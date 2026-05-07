# Qué mover o preparar al iniciar la migración (backend + SQL dedicado)

Lista operativa para el día del cutover. **No incluir secretos reales** en Git; usar gestor de secretos o variables del servidor.

## SQL Server

- Instancia destino: host, puerto, nombre de base (`DB_DATABASE`, hoy por defecto `DB_Materiales_Industrial`).
- Autenticación: definir si se usa `Trusted_Connection` (solo red Windows) o **`DB_USER` / `DB_PASSWORD`** (recomendado en servidor dedicado fuera del dominio origen).
- Cifrado: `DB_ENCRYPT` (p. ej. `yes` en producción), `DB_TRUST_SERVER_CERTIFICATE` (evitar `yes` salvo certificado interno conocido).
- Contenido: backup completo + restore en servidor nuevo **o** réplica; aplicar scripts en orden razonable (ver `backend/sql/migrations_order.json` y `docs/GOBERNANZA_SQL.md`).
- Objetos fuera del repo: SQL Agent jobs, permisos, otras bases vinculadas.

## Backend (Python)

- Código: carpeta `backend/` + `python -m pip install -r requirements.txt` en el servidor.
- Variables mínimas en **producción** (`IM_ENV=production`):
  - `JWT_SECRET` (fuerte, distinto del valor de desarrollo).
  - `ADMIN_MASTER_PASSWORD`.
  - `CORS_ALLOW_ORIGINS` lista separada por comas (sin `*`).
  - Conexión: `DB_SERVER`, `DB_PORT`, `DB_DATABASE`, y si aplica `DB_USER`, `DB_PASSWORD`.
- Opcionales:
  - `IM_TRUSTED_HOSTS`: hosts permitidos (middleware Starlette).
  - `IM_ALLOW_RUNTIME_DDL=0` en producción tras aplicar migraciones SQL (sin CREATE/ALTER desde la API ni `iniciar_auditoria`).
  - `IM_ENABLE_LOCAL_FILE_LAUNCH=1` solo si se necesita `/api/system/open_file` en un equipo de confianza.
- Proceso: servicio Windows / reverse proxy con TLS según política de red.
- Puerto API: **8001** (coherente con `server.py` y `uvicorn`).

## Cliente (Flutter / escritorio)

- Rebuild con `--dart-define=API_BASE_URL=https://su-servidor:8001` (o el puerto expuesto tras proxy).
- CORS del backend debe incluir el origen real de la app si aplica (web); para ejecutable Windows el origen puede no ser navegador, pero mantenga CORS explícito en producción.

## Red y archivos

- Rutas UNC o unidades mapeadas (`Z:\` en ayudas/CAD): validar en el servidor y en puestos cliente.
- Google Sheets inventario PT: el servidor debe poder salida HTTPS de **solo lectura** al CSV público (política de proxy/firewall).

## Scripts actuales de “red compartida”

- `DESPLEGAR_A_RED.bat`, `EMPAQUETAR_RELEASE_PARA_RED.bat`, etc. sirven al modelo actual; en servidor dedicado conviene un runbook separado (ver `docs/RUNBOOK_SERVIDOR_DEDICADO.md`).

## Artefacto local en raíz

- `industrial_manager.db` (SQLite): verificar con el equipo si es solo desarrollo; no sustituye a SQL Server de producción.
