//go:build integration

package db

import (
	"sync"
	"sync/atomic"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/platform/db/dbtest"
)

// Con Repeatable Read, Postgres local devuelve 40001 igual que el OCC de DSQL.
func TestInTx_RetriesConcurrentConflicts(t *testing.T) {
	ctx := t.Context()
	pool := dbtest.Pool(t)
	for _, stmt := range []string{
		"CREATE TABLE intx_counter (id int PRIMARY KEY, n int NOT NULL)",
		"INSERT INTO intx_counter VALUES (1, 0)",
	} {
		_, err := pool.Exec(ctx, stmt)
		require.NoError(t, err)
	}

	const writers = 4
	var attempts atomic.Int32
	var snapshots, wg sync.WaitGroup
	snapshots.Add(writers)
	errs := make(chan error, writers)
	for range writers {
		wg.Go(func() {
			first := true
			errs <- InTx(ctx, pool, func(tx pgx.Tx) error {
				attempts.Add(1)
				var n int
				if err := tx.QueryRow(ctx, "SELECT n FROM intx_counter WHERE id = 1").Scan(&n); err != nil {
					return err
				}
				if first {
					first = false
					snapshots.Done()
					snapshots.Wait()
				}
				_, err := tx.Exec(ctx, "UPDATE intx_counter SET n = $1 WHERE id = 1", n+1)
				return err
			})
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	var n int
	require.NoError(t, pool.QueryRow(ctx, "SELECT n FROM intx_counter WHERE id = 1").Scan(&n))
	require.Equal(t, writers, n)
	require.Greater(t, int(attempts.Load()), writers, "ningún conflicto: el test no ejercitó el reintento")
}
