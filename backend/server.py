"""
Arranque FastAPI — Industrial Manager API v60.0.
Las rutas viven en `routers/` (APIRouter). Lógica SQL sin cambios respecto al monolito previo.
"""
import ctypes
import os
import socket
import uvicorn
from contextlib import asynccontextmanager

from env_config import cors_allow_origins, validate_production_startup
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from audit_service import iniciar_auditoria
from auth_service import init_auth_db
from routers import (
    analytics,
    app_telemetry,
    auth,
    ayudas_visuales,
    bom,
    bom_despiece,
    cad,
    chat,
    catalog,
    config_api,
    dev_audit_feed,
    engineering,
    excel,
    gestor_tareas,
    historial,
    limpieza,
    mrp,
    proyectos,
    qa,
    root,
    usuarios,
    vins,
)

ADMIN_HOSTNAME = socket.gethostname()


@asynccontextmanager
async def lifespan(app: FastAPI):
    validate_production_startup()
    print(f"--- SERVER STARTED on {ADMIN_HOSTNAME} ---")
    print(f"--- LISTENING ON 0.0.0.0:8001 ---")
    iniciar_auditoria()
    try:
        init_auth_db()
    except Exception as e:
        print(f"ERROR INITIALIZING AUTH DB: {e}")
    yield
    print("--- SERVER SHUTTING DOWN ---")


app = FastAPI(title="Industrial Manager API v60.0", version="60.0", lifespan=lifespan)

_origins = cors_allow_origins()
_allow_credentials = "*" not in _origins
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_credentials=_allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

_hosts_raw = (os.environ.get("IM_TRUSTED_HOSTS") or "").strip()
if _hosts_raw:
    app.add_middleware(
        TrustedHostMiddleware,
        allowed_hosts=[h.strip() for h in _hosts_raw.split(",") if h.strip()],
    )

for _router in (
    root.router,
    config_api.router,
    proyectos.router,
    engineering.router,
    mrp.router,
    analytics.router,
    app_telemetry.router,
    vins.router,
    bom.router,
    bom_despiece.router,
    auth.router,
    usuarios.router,
    catalog.router,
    dev_audit_feed.router,
    excel.router,
    gestor_tareas.router,
    historial.router,
    limpieza.router,
    qa.router,
    chat.router,
    cad.router,
    ayudas_visuales.router,
):
    app.include_router(_router)


if __name__ == "__main__":
    # Banderas de la API de Windows: evitar suspensión y apagado de pantalla en el equipo servidor.
    ES_CONTINUOUS = 0x80000000
    ES_SYSTEM_REQUIRED = 0x00000001
    ES_DISPLAY_REQUIRED = 0x00000002
    try:
        ctypes.windll.kernel32.SetThreadExecutionState(
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED
        )
        print("🛡️ Prevención de suspensión de Windows: ACTIVADA.")
    except Exception as e:
        print(f"⚠️ No se pudo activar la prevención de suspensión: {e}")

    uvicorn.run(app, host="0.0.0.0", port=8001)
