package archtest

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Puertos sin datos de un tenant. Cada entrada lleva el porqué; la lista se
// revisa en el PR que la toca.
var tenantlessPorts = map[string]string{
	"Clock":     "el reloj no tiene tenant",
	"Generator": "los IDs no tienen tenant",
}

// tenantViolations recibe un archivo de application y devuelve cada método de
// interface que recibe context.Context pero no tenant.ID como segundo argumento.
func tenantViolations(f *ast.File, name string) []string {
	var found []string
	ast.Inspect(f, func(n ast.Node) bool {
		spec, ok := n.(*ast.TypeSpec)
		if !ok {
			return true
		}
		iface, ok := spec.Type.(*ast.InterfaceType)
		if !ok || tenantlessPorts[spec.Name.Name] != "" {
			return true
		}
		for _, m := range iface.Methods.List {
			fn, ok := m.Type.(*ast.FuncType)
			if !ok || len(m.Names) == 0 {
				continue
			}
			params := flatParams(fn)
			if len(params) > 0 && params[0] == "context.Context" && (len(params) < 2 || params[1] != "tenant.ID") {
				found = append(found, name+": "+spec.Name.Name+"."+m.Names[0].Name+" no recibe tenant.ID después del ctx")
			}
		}
		return true
	})
	return found
}

func flatParams(fn *ast.FuncType) []string {
	var out []string
	for _, field := range fn.Params.List {
		typ := exprString(field.Type)
		for range max(len(field.Names), 1) {
			out = append(out, typ)
		}
	}
	return out
}

func exprString(e ast.Expr) string {
	switch t := e.(type) {
	case *ast.SelectorExpr:
		return exprString(t.X) + "." + t.Sel.Name
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return "*" + exprString(t.X)
	default:
		return ""
	}
}

var (
	queryName    = regexp.MustCompile(`(?m)^-- name: (\w+)`)
	tenantFilter = regexp.MustCompile(`(?i)\bcoach_id\s*=\s*(@coach_id|sqlc\.arg\(\s*coach_id\s*\)|\$\d+)`)
	globalMark   = regexp.MustCompile(`(?m)^-- tenant: global — .+`)
)

// queryViolations exige el filtro de tenant en cada query de sqlc. Una query
// sin tenant lleva "-- tenant: global — <porqué>" debajo de su "-- name:".
func queryViolations(sql, name string) []string {
	var found []string
	idx := queryName.FindAllStringSubmatchIndex(sql, -1)
	for i, m := range idx {
		end := len(sql)
		if i+1 < len(idx) {
			end = idx[i+1][0]
		}
		body := sql[m[0]:end]
		if !tenantFilter.MatchString(body) && !globalMark.MatchString(body) {
			found = append(found, name+": "+sql[m[2]:m[3]]+" no filtra por coach_id")
		}
	}
	return found
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	return strings.TrimSpace(goList(t, "-m", "-f", "{{.Dir}}"))
}

func TestPorts_TakeTenantAfterContext(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(moduleRoot(t), "internal", "*", "application", "*.go"))
	fset := token.NewFileSet()
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		for _, v := range tenantViolations(f, path) {
			t.Error(v)
		}
	}
}

func TestQueries_FilterByTenant(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(moduleRoot(t), "internal", "*", "adapters", "postgres", "queries", "*.sql"))
	for _, path := range files {
		sql, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range queryViolations(string(sql), path) {
			t.Error(v)
		}
	}
}

func TestTenantChecks_Bite(t *testing.T) {
	src := `package application
type Matches interface {
	Get(ctx context.Context, t tenant.ID, id string) error
	Leak(ctx context.Context, id string) error
	Swapped(ctx context.Context, id string, t tenant.ID) error
}
type Clock interface { Now() time.Time }`
	f, err := parser.ParseFile(token.NewFileSet(), "ports.go", src, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := tenantViolations(f, "ports.go"); len(got) != 2 {
		t.Errorf("tenantViolations() = %v, want Leak y Swapped", got)
	}

	sql := "-- name: GetMatch :one\nSELECT * FROM matches WHERE coach_id = @coach_id AND id = @id;\n\n" +
		"-- name: LeakMatch :one\nSELECT * FROM matches WHERE id = @id;\n\n" +
		"-- name: CountTenants :one\n-- tenant: global — métrica interna sin datos por tenant\nSELECT count(DISTINCT coach_id) FROM matches;\n"
	if got := queryViolations(sql, "q.sql"); len(got) != 1 || !strings.Contains(got[0], "LeakMatch") {
		t.Errorf("queryViolations() = %v, want solo LeakMatch", got)
	}
}
