package main

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/getkin/kin-openapi/openapi3filter"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	oapimw "github.com/oapi-codegen/nethttp-middleware"

	"github.com/OWNER/REPO/internal/apigen"
	"github.com/OWNER/REPO/internal/kernel/errs"
	"github.com/OWNER/REPO/internal/platform/auth"
	"github.com/OWNER/REPO/internal/platform/httpx"
)

var errContract = errs.New(errs.KindMalformed, "REQUEST_INVALID", "el request no cumple el contrato")

// newRouter arma el borde: los roles de cada operación salen del security del
// contrato embebido, y el validador rechaza lo que el contrato no permite.
func newRouter(log *slog.Logger, v auth.TokenVerifier, server apigen.StrictServerInterface) (http.Handler, error) {
	spec, err := apigen.GetSpec()
	if err != nil {
		return nil, err
	}
	ops, err := auth.OperationsFromSpec(spec, "cognito")
	if err != nil {
		return nil, err
	}
	spec.Servers = nil
	fail := func(w http.ResponseWriter, r *http.Request, err error) { httpx.WriteError(w, r, log, err) }

	r := chi.NewRouter()
	r.Use(httpx.WithRequestID(uuid.NewString), httpx.AccessLog(log, time.Now), httpx.Recover(log),
		httpx.SecureHeaders, httpx.LimitBody(httpx.MaxBodyBytes))
	r.Use(oapimw.OapiRequestValidatorWithOptions(spec, &oapimw.Options{
		Options: openapi3filter.Options{AuthenticationFunc: openapi3filter.NoopAuthenticationFunc},
		ErrorHandlerWithOpts: func(_ context.Context, _ error, w http.ResponseWriter, r *http.Request, o oapimw.ErrorHandlerOpts) {
			if o.StatusCode == http.StatusNotFound {
				fail(w, r, httpx.ErrRouteNotFound)
				return
			}
			fail(w, r, errContract)
		},
	}))
	authz := func(f apigen.StrictHandlerFunc, operationID string) apigen.StrictHandlerFunc {
		return func(ctx context.Context, w http.ResponseWriter, req *http.Request, in any) (any, error) {
			p, err := ops.Check(v, operationID, req)
			if err != nil {
				return nil, err
			}
			return f(auth.WithPrincipal(ctx, p), w, req, in)
		}
	}
	h := apigen.NewStrictHandlerWithOptions(server, []apigen.StrictMiddlewareFunc{authz}, apigen.StrictHTTPServerOptions{
		RequestErrorHandlerFunc:  func(w http.ResponseWriter, r *http.Request, _ error) { fail(w, r, errContract) },
		ResponseErrorHandlerFunc: fail,
	})
	return apigen.HandlerFromMux(h, r), nil
}
