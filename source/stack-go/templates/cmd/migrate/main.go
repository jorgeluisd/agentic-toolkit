package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5"

	"github.com/OWNER/REPO/internal/platform/migrate"
)

func main() {
	schema := flag.Bool("schema", false, "imprime db/schema.sql para sqlc y sale")
	local := flag.Bool("local", false, "dialecto Postgres local (quita ASYNC)")
	flag.Parse()
	ms, err := migrate.Load(os.DirFS("db"), "migrations")
	if err != nil {
		log.Fatalf("migrate: %v", err)
	}
	if *schema {
		fmt.Print(migrate.Schema(ms))
		return
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatalf("migrate: conectar: %v", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	dialect := migrate.DSQL
	if *local {
		dialect = migrate.Postgres
	}
	n, err := migrate.Run(ctx, conn, dialect, ms)
	if err != nil {
		log.Fatalf("migrate: %v", err)
	}
	log.Printf("migrate: %d aplicadas", n) //nolint:gosec // G706: n es un conteo, no texto de afuera
}
