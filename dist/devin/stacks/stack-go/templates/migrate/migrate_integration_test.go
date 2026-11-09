//go:build integration

package migrate

import (
	"testing"
	"testing/fstest"

	"github.com/stretchr/testify/require"

	"github.com/OWNER/REPO/internal/platform/db/dbtest"
)

func TestRun_AppliesOnceAgainstPostgres(t *testing.T) {
	conn := dbtest.Conn(t)
	ms, err := Load(fstest.MapFS{
		"m/0001_probe.sql":       {Data: []byte("CREATE TABLE IF NOT EXISTS migrate_probe (id uuid PRIMARY KEY, status text NOT NULL)")},
		"m/0002_probe_index.sql": {Data: []byte("CREATE INDEX ASYNC migrate_probe_status_idx ON migrate_probe (status)")},
	}, "m")
	require.NoError(t, err)

	applied, err := Run(t.Context(), conn, Postgres, ms)
	require.NoError(t, err)
	require.Equal(t, 2, applied)

	applied, err = Run(t.Context(), conn, Postgres, ms)
	require.NoError(t, err)
	require.Equal(t, 0, applied)
}

func TestRun_ToleratesDDLAppliedButNotRecorded(t *testing.T) {
	conn := dbtest.Conn(t)
	_, err := conn.Exec(t.Context(), "CREATE TABLE migrate_cut (id uuid PRIMARY KEY)")
	require.NoError(t, err)

	applied, err := Run(t.Context(), conn, Postgres, []Migration{{Version: 1, Name: "cut", SQL: "CREATE TABLE migrate_cut (id uuid PRIMARY KEY)"}})
	require.NoError(t, err)
	require.Equal(t, 1, applied)
}
