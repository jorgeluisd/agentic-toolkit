// Package auth valida el access token de Cognito y deja el Principal (sujeto,
// tenant y roles) en el context. Plantilla de stack-go: copiar a
// internal/platform/auth/ y reemplazar github.com/OWNER/REPO.
package auth

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/lestrrat-go/httprc/v3"
	"github.com/lestrrat-go/jwx/v3/jwk"
	"github.com/lestrrat-go/jwx/v3/jwt"

	"github.com/OWNER/REPO/internal/kernel/errs"
	"github.com/OWNER/REPO/internal/kernel/tenant"
)

var (
	ErrUnauthenticated = errs.New(errs.KindUnauthenticated, "UNAUTHENTICATED", "token ausente o inválido")
	ErrRoleRequired    = errs.New(errs.KindForbidden, "ROLE_REQUIRED", "el rol del token no alcanza")
)

type Role string

const (
	RoleCoach     Role = "coach"
	RoleAssistant Role = "assistant"
	RoleDelegate  Role = "delegate"
	RoleParent    Role = "parent"
)

type Principal struct {
	Subject string
	Tenant  tenant.ID
	Roles   []Role
}

func (p Principal) Has(roles ...Role) bool {
	return slices.ContainsFunc(roles, func(r Role) bool { return slices.Contains(p.Roles, r) })
}

type Config struct {
	Issuer      string
	ClientID    string
	TenantClaim string
	JWKSURL     string
	Skew        time.Duration
}

func CognitoIssuer(region, userPoolID string) string {
	return fmt.Sprintf("https://cognito-idp.%s.amazonaws.com/%s", region, userPoolID)
}

type Verifier struct {
	cfg  Config
	keys jwk.Set
}

// NewVerifier registra el JWKS en una caché que se refresca sola. Si cfg.JWKSURL
// está vacío usa el de Cognito para cfg.Issuer.
func NewVerifier(ctx context.Context, cfg Config, client *httprc.Client) (*Verifier, error) {
	if cfg.JWKSURL == "" {
		cfg.JWKSURL = cfg.Issuer + "/.well-known/jwks.json"
	}
	cache, err := jwk.NewCache(ctx, client)
	if err != nil {
		return nil, fmt.Errorf("auth: cache jwks: %w", err)
	}
	if err := cache.Register(ctx, cfg.JWKSURL); err != nil {
		return nil, fmt.Errorf("auth: registrar jwks: %w", err)
	}
	keys, err := cache.CachedSet(cfg.JWKSURL)
	if err != nil {
		return nil, fmt.Errorf("auth: jwks: %w", err)
	}
	return &Verifier{cfg: cfg, keys: keys}, nil
}

// Verify acepta solo access tokens RS256 de este pool y este app client.
func (v *Verifier) Verify(raw string) (Principal, error) {
	tok, err := jwt.ParseString(raw,
		jwt.WithKeySet(v.keys),
		jwt.WithIssuer(v.cfg.Issuer),
		jwt.WithAcceptableSkew(v.cfg.Skew),
		jwt.WithClaimValue("token_use", "access"),
		jwt.WithClaimValue("client_id", v.cfg.ClientID),
	)
	if err != nil {
		return Principal{}, ErrUnauthenticated
	}
	return principalFrom(tok, v.cfg.TenantClaim)
}

func principalFrom(tok jwt.Token, tenantClaim string) (Principal, error) {
	sub, ok := tok.Subject()
	if !ok || sub == "" {
		return Principal{}, ErrUnauthenticated
	}
	var rawTenant string
	if err := tok.Get(tenantClaim, &rawTenant); err != nil {
		return Principal{}, ErrUnauthenticated
	}
	id, err := tenant.Parse(rawTenant)
	if err != nil {
		return Principal{}, ErrUnauthenticated
	}
	var groups []any
	_ = tok.Get("cognito:groups", &groups)
	roles := make([]Role, 0, len(groups))
	for _, g := range groups {
		if s, ok := g.(string); ok {
			roles = append(roles, Role(s))
		}
	}
	return Principal{Subject: sub, Tenant: id, Roles: roles}, nil
}

type principalKey struct{}

func WithPrincipal(ctx context.Context, p Principal) context.Context {
	return context.WithValue(ctx, principalKey{}, p)
}

// FromContext es la única fuente del tenant en un handler: nunca el body, la
// query ni un header que mande el cliente.
func FromContext(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(principalKey{}).(Principal)
	return p, ok
}

type TokenVerifier interface {
	Verify(raw string) (Principal, error)
}

type ErrorWriter func(w http.ResponseWriter, r *http.Request, err error)

func Authenticate(v TokenVerifier, fail ErrorWriter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || raw == "" {
				fail(w, r, ErrUnauthenticated)
				return
			}
			p, err := v.Verify(raw)
			if err != nil {
				fail(w, r, err)
				return
			}
			next.ServeHTTP(w, r.WithContext(WithPrincipal(r.Context(), p)))
		})
	}
}

// RequireRole es la autorización gruesa por grupo de Cognito. La fina (delegado
// de esta categoría, padre de este alumno) la decide application con datos.
func RequireRole(fail ErrorWriter, roles ...Role) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			p, ok := FromContext(r.Context())
			if !ok {
				fail(w, r, ErrUnauthenticated)
				return
			}
			if !p.Has(roles...) {
				fail(w, r, ErrRoleRequired)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
