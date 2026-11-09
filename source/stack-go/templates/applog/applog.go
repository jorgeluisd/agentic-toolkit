// Package applog arma el logger JSON del servicio con una lista cerrada de
// claves. Plantilla de stack-go: copiar a internal/platform/applog/.
package applog

import (
	"io"
	"log/slog"
)

var baseKeys = []string{
	slog.TimeKey, slog.LevelKey, slog.MessageKey,
	"service", "requestId", "method", "route", "status", "durationMs",
	"code", "errorType", "op", "attempt", "coachId",
}

// New descarta toda clave fuera de la lista y todo atributo dentro de un
// grupo: un slog.Any("player", p) puesto por error nunca llega a CloudWatch.
func New(w io.Writer, service string, level slog.Level, extraKeys ...string) *slog.Logger {
	allowed := make(map[string]bool, len(baseKeys)+len(extraKeys))
	for _, k := range append(baseKeys, extraKeys...) {
		allowed[k] = true
	}
	h := slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level: level,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) > 0 || !allowed[a.Key] {
				return slog.Attr{}
			}
			return a
		},
	})
	return slog.New(h).With(slog.String("service", service))
}

func Level(env string) slog.Level {
	if env == "dev" {
		return slog.LevelDebug
	}
	return slog.LevelInfo
}
