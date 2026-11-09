package migrate

import (
	"testing"
	"testing/fstest"

	"github.com/stretchr/testify/require"
)

func TestCheck_RejectsWhatDSQLCannotRun(t *testing.T) {
	cases := map[string]string{
		"two statements":       "CREATE TABLE a (id uuid PRIMARY KEY); CREATE TABLE b (id uuid PRIMARY KEY);",
		"index without async":  "CREATE INDEX a_idx ON a (id);",
		"unique index sync":    "CREATE UNIQUE INDEX a_idx ON a (id);",
		"trigger":              "CREATE TRIGGER t BEFORE INSERT ON a FOR EACH ROW EXECUTE FUNCTION f();",
		"plpgsql function":     "CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END $$ LANGUAGE plpgsql",
		"do block":             "DO $$ BEGIN NULL; END $$",
		"enum type":            "CREATE TYPE status AS ENUM ('a', 'b');",
		"truncate":             "TRUNCATE a;",
		"temporary table":      "CREATE TEMPORARY TABLE x (id int);",
		"extension":            "CREATE EXTENSION pgcrypto;",
		"row level security":   "ALTER TABLE a ENABLE ROW LEVEL SECURITY;",
		"concurrently":         "CREATE INDEX ASYNC CONCURRENTLY a_idx ON a (id);",
		"empty after comments": "-- nada\n",
	}
	for name, sql := range cases {
		t.Run(name, func(t *testing.T) {
			require.Error(t, Check(Migration{Version: 1, Name: "x", SQL: sql}))
		})
	}
}

func TestCheck_AcceptsDSQLCompatibleStatements(t *testing.T) {
	for _, sql := range []string{
		"-- tabla base\nCREATE TABLE IF NOT EXISTS a (id uuid PRIMARY KEY, status text NOT NULL CHECK (status IN ('open', 'closed')));",
		"CREATE INDEX ASYNC a_status_idx ON a (status);",
		"CREATE UNIQUE INDEX ASYNC a_code_idx ON a (code)",
		"ALTER TABLE a ADD COLUMN IF NOT EXISTS note text;",
	} {
		require.NoError(t, Check(Migration{Version: 1, Name: "x", SQL: sql}), sql)
	}
}

func TestLoad_OrdersByVersionAndRejectsBadNames(t *testing.T) {
	fsys := fstest.MapFS{
		"m/0002_second.sql": {Data: []byte("SELECT 2")},
		"m/0001_first.sql":  {Data: []byte("SELECT 1")},
		"m/README.md":       {Data: []byte("ignorado")},
	}
	ms, err := Load(fsys, "m")
	require.NoError(t, err)
	require.Equal(t, []int64{1, 2}, []int64{ms[0].Version, ms[1].Version})

	fsys["m/3_bad-name.sql"] = &fstest.MapFile{Data: []byte("SELECT 3")}
	_, err = Load(fsys, "m")
	require.ErrorContains(t, err, "NNNN_slug.sql")
}

func TestSchema_StripsAsyncForSqlc(t *testing.T) {
	got := Schema([]Migration{
		{Version: 1, Name: "matches", SQL: "-- tabla\nCREATE TABLE IF NOT EXISTS matches (id uuid PRIMARY KEY);\n"},
		{Version: 2, Name: "matches_idx", SQL: "CREATE INDEX ASYNC matches_idx ON matches (id)"},
	})
	require.Contains(t, got, "-- 0001_matches\nCREATE TABLE IF NOT EXISTS matches (id uuid PRIMARY KEY);\n")
	require.Contains(t, got, "CREATE INDEX matches_idx ON matches (id);")
	require.NotContains(t, got, "ASYNC")
}

func TestLoad_RejectsDuplicateVersions(t *testing.T) {
	fsys := fstest.MapFS{
		"m/0001_a.sql": {Data: []byte("SELECT 1")},
		"m/0001_b.sql": {Data: []byte("SELECT 1")},
	}
	_, err := Load(fsys, "m")
	require.ErrorContains(t, err, "repetida")
}
