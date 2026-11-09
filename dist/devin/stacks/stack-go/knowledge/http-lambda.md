# http-lambda

**Cuándo aplica (trigger de la entrada de Knowledge):** Una sola Lambda en Go detrás de API Gateway HTTP API: chi + aws-lambda-go-api-proxy (httpadapter.NewV2), router armado desde el contrato OpenAPI, orden de middlewares (request id, log de acceso, recover, headers, límite de body, validación del contrato, JWT de Cognito con lestrrat-go/jwx y rol por operationId con middleware propio), init liviano para arranque en frío mínimo, servidor local con el mismo router, y build arm64 provided.al2023 con binario bootstrap. Usar cuando se agrega una ruta o middleware, se toca cmd/api, el arranque, el build o el empaquetado de la Lambda.

---

# HTTP en Lambda: chi + api-proxy

La API es **un binario** y **una Lambda** (`cmd/api`), y el router es un `http.Handler` común de chi. `aws-lambda-go-api-proxy` traduce el evento de API Gateway HTTP API (payload v2) a `*http.Request`. Por eso todo el borde HTTP se prueba con `httptest`, sin Lambda ni AWS. Plantillas: `templates/httpx/` (problem+json y middlewares) y `templates/auth/` (Cognito y rol).

## 1. Composition root

```go
func main() {
	ctx := context.Background()
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Fatalf("api: config: %v", err)
	}
	logger := applog.New(os.Stdout, cfg.Service, applog.Level(cfg.Env))
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatalf("api: aws: %v", err)
	}
	pool, err := db.NewDSQLPool(ctx, db.DSQLConfig{Endpoint: cfg.DSQLEndpoint, Region: awsCfg.Region, User: "app", Credentials: awsCfg.Credentials})
	if err != nil {
		log.Fatalf("api: db: %v", err)
	}
	verifier, err := auth.NewVerifier(ctx, auth.Config{
		Issuer: auth.CognitoIssuer(awsCfg.Region, cfg.UserPoolID), ClientID: cfg.ClientID, TenantClaim: "coach_id",
	}, httprc.NewClient())
	if err != nil {
		log.Fatalf("api: auth: %v", err)
	}
	router, err := newRouter(logger, verifier, wire(pool, awsCfg, cfg))
	if err != nil {
		log.Fatalf("api: router: %v", err)
	}
	if os.Getenv("AWS_LAMBDA_RUNTIME_API") == "" {
		log.Fatal(http.ListenAndServe("127.0.0.1:8080", router)) // desarrollo local: mismo router
	}
	lambda.Start(httpadapter.NewV2(router).ProxyWithContext)
}
```

| Regla | Cómo se verifica |
|---|---|
| `aws-lambda-go` y `aws-lambda-go-api-proxy` solo en `cmd/` | `<lint>`: depguard `lambda-only-in-cmd` |
| Payload v2 (HTTP API): `httpadapter.NewV2`. Con REST API sería `httpadapter.New` (v1); no se mezclan | Revisión de `cmd/api` contra la infraestructura (CDK) |
| Un error del init es `log.Fatalf` con qué falló, nunca con el valor de una variable | Revisión; la config valida y nombra la variable (skill `security-baseline` §3) |
| El servidor local (`AWS_LAMBDA_RUNTIME_API` vacío) escucha solo en `127.0.0.1` | `grep -n 'ListenAndServe' cmd/api` muestra `127.0.0.1` |

## 2. Router y orden de middlewares

El router lo arma `newRouter` (plantilla `templates/cmd/api/router.go`) **desde el contrato**: las rutas, la validación y los roles salen de `api/openapi.yaml` (skill `api-contract-openapi` §3). Ninguna ruta se registra a mano.

```go
func newRouter(log *slog.Logger, v auth.TokenVerifier, server apigen.StrictServerInterface) (http.Handler, error) {
	spec, err := apigen.GetSpec()
	// ...
	ops, err := auth.OperationsFromSpec(spec, "cognito") // operationId → público | roles
	// ...
	r := chi.NewRouter()
	r.Use(httpx.WithRequestID(uuid.NewString), httpx.AccessLog(log, time.Now), httpx.Recover(log),
		httpx.SecureHeaders, httpx.LimitBody(httpx.MaxBodyBytes))
	r.Use(oapimw.OapiRequestValidatorWithOptions(spec, &oapimw.Options{ /* 400 REQUEST_INVALID, 404 ROUTE_NOT_FOUND */ }))
	authz := func(f apigen.StrictHandlerFunc, operationID string) apigen.StrictHandlerFunc { /* ops.Check → Principal en ctx */ }
	h := apigen.NewStrictHandlerWithOptions(server, []apigen.StrictMiddlewareFunc{authz}, apigen.StrictHTTPServerOptions{ /* → httpx.WriteError */ })
	return apigen.HandlerFromMux(h, r), nil
}
```

Orden, de afuera hacia adentro: **request id → log de acceso → recover → headers → límite de body → validación del contrato → autenticación y rol (por `operationId`) → handler**. El log de acceso va por fuera de `Recover`, así también registra el 500. La validación va antes de la autenticación: un request mal formado no llega a verificar el token.

| Regla | Cómo se verifica |
|---|---|
| Toda operación declara `security` en el contrato; sin eso la Lambda no arranca | `TestOperationsFromSpec_FailsWhenAnOperationDoesNotDeclareSecurity` |
| Los roles por operación salen del contrato; la autorización fina va en application (skill `application-cqrs` §5) | `TestRouter_EnforcesTheContract`: una fila de rol permitido y otra de rol denegado por operación |
| Un request que el contrato no permite → 400; una ruta inexistente → 404, siempre problem+json | Filas `campo de más`, `minuto fuera de rango` y `ruta inexistente` del mismo test |
| `auth.Authenticate` y `auth.RequireRole` quedan para rutas fuera del contrato (salud interna, por ejemplo), que se declaran en `newRouter` con un comentario del porqué | Revisión: toda ruta registrada a mano en `cmd/api` tiene su comentario y su test |
| CORS en API Gateway (orígenes de la PWA), no en la Lambda | Config de CDK; ninguna Lambda escribe `Access-Control-Allow-Origin` |

## 3. JWT de Cognito

`auth.Verifier` (plantilla) valida un **access token** RS256 del pool: firma contra el JWKS cacheado (`jwk.NewCache` + `CachedSet`), `iss`, `exp` con tolerancia, `token_use = access` y `client_id`. Después arma el `Principal` con `sub`, el tenant del claim configurado y los grupos `cognito:groups` como roles. Rechaza `alg: none`, claves ajenas, ID tokens y otro app client. Los roles de Citados son grupos de Cognito: profe, ayudante, delegado y padre. Ser "delegado de *esta* categoría" o "padre de *este* alumno" es autorización fina, con datos. **Cómo se verifica:** `TestVerify_RejectsEachInvalidToken`, `TestOperationsCheck` y `TestMiddlewares_AuthenticateThenRequireRole` de la plantilla. No se usa casbin: con cuatro roles y la autorización fina en application, un middleware de 20 líneas se lee y se prueba entero.

## 4. Handlers

Un handler HTTP traduce y nada más: valida la forma del request, arma el command con el tenant del `Principal`, llama a application y escribe la respuesta. Con oapi-codegen, el handler implementa la interfaz estricta generada (skill `api-contract-openapi`), y los errores de decodificación y de respuesta van a `httpx.WriteError`.

```go
func (h Matches) RecordGoal(ctx context.Context, req apigen.RecordGoalRequestObject) (apigen.RecordGoalResponseObject, error) {
	p, ok := auth.FromContext(ctx)
	if !ok {
		return nil, auth.ErrUnauthenticated
	}
	cmd, err := toRecordGoal(p, req)
	if err != nil {
		return nil, err
	}
	res, err := h.Record.Handle(ctx, cmd)
	if err != nil {
		return nil, err
	}
	return apigen.RecordGoal200JSONResponse(toGoalResponse(res)), nil
}
```

## 5. Arranque en frío mínimo

| Regla | Por qué | Cómo se verifica |
|---|---|---|
| En el init solo se lee la config, se carga `aws.Config`, se arma el pool **sin conectar** y se registra el JWKS (una descarga) | Todo lo que va en el init lo paga la primera request | Línea `REPORT` de CloudWatch: `Init Duration` p95 ≤ 250 ms; alarma si se pasa |
| Ni migraciones, ni conexión eager a la DB, ni lecturas de SSM por request | Lo caro va una sola vez o a otro proceso | `grep -rn 'migrate\.' cmd/api` vacío |
| SSM: un `GetParameters` en lote en el init (skill `security-baseline` §3) | Una llamada en vez de N | Revisión de `cmd/api` |
| Sin reflexión pesada ni frameworks de DI; dependencias mínimas | El tamaño del binario y la inicialización de paquetes cuestan | En el PR que agrega un módulo, comparar la cantidad de líneas de `go list -deps ./cmd/api` antes y después |
| Memoria de la Lambda ≥ 512 MB | La CPU escala con la memoria; con poca CPU el init y el TLS a DSQL tardan más | Config de CDK |

El objetivo del producto (API con Lambda fría < 500 ms) se mide en staging con una invocación fría por deploy, no se supone.

## 6. Build y empaquetado

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -tags lambda.norpc -trimpath -ldflags='-s -w' -o build/bootstrap ./cmd/api
(cd build && zip -X -q ../dist/api.zip bootstrap)
```

- Runtime `provided.al2023`, arquitectura `arm64`, handler `bootstrap` (el nombre del binario es obligatorio en runtimes `provided`).
- `lambda.norpc` saca el servidor RPC del runtime viejo `go1.x`, que en `provided.al2023` no se usa.
- `-trimpath` y `zip -X` dan un artefacto reproducible: mismo commit → mismo `CodeSha256`.

**Cómo se verifica:** el job de build del CI (`templates/ci.yml`) produce `bootstrap` y `file build/bootstrap` reporta `ELF 64-bit LSB executable, ARM aarch64, statically linked`.

## 7. Tests del borde

- Handler y middlewares con `httptest.NewRecorder` y el router real armado con fakes de application. Sin evento de Lambda.
- Un único test de humo del adaptador: `httpadapter.NewV2(router).ProxyWithContext(ctx, events.APIGatewayV2HTTPRequest{...})` con una ruta pública, para fijar que la traducción v2 llega al router. Vive en `cmd/api/main_test.go`, el único lugar donde la librería de Lambda está permitida.

## 8. Checklist

- [ ] ¿Operación nueva declarada en el contrato con su `security`, y con filas de rol permitido y denegado en el test de router?
- [ ] ¿Orden de middlewares de §2?
- [ ] ¿El handler solo traduce, y el tenant sale del `Principal`?
- [ ] ¿Nada nuevo en el init que conecte, migre o lea secretos por request?
- [ ] ¿Build `arm64` + `provided.al2023` + `bootstrap` + `lambda.norpc`, reproducible?
- [ ] ¿Tests con `httptest` y un humo del adaptador v2?
