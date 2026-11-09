// Package dbtest da a cada test de integración un schema propio en el Postgres
// local. Plantilla de stack-go: copiar a internal/platform/db/dbtest/.
package dbtest

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var localHosts = map[string]bool{"localhost": true, "127.0.0.1": true, "::1": true, "postgres": true}

// URL devuelve DATABASE_URL y frena el test si apunta fuera de la máquina:
// los tests crean y borran schemas, y nunca deben tocar una base real.
func URL(t *testing.T) string {
	t.Helper()
	raw := os.Getenv("DATABASE_URL")
	if raw == "" {
		t.Fatal("DATABASE_URL vacío: docker compose up -d --wait")
	}
	u, err := url.Parse(raw)
	if err != nil || !localHosts[u.Hostname()] {
		t.Fatalf("DATABASE_URL tiene que apuntar a un Postgres local, no a %q", u.Hostname())
	}
	return raw
}

func schemaFor(t *testing.T) string {
	name := strings.ToLower(strings.NewReplacer("/", "_", " ", "_", "-", "_").Replace(t.Name()))
	return fmt.Sprintf("t_%.40s_%d", name, os.Getpid())
}

func createSchema(t *testing.T, raw, schema string) {
	t.Helper()
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, raw)
	if err != nil {
		t.Fatalf("dbtest: conectar: %v", err)
	}
	defer func() { _ = admin.Close(ctx) }()
	ident := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(ctx, "DROP SCHEMA IF EXISTS "+ident+" CASCADE"); err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+ident); err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	t.Cleanup(func() {
		c, err := pgx.Connect(context.Background(), raw)
		if err == nil {
			_, _ = c.Exec(context.Background(), "DROP SCHEMA IF EXISTS "+ident+" CASCADE")
			_ = c.Close(context.Background())
		}
	})
}

func Conn(t *testing.T) *pgx.Conn {
	t.Helper()
	raw, schema := URL(t), schemaFor(t)
	createSchema(t, raw, schema)
	cfg, err := pgx.ParseConfig(raw)
	if err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	cfg.RuntimeParams["search_path"] = schema
	conn, err := pgx.ConnectConfig(t.Context(), cfg)
	if err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	return conn
}

func Pool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	raw, schema := URL(t), schemaFor(t)
	createSchema(t, raw, schema)
	cfg, err := pgxpool.ParseConfig(raw)
	if err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatalf("dbtest: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}
