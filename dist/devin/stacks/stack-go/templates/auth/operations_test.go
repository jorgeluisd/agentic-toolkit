package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

const specYAML = `
openapi: 3.0.3
info: { title: t, version: "1" }
components:
  securitySchemes:
    cognito: { type: http, scheme: bearer }
paths:
  /live/{token}:
    get:
      operationId: liveBoard
      security: []
      responses: { "200": { description: ok } }
  /matches:
    post:
      operationId: createMatch
      security: [{ cognito: [coach, assistant] }]
      responses: { "200": { description: ok } }
  /me:
    get:
      operationId: me
      security: [{ cognito: [] }]
      responses: { "200": { description: ok } }
`

func loadSpec(t *testing.T, src string) *openapi3.T {
	t.Helper()
	doc, err := openapi3.NewLoader().LoadFromData([]byte(src))
	require.NoError(t, err)
	return doc
}

func TestOperationsFromSpec_ReadsRolesFromTheContract(t *testing.T) {
	ops, err := OperationsFromSpec(loadSpec(t, specYAML), "cognito")
	require.NoError(t, err)
	require.Equal(t, Rule{Public: true}, ops["liveBoard"])
	require.Equal(t, Rule{Roles: []Role{RoleCoach, RoleAssistant}}, ops["createMatch"])
	require.Equal(t, Rule{}, ops["me"])
}

func TestOperationsFromSpec_FailsWhenAnOperationDoesNotDeclareSecurity(t *testing.T) {
	src := specYAML + `
  /forgotten:
    get:
      operationId: forgotten
      responses: { "200": { description: ok } }
`
	_, err := OperationsFromSpec(loadSpec(t, src), "cognito")
	require.ErrorContains(t, err, "forgotten")
}

func TestOperationsCheck(t *testing.T) {
	ops, err := OperationsFromSpec(loadSpec(t, specYAML), "cognito")
	require.NoError(t, err)
	coach := fakeVerifier{p: Principal{Subject: "u1", Roles: []Role{RoleCoach}}}
	parent := fakeVerifier{p: Principal{Subject: "u2", Roles: []Role{RoleParent}}}
	bad := fakeVerifier{err: ErrUnauthenticated}
	cases := []struct {
		name   string
		v      fakeVerifier
		op     string
		header string
		want   errs.Kind
	}{
		{"pública sin token", bad, "liveBoard", "", 0},
		{"rol permitido", coach, "createMatch", "Bearer x", 0},
		{"rol denegado", parent, "createMatch", "Bearer x", errs.KindForbidden},
		{"sin token", coach, "createMatch", "", errs.KindUnauthenticated},
		{"token inválido", bad, "me", "Bearer x", errs.KindUnauthenticated},
		{"autenticado sin rol pedido", parent, "me", "Bearer x", 0},
		{"operación desconocida", coach, "nope", "Bearer x", errs.KindForbidden},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.header != "" {
				r.Header.Set("Authorization", tc.header)
			}
			_, err := ops.Check(tc.v, tc.op, r)
			kind, _, _ := errs.KindOf(err)
			require.Equal(t, tc.want, kind)
		})
	}
}
