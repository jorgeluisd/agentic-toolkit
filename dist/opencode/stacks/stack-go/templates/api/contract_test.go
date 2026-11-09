package apigen

import (
	"fmt"
	"sort"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

// Plantilla de stack-go: copiar a internal/apigen/contract_test.go (no es
// código generado). Exige esquemas cerrados en todo el contrato.
func TestContract_SchemasAreClosed(t *testing.T) {
	spec, err := GetSpec()
	if err != nil {
		t.Fatal(err)
	}
	var problems []string
	seen := map[*openapi3.Schema]bool{}
	var visit func(name string, ref *openapi3.SchemaRef)
	visit = func(name string, ref *openapi3.SchemaRef) {
		if ref == nil || ref.Value == nil || seen[ref.Value] {
			return
		}
		s := ref.Value
		seen[s] = true
		switch {
		case s.Type.Is("object"):
			if s.AdditionalProperties.Has == nil || *s.AdditionalProperties.Has {
				problems = append(problems, name+": object sin additionalProperties: false")
			}
			for prop, p := range s.Properties {
				visit(name+"."+prop, p)
			}
		case s.Type.Is("string"):
			if s.MaxLength == nil && s.Format != "uuid" && s.Format != "date-time" && s.Format != "date" && len(s.Enum) == 0 {
				problems = append(problems, name+": string sin maxLength")
			}
		case s.Type.Is("array"):
			if s.MaxItems == nil {
				problems = append(problems, name+": array sin maxItems")
			}
			visit(name+"[]", s.Items)
		}
		for i, sub := range append(append(s.AllOf, s.OneOf...), s.AnyOf...) {
			visit(fmt.Sprintf("%s#%d", name, i), sub)
		}
	}
	for name, s := range spec.Components.Schemas {
		visit(name, s)
	}
	for path, item := range spec.Paths.Map() {
		for method, op := range item.Operations() {
			for _, p := range op.Parameters {
				visit(method+" "+path+" "+p.Value.Name, p.Value.Schema)
			}
			if op.RequestBody != nil {
				for _, media := range op.RequestBody.Value.Content {
					visit(method+" "+path+" body", media.Schema)
				}
			}
		}
	}
	sort.Strings(problems)
	for _, p := range problems {
		t.Error(p)
	}
}
