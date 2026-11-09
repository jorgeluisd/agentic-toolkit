package auth

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/lestrrat-go/httprc/v3"
	"github.com/lestrrat-go/jwx/v3/jwa"
	"github.com/lestrrat-go/jwx/v3/jwk"
	"github.com/lestrrat-go/jwx/v3/jwt"
	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

const (
	testIssuer   = "https://cognito-idp.sa-east-1.amazonaws.com/sa-east-1_test"
	testClientID = "client-123"
	testTenant   = "0b9c7f1e-2a4d-4c3b-9e8f-1a2b3c4d5e6f"
)

type signer struct {
	key jwk.Key
}

func newSigner(t *testing.T, kid string) (signer, jwk.Key) {
	t.Helper()
	raw, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	priv, err := jwk.Import(raw)
	require.NoError(t, err)
	require.NoError(t, priv.Set(jwk.KeyIDKey, kid))
	require.NoError(t, priv.Set(jwk.AlgorithmKey, jwa.RS256()))
	pub, err := jwk.PublicKeyOf(priv)
	require.NoError(t, err)
	return signer{key: priv}, pub
}

func (s signer) sign(t *testing.T, edit func(*jwt.Builder) *jwt.Builder) string {
	t.Helper()
	b := jwt.NewBuilder().
		Issuer(testIssuer).
		Subject("user-1").
		Expiration(time.Now().Add(time.Hour)).
		Claim("token_use", "access").
		Claim("client_id", testClientID).
		Claim("custom:coach_id", testTenant).
		Claim("cognito:groups", []string{"coach"})
	tok, err := edit(b).Build()
	require.NoError(t, err)
	signed, err := jwt.Sign(tok, jwt.WithKey(jwa.RS256(), s.key))
	require.NoError(t, err)
	return string(signed)
}

func newTestVerifier(t *testing.T, pub jwk.Key) *Verifier {
	t.Helper()
	set := jwk.NewSet()
	require.NoError(t, set.AddKey(pub))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(set)
	}))
	t.Cleanup(srv.Close)
	v, err := NewVerifier(t.Context(), Config{
		Issuer: testIssuer, ClientID: testClientID, TenantClaim: "custom:coach_id", JWKSURL: srv.URL,
	}, httprc.NewClient())
	require.NoError(t, err)
	return v
}

func TestVerify_AcceptsAValidAccessToken(t *testing.T) {
	s, pub := newSigner(t, "k1")
	v := newTestVerifier(t, pub)

	p, err := v.Verify(s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b }))

	require.NoError(t, err)
	require.Equal(t, "user-1", p.Subject)
	require.Equal(t, testTenant, p.Tenant.String())
	require.True(t, p.Has("coach"))
	require.False(t, p.Has("parent"))
}

func TestVerify_RejectsEachInvalidToken(t *testing.T) {
	s, pub := newSigner(t, "k1")
	other, _ := newSigner(t, "k1")
	v := newTestVerifier(t, pub)
	cases := map[string]string{
		"expired":          s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Expiration(time.Now().Add(-time.Hour)) }),
		"other issuer":     s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Issuer("https://evil.example") }),
		"id token":         s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Claim("token_use", "id") }),
		"other app client": s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Claim("client_id", "other") }),
		"no tenant":        s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Claim("custom:coach_id", "") }),
		"tenant not uuid":  s.sign(t, func(b *jwt.Builder) *jwt.Builder { return b.Claim("custom:coach_id", "' OR 1=1") }),
		"foreign key":      other.sign(t, func(b *jwt.Builder) *jwt.Builder { return b }),
		"garbage":          "not.a.jwt",
		"alg none":         "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyLTEifQ.",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := v.Verify(raw)
			kind, _, _ := errs.KindOf(err)
			require.Equal(t, errs.KindUnauthenticated, kind)
		})
	}
}

type fakeVerifier struct {
	p   Principal
	err error
}

func (f fakeVerifier) Verify(string) (Principal, error) { return f.p, f.err }

func failWithKind(w http.ResponseWriter, _ *http.Request, err error) {
	kind, _, _ := errs.KindOf(err)
	w.WriteHeader(map[errs.Kind]int{errs.KindUnauthenticated: 401, errs.KindForbidden: 403}[kind])
}

func TestMiddlewares_AuthenticateThenRequireRole(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, _ := FromContext(r.Context())
		_, _ = w.Write([]byte(p.Subject))
	})
	coach := Principal{Subject: "u1", Roles: []Role{"coach"}}
	cases := []struct {
		name   string
		header string
		v      fakeVerifier
		status int
	}{
		{"no header", "", fakeVerifier{p: coach}, 401},
		{"not bearer", "Basic abc", fakeVerifier{p: coach}, 401},
		{"bad token", "Bearer x", fakeVerifier{err: ErrUnauthenticated}, 401},
		{"wrong role", "Bearer x", fakeVerifier{p: Principal{Subject: "u2", Roles: []Role{"parent"}}}, 403},
		{"coach", "Bearer x", fakeVerifier{p: coach}, 200},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := Authenticate(tc.v, failWithKind)(RequireRole(failWithKind, "coach")(ok))
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tc.header != "" {
				req.Header.Set("Authorization", tc.header)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			require.Equal(t, tc.status, rec.Code)
		})
	}
}
