package httpx

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

func TestWriteError_MapsEachKindInOnePlace(t *testing.T) {
	cases := []struct {
		err    error
		status int
		code   string
	}{
		{errs.New(errs.KindInvalid, "SCORE_NEGATIVE", "x"), http.StatusUnprocessableEntity, "SCORE_NEGATIVE"},
		{errs.New(errs.KindMalformed, "BODY_INVALID", "x"), http.StatusBadRequest, "BODY_INVALID"},
		{fmt.Errorf("match 7: %w", errs.New(errs.KindNotFound, "MATCH_NOT_FOUND", "x")), http.StatusNotFound, "MATCH_NOT_FOUND"},
		{errs.New(errs.KindConflict, "EVENT_REPLAYED", "x"), http.StatusConflict, "EVENT_REPLAYED"},
		{errs.New(errs.KindForbidden, "ROLE_REQUIRED", "x"), http.StatusForbidden, "ROLE_REQUIRED"},
		{errs.New(errs.KindUnauthenticated, "TOKEN_INVALID", "x"), http.StatusUnauthorized, "TOKEN_INVALID"},
		{errs.New(errs.KindUnavailable, "DB_UNAVAILABLE", "x"), http.StatusServiceUnavailable, "DB_UNAVAILABLE"},
		{errors.New("pgx: conn refused at 10.0.0.1"), http.StatusInternalServerError, "INTERNAL"},
		{errs.New(errs.Kind(99), "UNMAPPED", "x"), http.StatusInternalServerError, "INTERNAL"},
	}
	for _, tc := range cases {
		t.Run(tc.code, func(t *testing.T) {
			rec := httptest.NewRecorder()
			WriteError(rec, httptest.NewRequest(http.MethodGet, "/", nil), slog.New(slog.DiscardHandler), tc.err)
			var p Problem
			require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &p))
			require.Equal(t, tc.status, rec.Code)
			require.Equal(t, tc.code, p.Code)
			require.Equal(t, "application/problem+json", rec.Header().Get("Content-Type"))
			require.NotContains(t, rec.Body.String(), "10.0.0.1")
		})
	}
}

func TestWithRequestID_RejectsUnsafeIncomingIDs(t *testing.T) {
	h := WithRequestID(func() string { return "generated-0001" })(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(RequestID(r.Context())))
	}))
	for incoming, want := range map[string]string{
		"abcd-1234-efgh":        "abcd-1234-efgh",
		"":                      "generated-0001",
		"bad\nforged-entry":     "generated-0001",
		strings.Repeat("a", 65): "generated-0001",
	} {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		req.Header.Set(HeaderRequestID, incoming)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		require.Equal(t, want, rec.Body.String())
		require.Equal(t, want, rec.Header().Get(HeaderRequestID))
	}
}

func TestAccessLog_LogsRoutePatternNotRawURL(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	r := chi.NewRouter()
	r.Use(AccessLog(log, func() time.Time { return time.Unix(0, 0) }))
	r.Get("/players/{id}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })

	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/players/42?email=ana@example.com", nil))

	require.Contains(t, buf.String(), `"route":"/players/{id}"`)
	require.Contains(t, buf.String(), `"status":204`)
	require.NotContains(t, buf.String(), "ana@example.com")
	require.NotContains(t, buf.String(), "/players/42")
}

func TestRecover_AnswersProblemWithoutLeakingThePanicValue(t *testing.T) {
	var buf bytes.Buffer
	h := Recover(slog.New(slog.NewJSONHandler(&buf, nil)))(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("dni 12345678") //nolint:forbidigo // el test provoca el panic que Recover tiene que absorber
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	require.Equal(t, http.StatusInternalServerError, rec.Code)
	require.NotContains(t, buf.String()+rec.Body.String(), "12345678")
}

func TestSecureHeaders_SetsNosniffAndNoStore(t *testing.T) {
	rec := httptest.NewRecorder()
	SecureHeaders(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	require.Equal(t, "nosniff", rec.Header().Get("X-Content-Type-Options"))
	require.Equal(t, "no-store", rec.Header().Get("Cache-Control"))
}

func TestLimitBody_RejectsOversizedBodies(t *testing.T) {
	h := LimitBody(8)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v map[string]any
		if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
			var tooBig *http.MaxBytesError
			require.ErrorAs(t, err, &tooBig)
			w.WriteHeader(http.StatusRequestEntityTooLarge)
		}
	}))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"name":"a very long body"}`)))
	require.Equal(t, http.StatusRequestEntityTooLarge, rec.Code)
}
