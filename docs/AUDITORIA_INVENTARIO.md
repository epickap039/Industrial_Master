# Inventario del repositorio (auditoría)

Generado como parte del plan de auditoría / migración a servidor dedicado. Cuentas aproximadas por dominio.

| Dominio | Archivos (aprox.) | Notas |
|--------|-------------------|--------|
| Backend Python (`backend/**/*.py`) | 51 | API FastAPI, routers, scripts auxiliares |
| SQL versionado (`backend/sql/*.sql`) | 20 + `migrations_order.json` | Migraciones incrementales; ver gobernanza |
| Migraciones sueltas en `backend/` | `migrate_v60.sql`, `migrate_v60_fix.sql` | Revisar orden respecto a `backend/sql/` |
| Flutter (`lib/**/*.dart`) | 83 | Cliente; `lib/config/app_config.dart` define `API_BASE_URL` |
| Scripts (`scripts/**/*`) | 18 | Herramientas Python/PowerShell/BAT |
| UAT / herramientas (`tool/**/*`) | 13 | Checklists JSON/MD, scripts ensamblado |
| Raíz del repo | Muchos `.bat`, `.md`, `.txt`, `industrial_manager.db` | Documentación operativa y artefactos locales |

## Matriz de revisión por dominio (estado)

| Área | Revisión documentada | Cambios aplicados en código |
|------|----------------------|-----------------------------|
| Seguridad HTTP (CORS, secretos, arranque producción) | `RUNBOOK_SERVIDOR_DEDICADO.md` | `env_config.py`, `server.py`, `jwt_tokens.py`, `admin_master_password.py`, `excel.py` (`open_file`) |
| Conexión SQL | Misma runbook | `database.py` (env + mensajes de error) |
| DDL en runtime | `DDL_RUNTIME_INVENTORY.md` | Flag `IM_ALLOW_RUNTIME_DDL`, guards en routers + `audit_service.py` |
| Rendimiento lista tareas / sync PT | `AUDITORIA_CIERRE.md` | `gestor_tareas.py` (1 consulta checklist), `catalog.py` (UPDATE por lotes) |
| Migraciones | `GOBERNANZA_SQL.md` | `run_migration.py`, `migrations_order.json` |
| Cliente Flutter | Este inventario | Default `API_BASE_URL` documentado en runbook |

## Archivos de entrada prioritarios (plan original)

- `backend/server.py`, `backend/database.py`, `backend/jwt_tokens.py`, `backend/admin_master_password.py`
- `backend/routers/*` (toda la superficie API)
- `backend/sql/*`, `backend/migrate_v60*.sql`
- `lib/config/app_config.dart`, `lib/services/api_client.dart`
- Scripts de despliegue en raíz y `tool/uat/*`
