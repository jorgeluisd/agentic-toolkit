---
name: <producto>-invariants
description: "Invariantes del producto <producto> que el plugin no puede conocer: campo y helper de tenant, tablas y esquemas reales, reglas de negocio no negociables, puntos rojos de seguridad propios, checks que el verifier debe correr. Usar en cualquier tarea de este repositorio."
---

# Invariantes de <producto>

Prima sobre los defaults de `sdd-tdd-core` y del plugin de stack en lo que declare aquí. Máximo 10 invariantes; cada una con ADR y con su check mecánico.

## 1. Tenant
- Campo: `<tenant_field>` · Helper: `<TenantContext>.run(tenantId, fn)` · GUC: `app.tenant_id` (ADR-…)
- Origen: <claim del JWT | header validado contra tabla de membresías>.
- Roles: <lista> — se validan contra <fuente>.

## 2. Datos sensibles
- Clase alta: <campos> → cifrado envelope / blind index (ADR-…)
- PII plana permitida en: <tablas>; nunca en logs (paths de redact adicionales: …)

## 3. Reglas de negocio no negociables
1. <regla> — se prueba con <test> (ADR-…)
2. …

## 4. Integraciones y webhooks
| Proveedor | Firma | Encolado | Test |
|---|---|---|---|

## 5. Producción
- Marcadores (`SDD_PROD_MARKERS`): `<regex>`
- Entornos: staging `<…>` · producción `<…>` (nunca sin OK humano)

## 6. Checks adicionales del verifier
- [ ] <comando o grep> → <resultado esperado>

## 7. Esquema y migraciones
- Esquemas Postgres: <public | uno por contexto>
- Convenciones que difieren del plugin: <ninguna | …>
