# Gobernanza SQL y orden de migraciones

## Manifest

El archivo [`backend/sql/migrations_order.json`](../backend/sql/migrations_order.json) lista un **orden sugerido** de scripts. No sustituye el juicio del DBA: muchas sentencias son idempotentes o toleran “ya existe”.

**Advertencia:** `reset_dev_usuarios.sql` es destructivo para entornos de desarrollo; **no** ejecutarlo en producción.

## Aplicar un script manualmente

Desde la carpeta `backend`, con variables `DB_*` configuradas:

```text
python run_migration.py sql/add_minutos_estimados.sql
```

`run_migration.py` usa la misma `CONNECTION_STRING` que [`backend/database.py`](../backend/database.py) (incluye variables de entorno).

## Flag `IM_ALLOW_RUNTIME_DDL`

| Valor | Efecto |
|-------|--------|
| (vacío) en desarrollo | Igual que antes: la API puede crear tablas/columnas donde esté implementado. |
| (vacío) con `IM_ENV=production` | **Desactiva** DDL en runtime por defecto. |
| `1` / `true` | Fuerza DDL en runtime (solo si se acepta el riesgo). |
| `0` / `false` | Fuerza **sin** DDL en runtime (recomendado tras migraciones aplicadas). |

Ver también [`docs/DDL_RUNTIME_INVENTORY.md`](DDL_RUNTIME_INVENTORY.md).

## Próximos pasos recomendados (deuda técnica)

- Tabla de control de versión en BD (p. ej. `Tbl_App_Schema_Version`) y registro de scripts aplicados.
- Herramienta formal tipo Flyway/Liquibase si el equipo lo estandariza.
