package auth

import (
	"fmt"
	"net/http"
	"sort"

	"github.com/getkin/kin-openapi/openapi3"
)

type Rule struct {
	Public bool
	Roles  []Role
}

type Operations map[string]Rule

// OperationsFromSpec lee los roles de cada operación del `security` del
// contrato. Una operación sin `security` propio es un error de arranque: el
// contrato tiene que decir si es pública (`security: []`) o qué roles pide.
func OperationsFromSpec(doc *openapi3.T, scheme string) (Operations, error) {
	ops := Operations{}
	var missing []string
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			if op.OperationID == "" {
				return nil, fmt.Errorf("auth: %s %s no tiene operationId", method, path)
			}
			if op.Security == nil {
				missing = append(missing, op.OperationID)
				continue
			}
			ops[op.OperationID] = ruleFor(*op.Security, scheme)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return nil, fmt.Errorf("auth: operaciones sin security explícito: %v", missing)
	}
	return ops, nil
}

func ruleFor(reqs openapi3.SecurityRequirements, scheme string) Rule {
	if len(reqs) == 0 {
		return Rule{Public: true}
	}
	var roles []Role
	for _, req := range reqs {
		for _, scope := range req[scheme] {
			roles = append(roles, Role(scope))
		}
	}
	return Rule{Roles: roles}
}

// Check aplica la regla de la operación: devuelve el Principal (vacío si es
// pública) o el error que httpx.WriteError traduce a 401 o 403.
func (ops Operations) Check(v TokenVerifier, operationID string, r *http.Request) (Principal, error) {
	rule, ok := ops[operationID]
	if !ok {
		return Principal{}, ErrRoleRequired
	}
	if rule.Public {
		return Principal{}, nil
	}
	raw := bearer(r)
	if raw == "" {
		return Principal{}, ErrUnauthenticated
	}
	p, err := v.Verify(raw)
	if err != nil {
		return Principal{}, ErrUnauthenticated
	}
	if len(rule.Roles) > 0 && !p.Has(rule.Roles...) {
		return Principal{}, ErrRoleRequired
	}
	return p, nil
}

func bearer(r *http.Request) string {
	const prefix = "Bearer "
	h := r.Header.Get("Authorization")
	if len(h) <= len(prefix) || h[:len(prefix)] != prefix {
		return ""
	}
	return h[len(prefix):]
}
