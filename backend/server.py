"""
Arranque FastAPI — Industrial Manager API v60.0.
Las rutas viven en `routers/` (APIRouter). Lógica SQL sin cambios respecto al monolito previo.
"""
import ctypes
import socket
import uvicorn
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from audit_service import iniciar_auditoria
from auth_service import init_auth_db
from routers import (
    analytics,
    auth,
    ayudas_visuales,
    bom,
    cad,
    catalog,
    config_api,
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

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

for _router in (
    root.router,
    config_api.router,
    proyectos.router,
    engineering.router,
    mrp.router,
    analytics.router,
    vins.router,
    bom.router,
    auth.router,
    usuarios.router,
    catalog.router,
    excel.router,
    gestor_tareas.router,
    historial.router,
    limpieza.router,
    qa.router,
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
