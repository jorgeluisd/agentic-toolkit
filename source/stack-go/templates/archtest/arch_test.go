// Package archtest verifica la matriz de imports del propio módulo por capa y
// contexto, que depguard no puede expresar. Plantilla de stack-go: copiar a
// internal/archtest/arch_test.go. Corre con <test>, sin Docker.
package archtest

import (
	"bufio"
	"bytes"
	"os/exec"
	"strings"
	"testing"
)

type layer string

const (
	layerKernel      layer = "kernel"
	layerPlatform    layer = "platform"
	layerContract    layer = "contract"
	layerDomain      layer = "domain"
	layerApplication layer = "application"
	layerAdapter     layer = "adapter"
	layerFakes       layer = "fakes"
	layerCmd         layer = "cmd"
	layerArchtest    layer = "archtest"
	layerUnknown     layer = "unknown"
)

type pkg struct {
	layer layer
	ctx   string
}

func classify(rel string) pkg {
	parts := strings.Split(rel, "/")
	switch {
	case parts[0] == "cmd":
		return pkg{layer: layerCmd}
	case len(parts) < 2 || parts[0] != "internal":
		return pkg{layer: layerUnknown}
	case parts[1] == "kernel":
		return pkg{layer: layerKernel}
	case parts[1] == "platform":
		return pkg{layer: layerPlatform}
	case parts[1] == "apigen":
		return pkg{layer: layerContract}
	case parts[1] == "archtest":
		return pkg{layer: layerArchtest}
	case len(parts) < 3:
		return pkg{layer: layerUnknown, ctx: parts[1]}
	}
	ctx := parts[1]
	switch {
	case parts[2] == "domain":
		return pkg{layer: layerDomain, ctx: ctx}
	case parts[2] == "application":
		return pkg{layer: layerApplication, ctx: ctx}
	case parts[2] == "adapters" && len(parts) >= 4:
		return pkg{layer: layerAdapter, ctx: ctx}
	case parts[2] == ctx+"test" && len(parts) == 3:
		return pkg{layer: layerFakes, ctx: ctx}
	}
	return pkg{layer: layerUnknown, ctx: ctx}
}

// allowed es la matriz de la skill onion-screaming-architecture §2. Los fakes
// nunca son destino válido: go list no incluye en Imports los de los _test.go.
func allowed(from, to pkg) bool {
	same := from.ctx == to.ctx
	switch {
	case to.layer == layerCmd, to.layer == layerUnknown, to.layer == layerArchtest, to.layer == layerFakes:
		return false
	case from.layer == layerCmd:
		return true
	}
	switch from.layer {
	case layerKernel:
		return to.layer == layerKernel
	case layerPlatform:
		return to.layer == layerKernel || to.layer == layerPlatform
	case layerContract:
		return to.layer == layerContract
	case layerDomain:
		return to.layer == layerKernel || (to.layer == layerDomain && same)
	case layerApplication, layerFakes:
		return to.layer == layerKernel || (same && (to.layer == layerDomain || to.layer == layerApplication))
	case layerAdapter:
		return adapterMayImport(to, same)
	default:
		return false
	}
}

func adapterMayImport(to pkg, same bool) bool {
	switch to.layer {
	case layerKernel, layerPlatform, layerContract, layerApplication:
		return true
	case layerDomain, layerAdapter:
		return same
	default:
		return false
	}
}

type edge struct{ from, to string }

func violations(packages []string, imports []edge) []string {
	var found []string
	for _, p := range packages {
		if classify(p).layer == layerUnknown {
			found = append(found, p+": paquete fuera de la taxonomía (moverlo a su capa)")
		}
	}
	for _, e := range imports {
		if !allowed(classify(e.from), classify(e.to)) {
			found = append(found, e.from+" → "+e.to)
		}
	}
	return found
}

func goList(t *testing.T, args ...string) string {
	t.Helper()
	out, err := exec.CommandContext(t.Context(), "go", append([]string{"list"}, args...)...).Output()
	if err != nil {
		t.Fatalf("go list %v: %v", args, err)
	}
	return string(out)
}

func loadModule(t *testing.T) (module string, packages []string, imports []edge) {
	t.Helper()
	module = strings.TrimSpace(goList(t, "-m"))
	out := goList(t, "-f", `{{.ImportPath}}{{range .Imports}} {{.}}{{end}}`, module+"/...")
	sc := bufio.NewScanner(bytes.NewReader([]byte(out)))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		from, ok := strings.CutPrefix(fields[0], module+"/")
		if !ok {
			continue
		}
		packages = append(packages, from)
		for _, imp := range fields[1:] {
			if to, ok := strings.CutPrefix(imp, module+"/"); ok {
				imports = append(imports, edge{from, to})
			}
		}
	}
	return module, packages, imports
}

func TestModule_RespectsImportMatrix(t *testing.T) {
	_, packages, imports := loadModule(t)
	if len(packages) < 2 {
		t.Fatalf("go list encontró %d paquetes: el test pasaría vacío", len(packages))
	}
	for _, v := range violations(packages, imports) {
		t.Error(v)
	}
}

func TestBinary_DoesNotLinkFakes(t *testing.T) {
	module, _, _ := loadModule(t)
	for _, dep := range strings.Fields(goList(t, "-deps", "-tags", "lambda.norpc", module+"/cmd/...")) {
		if r, ok := strings.CutPrefix(dep, module+"/"); ok && classify(r).layer == layerFakes {
			t.Errorf("cmd enlaza %s", r)
		}
	}
}

func TestAllowed_EachRuleBites(t *testing.T) {
	cases := []struct {
		from, to string
		want     bool
	}{
		{"internal/matches/domain", "internal/kernel/errs", true},
		{"internal/matches/domain/score", "internal/matches/domain", true},
		{"internal/matches/domain", "internal/matches/application", false},
		{"internal/matches/domain", "internal/platform/log", false},
		{"internal/matches/domain", "internal/roster/domain", false},
		{"internal/matches/application", "internal/matches/domain", true},
		{"internal/matches/application", "internal/matches/adapters/postgres", false},
		{"internal/matches/application", "internal/platform/db", false},
		{"internal/matches/application", "internal/roster/application", false},
		{"internal/matches/adapters/postgres", "internal/platform/db", true},
		{"internal/matches/adapters/http", "internal/apigen", true},
		{"internal/matches/adapters/http", "internal/matches/application", true},
		{"internal/matches/adapters/rosterclient", "internal/roster/application", true},
		{"internal/matches/adapters/rosterclient", "internal/roster/domain", false},
		{"internal/matches/adapters/http", "internal/roster/adapters/http", false},
		{"internal/matches/adapters/postgres", "internal/matches/matchestest", false},
		{"internal/matches/matchestest", "internal/matches/application", true},
		{"internal/platform/auth", "internal/kernel/tenant", true},
		{"internal/platform/auth", "internal/matches/domain", false},
		{"internal/kernel/errs", "internal/platform/log", false},
		{"internal/apigen", "internal/kernel/errs", false},
		{"cmd/api", "internal/matches/adapters/postgres", true},
		{"internal/platform/db", "cmd/api", false},
		{"internal/matches/adapters/http", "internal/matches/util", false},
	}
	for _, tc := range cases {
		t.Run(tc.from+"→"+tc.to, func(t *testing.T) {
			if got := allowed(classify(tc.from), classify(tc.to)); got != tc.want {
				t.Errorf("allowed() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestClassify_FlagsUnknownPackages(t *testing.T) {
	for _, p := range []string{"internal/utils", "internal/matches/services", "pkg/helpers", "internal/matches/adapters"} {
		if got := classify(p).layer; got != layerUnknown {
			t.Errorf("classify(%q) = %s, want unknown", p, got)
		}
	}
}
