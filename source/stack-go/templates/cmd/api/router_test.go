package main

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/apigen"
	"github.com/OWNER/REPO/internal/platform/auth"
)

type fakeVerifier map[string]auth.Principal

func (f fakeVerifier) Verify(raw string) (auth.Principal, error) {
	p, ok := f[raw]
	if !ok {
		return auth.Principal{}, auth.ErrUnauthenticated
	}
	return p, nil
}

type fakeServer struct{ apigen.StrictServerInterface }

func (fakeServer) RecordGoal(ctx context.Context, req apigen.RecordGoalRequestObject) (apigen.RecordGoalResponseObject, error) {
	p, _ := auth.FromContext(ctx)
	return apigen.RecordGoal200JSONResponse{MatchId: req.Id, Goals: len(p.Subject), Replay: false}, nil
}

func (fakeServer) LiveBoard(context.Context, apigen.LiveBoardRequestObject) (apigen.LiveBoardResponseObject, error) {
	return apigen.LiveBoard200JSONResponse{Goals: 2}, nil
}

func TestRouter_EnforcesTheContract(t *testing.T) {
	v := fakeVerifier{
		"coach":  {Subject: "u1", Roles: []auth.Role{auth.RoleCoach}},
		"parent": {Subject: "u2", Roles: []auth.Role{auth.RoleParent}},
	}
	h, err := newRouter(slog.New(slog.DiscardHandler), v, fakeServer{})
	require.NoError(t, err)
	const goal = `{"playerId":"0b9c7f1e-2a4d-4c3b-9e8f-1a2b3c4d5e6f","minute":10,"clientEventId":"1b9c7f1e-2a4d-4c3b-9e8f-1a2b3c4d5e6f"}`
	path := "/matches/2b9c7f1e-2a4d-4c3b-9e8f-1a2b3c4d5e6f/goals"
	cases := []struct {
		name, method, path, token, body string
		status                          int
	}{
		{"coach registra gol", http.MethodPost, path, "coach", goal, 200},
		{"padre no puede", http.MethodPost, path, "parent", goal, 403},
		{"sin token", http.MethodPost, path, "", goal, 401},
		{"token inválido", http.MethodPost, path, "otro", goal, 401},
		{"campo de más", http.MethodPost, path, "coach", strings.Replace(goal, `"minute":10`, `"minute":10,"coachId":"x"`, 1), 400},
		{"minuto fuera de rango", http.MethodPost, path, "coach", strings.Replace(goal, `"minute":10`, `"minute":999`, 1), 400},
		{"id de ruta no uuid", http.MethodPost, "/matches/42/goals", "coach", goal, 400},
		{"link público sin token", http.MethodGet, "/live/abc", "", "", 200},
		{"ruta inexistente", http.MethodGet, "/nada", "coach", "", 404},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			if tc.body != "" {
				req.Header.Set("Content-Type", "application/json")
			}
			if tc.token != "" {
				req.Header.Set("Authorization", "Bearer "+tc.token)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			require.Equal(t, tc.status, rec.Code, rec.Body.String())
		})
	}
}
