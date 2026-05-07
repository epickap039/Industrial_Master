# Runbook: servidor dedicado (API + SQL)

## Puertos y URLs coherentes

- API escucha en **8001** (`backend/server.py` / `uvicorn`).
- Pruebas de voz: `backend/test_voz_curl.ps1` y `backend/VOZ_GUIA_RAPIDA.md` usan `8001`.

## Variables de entorno (resumen)

| Variable | Uso |
|----------|-----|
| `IM_ENV` | `production` activa validaciones estrictas al arrancar. |
| `JWT_SECRET` | Firma JWT; obligatorio y no trivial en producción. |
| `ADMIN_MASTER_PASSWORD` | Operaciones destructivas con contraseña maestra. |
| `CORS_ALLOW_ORIGINS` o `IM_CORS_ORIGINS` | Lista separada por comas; **sin** `*` en producción. |
| `IM_TRUSTED_HOSTS` | Opcional; lista de `Host` permitidos (middleware). |
| `DB_SERVER`, `DB_PORT`, `DB_DATABASE` | SQL Server destino. |
| `DB_USER`, `DB_PASSWORD` | Opcional; si falta, se usa `Trusted_Connection=yes`. |
| `DB_ENCRYPT`, `DB_TRUST_SERVER_CERTIFICATE` | Cifrado y confianza del certificado del servidor SQL. |
| `IM_ALLOW_RUNTIME_DDL` | Ver `docs/GOBERNANZA_SQL.md`. |
| `IM_ENABLE_LOCAL_FILE_LAUNCH` | `1` solo si debe habilitarse `POST /api/system/open_file`. |

## Health

- `GET /api/health` (router `root`) — validar en balanceador o script de smoke test post-despliegue.

## Backup y restauración

- Antes de cambios de esquema o cutover: backup completo de la base en el **servidor SQL dedicado**.
- Documentar ruta, retención y una **prueba de restauración** fechada.
- Scripts como `backend/sql/purga_fantasmas.sql` exigen backup previo por política interna.

## Cliente Flutter

- Build con `API_BASE_URL` apuntando al nuevo host (`lib/config/app_config.dart`, `--dart-define`).

## Checklist corto Go-Live

1. Migraciones SQL aplicadas y `IM_ALLOW_RUNTIME_DDL=0` en producción (si se adopta política sin DDL).
2. Secretos y CORS configurados; arranque no lanza `RuntimeError` de `validate_production_startup()`.
3. Firewall abre solo origen necesario hacia 8001 o hacia el reverse proxy.
4. Smoke: login, listado catálogo, lista de tareas, chat si aplica.
5. Plan de rollback (versión anterior del backend + restore BD si procede).
