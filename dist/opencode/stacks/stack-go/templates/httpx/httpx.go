// Package httpx es el borde HTTP compartido: problem+json, request id, log de
// acceso, recover y límite de tamaño. Plantilla de stack-go: copiar a
// internal/platform/httpx/ y reemplazar github.com/OWNER/REPO.
package httpx

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

const (
	HeaderRequestID = "X-Request-Id"
	MaxBodyBytes    = 64 << 10
	codeInternal    = "INTERNAL"
)

var ErrRouteNotFound = errs.New(errs.KindNotFound, "ROUTE_NOT_FOUND", "la ruta no existe")

var statusByKind = map[errs.Kind]int{
	errs.KindInvalid:         http.StatusUnprocessableEntity,
	errs.KindMalformed:       http.StatusBadRequest,
	errs.KindNotFound:        http.StatusNotFound,
	errs.KindConflict:        http.StatusConflict,
	errs.KindForbidden:       http.StatusForbidden,
	errs.KindUnauthenticated: http.StatusUnauthorized,
	errs.KindUnavailable:     http.StatusServiceUnavailable,
}

type Problem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Code      string `json:"code"`
	RequestID string `json:"requestId"`
}

// WriteError es el único lugar donde un error se vuelve status HTTP. Lo que no
// es un *errs.Error es un bug o una caída: 500 genérico y el detalle solo al log.
func WriteError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	kind, code, ok := errs.KindOf(err)
	status, known := statusByKind[kind]
	if !ok || !known {
		status, code = http.StatusInternalServerError, codeInternal
		log.ErrorContext(r.Context(), "http.request.failed", slog.String("errorType", fmt.Sprintf("%T", err)))
	}
	WriteJSON(w, status, Problem{
		Type: "about:blank", Title: http.StatusText(status), Status: status,
		Code: code, RequestID: RequestID(r.Context()),
	}, "application/problem+json")
}

func WriteJSON(w http.ResponseWriter, status int, body any, contentType string) {
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type requestIDKey struct{}

var validRequestID = regexp.MustCompile(`^[A-Za-z0-9-]{8,64}$`)

func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

// WithRequestID acepta el id entrante solo si tiene forma segura; si no, genera
// uno. newID se inyecta para que el test no dependa del azar.
func WithRequestID(newID func() string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := r.Header.Get(HeaderRequestID)
			if !validRequestID.MatchString(id) {
				id = newID()
			}
			w.Header().Set(HeaderRequestID, id)
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id)))
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// AccessLog escribe una línea por request con la ruta como patrón de chi
// (/matches/{id}), nunca la URL cruda: la URL puede traer datos personales.
func AccessLog(log *slog.Logger, now func() time.Time) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			route := "unmatched"
			if rc := chi.RouteContext(r.Context()); rc != nil && rc.RoutePattern() != "" {
				route = rc.RoutePattern()
			}
			log.LogAttrs(r.Context(), slog.LevelInfo, "http.request.completed",
				slog.String("requestId", RequestID(r.Context())),
				slog.String("method", r.Method),
				slog.String("route", route),
				slog.Int("status", rec.status),
				slog.Int64("durationMs", now().Sub(start).Milliseconds()),
			)
		})
	}
}

// Recover convierte un panic en 500 sin loguear el valor (puede traer datos).
func Recover(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer answerPanic(w, r, log)
			next.ServeHTTP(w, r)
		})
	}
}

func answerPanic(w http.ResponseWriter, r *http.Request, log *slog.Logger) {
	v := recover()
	if v == nil {
		return
	}
	if v == http.ErrAbortHandler { //nolint:errorlint // recover() devuelve any, no un error envuelto
		panic(v) //nolint:forbidigo // net/http exige re-lanzar ErrAbortHandler
	}
	log.ErrorContext(r.Context(), "http.request.panicked", slog.String("requestId", RequestID(r.Context())))
	WriteError(w, r, log, nil)
}

func SecureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func LimitBody(limit int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, limit)
			next.ServeHTTP(w, r)
		})
	}
}
