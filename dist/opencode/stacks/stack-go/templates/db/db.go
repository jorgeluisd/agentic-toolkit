// Package db arma el pool de Aurora DSQL con token IAM y la transacción con
// reintento ante conflictos optimistas. Plantilla de stack-go: copiar a
// internal/platform/db/.
package db

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/url"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dsql/auth"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	MaxRowsPerTx  = 3000
	maxAttempts   = 5
	firstBackoff  = 20 * time.Millisecond
	sqlstateOCC   = "40001"
	adminUser     = "admin"
	connLifetime  = 50 * time.Minute
	connIdleLimit = 5 * time.Minute
)

type DSQLConfig struct {
	Endpoint    string
	Region      string
	User        string
	Credentials aws.CredentialsProvider
}

// NewDSQLPool no abre conexiones: la primera consulta conecta, así el init de
// la Lambda no paga la red. Cada conexión nueva firma un token IAM fresco.
func NewDSQLPool(ctx context.Context, c DSQLConfig) (*pgxpool.Pool, error) {
	dsn := (&url.URL{
		Scheme:   "postgres",
		User:     url.User(c.User),
		Host:     c.Endpoint + ":5432",
		Path:     "/postgres",
		RawQuery: "sslmode=verify-full",
	}).String()
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("db: config: %w", err)
	}
	cfg.MaxConns = 2
	cfg.MaxConnLifetime = connLifetime
	cfg.MaxConnIdleTime = connIdleLimit
	cfg.BeforeConnect = func(ctx context.Context, cc *pgx.ConnConfig) error {
		token, err := token(ctx, c)
		if err != nil {
			return fmt.Errorf("db: token IAM: %w", err)
		}
		cc.Password = token
		return nil
	}
	return pgxpool.NewWithConfig(ctx, cfg)
}

func token(ctx context.Context, c DSQLConfig) (string, error) {
	if c.User == adminUser {
		return auth.GenerateDBConnectAdminAuthToken(ctx, c.Endpoint, c.Region, c.Credentials)
	}
	return auth.GenerateDbConnectAuthToken(ctx, c.Endpoint, c.Region, c.Credentials)
}

type Beginner interface {
	Begin(ctx context.Context) (pgx.Tx, error)
}

// InTx reintenta fn ante SQLSTATE 40001 (DSQL: OC000 datos, OC001 esquema).
// fn puede correr más de una vez: tiene que ser idempotente y no tener efectos
// fuera de la transacción (nada de publicar eventos ni mandar mails adentro).
func InTx(ctx context.Context, db Beginner, fn func(pgx.Tx) error) error {
	backoff := firstBackoff
	for attempt := 1; ; attempt++ {
		err := pgx.BeginFunc(ctx, db, fn)
		if err == nil || !IsConflict(err) || attempt == maxAttempts {
			return err
		}
		wait := backoff + rand.N(backoff) //nolint:gosec // G404: jitter de reintento, no es un secreto
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
		backoff *= 2
	}
}

func IsConflict(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == sqlstateOCC
}

// Chunks parte un lote para que ninguna transacción supere MaxRowsPerTx filas.
func Chunks[T any](items []T, size int) [][]T {
	size = min(max(size, 1), MaxRowsPerTx)
	var out [][]T
	for len(items) > size {
		out = append(out, items[:size:size])
		items = items[size:]
	}
	if len(items) > 0 {
		out = append(out, items)
	}
	return out
}
