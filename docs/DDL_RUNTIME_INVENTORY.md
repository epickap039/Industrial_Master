# Inventario de DDL y mutación de esquema en runtime

Estos puntos crean o alteran objetos en SQL Server durante la vida del proceso (no solo en scripts de despliegue).

| Ubicación | Comportamiento | Notas |
|-----------|----------------|--------|
| `backend/audit_service.py` — `iniciar_auditoria()` | Varios `CREATE TABLE` si faltan | Con `IM_ALLOW_RUNTIME_DDL=0` **no se ejecuta** (solo log). Equivalente debe estar en migraciones SQL. |
| `backend/routers/chat.py` | `Tbl_Chat_Mensajes` + índices | Con `IM_ALLOW_RUNTIME_DDL=0`: error 503 si falta la tabla; usar `backend/sql/add_chat_interno_tables.sql`. |
| `backend/routers/config_api.py` | `Tbl_App_Manual` | Mismo patrón; DDL manual o flag de desarrollo. |
| `backend/routers/app_telemetry.py` | `Tbl_App_Uso_Eventos` | Mismo patrón. |
| `backend/routers/catalog.py` | Columnas `Stock_PT_*` en `Tbl_Maestro_Piezas` | Con `IM_ALLOW_RUNTIME_DDL=0`: 503 si faltan; usar `add_maestro_stock_pt_almacen.sql`. |
| `backend/routers/ayudas_visuales.py` | `ALTER TABLE` varias columnas ayudas | Con `IM_ALLOW_RUNTIME_DDL=0`: 503 con mensaje que cita el `.sql` correspondiente. |
| `backend/crear_admin.py`, `backend/crear_reporte_modulo.py` | DDL SQLite/SQL utilitario | Scripts de mantenimiento, no el path del API en producción. |

## Objetivo en servidor dedicado

1. Aplicar migraciones desde `backend/sql/` (y scripts grandes `migrate_v60*.sql` si aplica) **antes** de poner `IM_ALLOW_RUNTIME_DDL=0`.
2. Desactivar DDL en runtime en producción para evitar carreras y drift de esquema.
3. Mantener este inventario al añadir nuevos `_ensure_*` en routers.
