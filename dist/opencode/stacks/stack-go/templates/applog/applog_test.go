package applog

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

type player struct {
	Name      string
	BirthDate string
	Phone     string
}

func TestNew_DropsEveryKeyOutsideTheAllowlist(t *testing.T) {
	var buf bytes.Buffer
	log := New(&buf, "api", slog.LevelInfo, "matchId")
	p := player{Name: "Juana Pérez", BirthDate: "2016-03-04", Phone: "+10000000001"}

	log.Info("matches.goal.recorded",
		slog.String("matchId", "m-1"),
		slog.String("coachId", "c-1"),
		slog.Any("player", p),
		slog.String("phone", p.Phone),
		slog.Group("child", slog.String("name", p.Name)),
	)

	line := buf.String()
	for _, leaked := range []string{"Juana", "2016-03-04", "+10000000001", "player", "child"} {
		require.NotContains(t, line, leaked)
	}
	var entry map[string]any
	require.NoError(t, json.Unmarshal([]byte(line), &entry))
	require.Equal(t, "m-1", entry["matchId"])
	require.Equal(t, "c-1", entry["coachId"])
	require.Equal(t, "api", entry["service"])
}

func TestNew_EscapesLineBreaksInValues(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, "api", slog.LevelInfo).Info("x", slog.String("route", "/a\n{\"level\":\"ERROR\"}"))
	require.Equal(t, 1, strings.Count(buf.String(), "\n"), "una entrada, una línea")
}

func TestLevel(t *testing.T) {
	require.Equal(t, slog.LevelDebug, Level("dev"))
	require.Equal(t, slog.LevelInfo, Level("prod"))
}
