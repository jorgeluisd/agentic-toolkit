// Package migrate aplica migraciones SQL compatibles con Aurora DSQL: una
// sentencia por archivo y sin locks de advisory. Plantilla de stack-go: copiar
// a internal/platform/migrate/. Lo usa cmd/migrate, nunca el init de la Lambda.
package migrate

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type Dialect int

const (
	DSQL Dialect = iota
	Postgres
)

type Migration struct {
	Version int64
	Name    string
	SQL     string
}

const createVersionTable = `CREATE TABLE IF NOT EXISTS schema_migrations (
	version bigint PRIMARY KEY,
	name text NOT NULL,
	applied_at timestamptz NOT NULL DEFAULT now()
)`

var fileName = regexp.MustCompile(`^(\d{4,})_([a-z0-9_]+)\.sql$`)

func Load(fsys fs.FS, dir string) ([]Migration, error) {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return nil, err
	}
	seen := map[int64]string{}
	var ms []Migration
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sql") {
			continue
		}
		m := fileName.FindStringSubmatch(e.Name())
		if m == nil {
			return nil, fmt.Errorf("migrate: %s no sigue NNNN_slug.sql", e.Name())
		}
		version, _ := strconv.ParseInt(m[1], 10, 64)
		if prev, dup := seen[version]; dup {
			return nil, fmt.Errorf("migrate: versión %d repetida en %s y %s", version, prev, e.Name())
		}
		seen[version] = e.Name()
		body, err := fs.ReadFile(fsys, path.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		ms = append(ms, Migration{Version: version, Name: m[2], SQL: string(body)})
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i].Version < ms[j].Version })
	return ms, nil
}

var (
	lineComment = regexp.MustCompile(`--[^\n]*`)
	indexAsync  = regexp.MustCompile(`(?i)\bINDEX\s+ASYNC\b`)
	createIndex = regexp.MustCompile(`(?i)\bCREATE\s+(UNIQUE\s+)?INDEX\b`)
	forbidden   = []struct {
		re     *regexp.Regexp
		reason string
	}{
		{regexp.MustCompile(`(?i)\bCREATE\s+(OR\s+REPLACE\s+)?TRIGGER\b`), "DSQL no soporta triggers"},
		{regexp.MustCompile(`(?i)\bLANGUAGE\s+plpgsql\b|\bDO\s+\$`), "DSQL no soporta PL/pgSQL"},
		{regexp.MustCompile(`(?i)\bCREATE\s+TYPE\b`), "DSQL no soporta CREATE TYPE: text con CHECK"},
		{regexp.MustCompile(`(?i)\bTRUNCATE\b`), "DSQL no soporta TRUNCATE: DELETE por lotes"},
		{regexp.MustCompile(`(?i)\b(TEMP|TEMPORARY)\s+TABLE\b`), "DSQL no soporta tablas temporales: CTE"},
		{regexp.MustCompile(`(?i)\bCREATE\s+(EXTENSION|DATABASE)\b`), "DSQL no soporta extensiones ni otras bases"},
		{regexp.MustCompile(`(?i)\bROW\s+LEVEL\s+SECURITY\b|\bCREATE\s+POLICY\b`), "sin RLS: el tenant se filtra en los repositorios"},
		{regexp.MustCompile(`(?i)\bCONCURRENTLY\b`), "en DSQL es CREATE INDEX ASYNC"},
	}
)

func statement(sql string) string {
	return strings.TrimSuffix(strings.TrimSpace(lineComment.ReplaceAllString(sql, "")), ";")
}

// Check es textual: un ';' en un literal cuenta como segunda sentencia, a propósito.
func Check(m Migration) error {
	stmt := statement(m.SQL)
	switch {
	case stmt == "":
		return fmt.Errorf("migrate: %04d_%s está vacía", m.Version, m.Name)
	case strings.Contains(stmt, ";"):
		return fmt.Errorf("migrate: %04d_%s tiene más de una sentencia (DSQL: una DDL por transacción)", m.Version, m.Name)
	case createIndex.MatchString(stmt) && !indexAsync.MatchString(stmt):
		return fmt.Errorf("migrate: %04d_%s crea un índice sin ASYNC", m.Version, m.Name)
	}
	for _, f := range forbidden {
		if f.re.MatchString(stmt) {
			return fmt.Errorf("migrate: %04d_%s: %s", m.Version, m.Name, f.reason)
		}
	}
	return nil
}

// Schema es db/schema.sql para sqlc, que no parsea la sintaxis ASYNC de DSQL.
func Schema(ms []Migration) string {
	var b strings.Builder
	b.WriteString("-- Generado desde db/migrations: no editar.\n")
	for _, m := range ms {
		fmt.Fprintf(&b, "\n-- %04d_%s\n%s;\n", m.Version, m.Name, indexAsync.ReplaceAllString(statement(m.SQL), "INDEX"))
	}
	return b.String()
}

func CheckAll(ms []Migration) error {
	var errs []error
	for _, m := range ms {
		errs = append(errs, Check(m))
	}
	return errors.Join(errs...)
}

// Run registra cada versión aparte de su DDL (regla de DSQL): tras un corte, tolera "ya existe".
func Run(ctx context.Context, conn *pgx.Conn, d Dialect, ms []Migration) (int, error) {
	if err := CheckAll(ms); err != nil {
		return 0, err
	}
	if _, err := conn.Exec(ctx, createVersionTable); err != nil {
		return 0, fmt.Errorf("migrate: tabla de versiones: %w", err)
	}
	done, err := appliedVersions(ctx, conn)
	if err != nil {
		return 0, err
	}
	applied := 0
	for _, m := range ms {
		if done[m.Version] {
			continue
		}
		if err := apply(ctx, conn, d, statement(m.SQL)); err != nil {
			return applied, fmt.Errorf("migrate: %04d_%s: %w", m.Version, m.Name, err)
		}
		if _, err := conn.Exec(ctx, `INSERT INTO schema_migrations (version, name) VALUES ($1, $2) ON CONFLICT (version) DO NOTHING`, m.Version, m.Name); err != nil {
			return applied, fmt.Errorf("migrate: registrar %04d: %w", m.Version, err)
		}
		applied++
	}
	return applied, nil
}

func appliedVersions(ctx context.Context, conn *pgx.Conn) (map[int64]bool, error) {
	rows, err := conn.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, err
	}
	versions, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return nil, err
	}
	done := make(map[int64]bool, len(versions))
	for _, v := range versions {
		done[v] = true
	}
	return done, nil
}

func apply(ctx context.Context, conn *pgx.Conn, d Dialect, stmt string) error {
	if d == Postgres {
		_, err := conn.Exec(ctx, indexAsync.ReplaceAllString(stmt, "INDEX"))
		return toleratingExisting(err)
	}
	if !indexAsync.MatchString(stmt) {
		_, err := conn.Exec(ctx, stmt)
		return toleratingExisting(err)
	}
	var jobID string
	if err := conn.QueryRow(ctx, stmt).Scan(&jobID); err != nil {
		return toleratingExisting(err)
	}
	var ok bool
	if err := conn.QueryRow(ctx, `SELECT sys.wait_for_job($1)`, jobID).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("el índice del job %s quedó INVALID: DROP INDEX y volver a crearlo", jobID)
	}
	return nil
}

var alreadyExists = map[string]bool{"42P07": true, "42701": true, "42710": true}

func toleratingExisting(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && alreadyExists[pgErr.Code] {
		return nil
	}
	return err
}
