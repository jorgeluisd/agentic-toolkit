package db

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/require"
)

func TestIsConflict(t *testing.T) {
	require.True(t, IsConflict(fmt.Errorf("commit: %w", &pgconn.PgError{Code: "40001"})))
	require.False(t, IsConflict(&pgconn.PgError{Code: "23505"}))
	require.False(t, IsConflict(errors.New("40001")))
}

func TestChunks_NeverExceedsTheDSQLRowLimit(t *testing.T) {
	items := make([]int, 7001)
	chunks := Chunks(items, 10_000)
	require.Len(t, chunks, 3)
	for _, c := range chunks {
		require.LessOrEqual(t, len(c), MaxRowsPerTx)
	}
	require.Len(t, chunks[2], 1001)
	require.Empty(t, Chunks([]int{}, 10))
}
