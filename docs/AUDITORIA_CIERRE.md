# Cierre de auditoría (implementación del plan)

## Resumen ejecutivo

Se implementó la preparación para **servidor dedicado** en tres frentes: documentación operativa, configuración por entorno, y reducción de DDL/opciones inseguras en runtime. No sustituye un pen-test ni la política interna de backup/AD.

## Entregables en el repo

| Documento | Propósito |
|-----------|-----------|
| `docs/AUDITORIA_INVENTARIO.md` | Inventario por dominios y matriz de seguimiento. |
| `docs/MIGRACION_QUÉ_MOVER.md` | Checklist de cutover SQL/backend/cliente. |
| `docs/DDL_RUNTIME_INVENTORY.md` | Lista de mutaciones de esquema desde código. |
| `docs/GOBERNANZA_SQL.md` | Orden de migraciones, flag DDL, uso de `run_migration.py`. |
| `docs/RUNBOOK_SERVIDOR_DEDICADO.md` | Variables, health, Go-Live. |
| `backend/sql/migrations_order.json` | Orden sugerido de scripts (ajustable). |

## Cambios de código relevantes

- **`backend/env_config.py`**: Producción (`IM_ENV=production`) exige JWT, contraseña maestra y CORS explícito; flags `IM_ALLOW_RUNTIME_DDL`, `IM_ENABLE_LOCAL_FILE_LAUNCH`.
- **`backend/server_validation`**: `validate_production_startup()` en el `lifespan`; CORS desde env; `TrustedHostMiddleware` opcional; credenciales CORS desactivadas si hay `*`.
- **`backend/database.py`**: Construcción de cadena desde variables de entorno; mensaje genérico al cliente ante fallo de conexión.
- **`backend/jwt_tokens.py` / `admin_master_password.py`**: Constantes de fallback centralizadas para comparación en validación.
- **`backend/audit_service.py`**: Respeta `IM_ALLOW_RUNTIME_DDL`.
- **Routers** (`chat`, `config_api`, `app_telemetry`, `catalog`, `ayudas_visuales`): sin DDL automático cuando el flag lo prohíbe (503 con pista de migración).
- **`backend/routers/excel.py`**: `open_file` bloqueado salvo `IM_ENABLE_LOCAL_FILE_LAUNCH`.
- **`backend/routers/gestor_tareas.py`**: Checklists cargados en lote (menos idas a SQL en `/api/tareas/lista`).
- **`backend/routers/catalog.py`**: Sync stock PT con `UPDATE … JOIN (VALUES …)` por chunks.
- **`backend/run_migration.py`**: Usa `CONNECTION_STRING` unificada y acepta ruta del `.sql` como argumento.
- **Puerto documentado** en `backend/VOZ_GUIA_RAPIDA.md` y `backend/test_voz_curl.ps1` → **8001**.

## Riesgos pendientes (no cerrados en este trabajo)

- **Autorización**: Muchos endpoints mutables siguen sin un modelo uniforme JWT + roles; conviene una pasada con dependencias FastAPI y matriz por ruta.
- **Contraseñas usuario**: `auth_service` sigue con SHA-256; migración a bcrypt/argon2 es deuda conocida.
- **CAD / otros `os.startfile`**: Revisar `backend/routers/cad.py` y similares para política en servidor dedicado.
- **SQLite `industrial_manager.db`**: Confirmar uso real antes del cutover.

## Criterio de aceptación sugerido

- Arranque en `IM_ENV=production` con variables requeridas **sin** error.
- Con `IM_ALLOW_RUNTIME_DDL=0`, esquema al día: API responde sin 503 en rutas críticas.
- Smoke tests documentados en runbook ejecutados tras despliegue.
