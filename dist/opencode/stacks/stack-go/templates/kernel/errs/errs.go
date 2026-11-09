// Package errs es el error tipado del shared kernel. Plantilla de stack-go:
// copiar a internal/kernel/errs/. Solo stdlib: lo importan dominio y aplicación.
package errs

import "errors"

type Kind uint8

const (
	KindInvalid Kind = iota + 1
	KindMalformed
	KindNotFound
	KindConflict
	KindForbidden
	KindUnauthenticated
	KindUnavailable
)

// Error lleva un Code estable (contrato con el front) y un Kind que el borde
// HTTP traduce a status en un solo lugar. Msg es interno: nunca datos personales.
type Error struct {
	Kind Kind
	Code string
	Msg  string
}

func New(kind Kind, code, msg string) *Error {
	return &Error{Kind: kind, Code: code, Msg: msg}
}

func (e *Error) Error() string { return e.Code + ": " + e.Msg }

// Is compara por Code: un error envuelto con fmt.Errorf("...: %w", ErrX)
// sigue siendo errors.Is(err, ErrX).
func (e *Error) Is(target error) bool {
	t, ok := target.(*Error)
	return ok && t.Code == e.Code
}

func KindOf(err error) (Kind, string, bool) {
	var e *Error
	if !errors.As(err, &e) {
		return 0, "", false
	}
	return e.Kind, e.Code, true
}
