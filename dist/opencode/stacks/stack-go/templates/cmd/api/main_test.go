package main

import (
	"net/http"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/awslabs/aws-lambda-go-api-proxy/httpadapter"
	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/require"
)

func TestAdapterV2_ReachesTheRouter(t *testing.T) {
	r := chi.NewRouter()
	r.Get("/live/{token}", func(w http.ResponseWriter, req *http.Request) {
		_, _ = w.Write([]byte(chi.URLParam(req, "token")))
	})
	resp, err := httpadapter.NewV2(r).ProxyWithContext(t.Context(), events.APIGatewayV2HTTPRequest{
		RawPath: "/live/abc123",
		RequestContext: events.APIGatewayV2HTTPRequestContext{
			HTTP: events.APIGatewayV2HTTPRequestContextHTTPDescription{Method: http.MethodGet, Path: "/live/abc123"},
		},
	})
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode)
	require.Equal(t, "abc123", resp.Body)
}
