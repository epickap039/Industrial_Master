# Mapa de conexiones (stack Industrial Manager)

**Respaldo Git previo a migración de servidor:** commit `69a704d` en rama `v15.5_Clean_Rebuild` (mensaje: respaldo pre-migración). Para volver: `git checkout 69a704d` o `git revert` según política del equipo.

Los diagramas siguientes resumen **dependencias entre archivos y sistemas**, no cada endpoint.

---

## 1. Mapa mental (visión rápida)

```mermaid
mindmap
  root((Industrial Manager))
    Cliente Flutter
      lib/config/app_config.dart
      API_BASE_URL dart-define
      HTTPS HTTP a puerto 8001
    API FastAPI
      backend/server.py
        uvicorn 0.0.0.0:8001
        CORS env_config
        TrustedHost opcional
        lifespan auditoria auth
      Routers backend/routers/*.py
        REST WebSocket chat
    Nucleo backend
      env_config.py
        produccion JWT CORS DDL
      database.py
        pyodbc SQL Server
      jwt_tokens.py
      auth_service.py
      audit_service.py
      schema_guard.py
      admin_master_password.py
      user_context.py
    Datos y red
      SQL Server
      Google Sheets solo lectura catalog
      Rutas UNC CAD ayudas
    SQL repo
      backend/sql/
      migrations_order.json
```

---

## 2. Capas: de `server.py` hacia afuera

```mermaid
flowchart TB
  subgraph cliente["Cliente"]
    APP["Flutter: lib/config/app_config.dart\n(kApiBaseUrl / API_BASE_URL)"]
  end

  subgraph api["API"]
    SRV["server.py"]
    MW["CORSMiddleware + TrustedHostMiddleware\n(origen: env_config + IM_TRUSTED_HOSTS)"]
    LIFE["lifespan: validate_production_startup\niniciar_auditoria + init_auth_db"]
    SRV --> MW
    SRV --> LIFE
  end

  subgraph routers["routers/ (23 módulos)"]
    RALL["root, config_api, proyectos, engineering,\nmrp, analytics, app_telemetry, vins,\nbom, bom_despiece, auth, usuarios,\ncatalog, dev_audit_feed, excel,\ngestor_tareas, historial, limpieza,\nqa, chat, cad, ayudas_visuales"]
  end

  subgraph core["Núcleo Python"]
    ENV["env_config.py"]
    DB["database.py\n→ SQL Server"]
    JWT["jwt_tokens.py"]
    AUTH["auth_service.py\n→ database"]
    AUD["audit_service.py\n→ database + allow_runtime_ddl"]
    SCH["schema_guard.py\n(INFORMATION_SCHEMA, sin DDL)"]
    ADM["admin_master_password.py\n→ env_config fallback"]
    USR["user_context.py\n→ jwt_tokens"]
  end

  subgraph externo["Externo"]
    SQL[(SQL Server)]
    NET["Red: UNC, CSV Google Sheets"]
  end

  APP -->|"HTTP :8001"| SRV
  SRV --> RALL
  RALL --> DB
  RALL --> JWT
  RALL --> AUTH
  RALL --> AUD
  RALL --> SCH
  RALL --> ADM
  RALL --> USR
  DB --> ENV
  JWT --> ENV
  ADM --> ENV
  AUD --> ENV
  DB --> SQL
  LIFE --> AUD
  LIFE --> AUTH
  RALL -.-> NET
```

---

## 3. Quién usa qué (transversal)

| Archivo / concepto | Usado por |
|--------------------|-----------|
| `database.get_db_connection` | Casi todos los routers; `auth_service`, `audit_service`, `run_migration` |
| `env_config` | `server`, `database`, `jwt_tokens`, `admin_master_password`, `audit_service`, y routers: catalog, config_api, chat, app_telemetry, ayudas_visuales, excel (`allow_local_file_launch`) |
| `schema_guard` | `catalog` (columnas), `config_api`, `chat`, `app_telemetry` (tablas) |
| `jwt_tokens` | `auth`, `usuarios`, `dev_audit_feed`, `app_telemetry`; vía `user_context`: `bom`, `bom_despiece`, `cad`, `engineering`, `gestor_tareas`, `ayudas_visuales`, `limpieza`, `usuarios` |
| `auth_service` | `server` (init), `auth`, `usuarios` |
| `audit_service` | `server` (inicio), `catalog`, `config_api`, `excel`, `limpieza`, `qa`, `cad`, `gestor_tareas`, `ayudas_visuales` |
| `admin_master_password` | `gestor_tareas`, `ayudas_visuales` |
| `user_context.resolve_actor_user` | `bom`, `bom_despiece`, `cad`, `engineering`, `gestor_tareas`, `ayudas_visuales`, `usuarios`, `limpieza` |
| `bom_despiece_service` | `routers/bom_despiece` |

---

## 4. Scripts y documentación operativa

| Ruta | Relación |
|------|----------|
| `backend/run_migration.py` | Usa `database.CONNECTION_STRING` → SQL Server |
| `backend/sql/migrations_order.json` | Orden sugerido de scripts |
| `docs/MIGRACION_QUÉ_MOVER.md` | Checklist cutover |
| `docs/RUNBOOK_SERVIDOR_DEDICADO.md` | Variables, health, go-live |
| `docs/GOBERNANZA_SQL.md` | Política DDL / `IM_ALLOW_RUNTIME_DDL` |

---

*Generado para facilitar la migración a servidor dedicado; actualizar el diagrama si se añaden routers o módulos núcleo.*
