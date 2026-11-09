// Package tenant es el identificador del tenant en el shared kernel.
// Plantilla de stack-go: copiar a internal/kernel/tenant/.
package tenant

import (
	"regexp"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

var ErrInvalid = errs.New(errs.KindUnauthenticated, "TENANT_INVALID", "el tenant del token no es un UUID")

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ID no tiene valor cero válido: un repositorio que recibe ID{} es un bug.
type ID struct{ value string }

func Parse(s string) (ID, error) {
	if !uuidPattern.MatchString(s) {
		return ID{}, ErrInvalid
	}
	return ID{value: s}, nil
}

func (id ID) String() string { return id.value }

func (id ID) IsZero() bool { return id.value == "" }
