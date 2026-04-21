"""Routers FastAPI (Industrial Manager)."""
from . import analytics
from . import app_telemetry
from . import auth
from . import ayudas_visuales
from . import bom
from . import cad
from . import chat
from . import catalog
from . import config_api
from . import dev_audit_feed
from . import engineering
from . import excel
from . import gestor_tareas
from . import historial
from . import limpieza
from . import mrp
from . import proyectos
from . import qa
from . import root
from . import usuarios
from . import vins

__all__ = [
    'analytics',
    'app_telemetry',
    'auth',
    'ayudas_visuales',
    'bom',
    'cad',
    'chat',
    'catalog',
    'config_api',
    'dev_audit_feed',
    'engineering',
    'excel',
    'gestor_tareas',
    'historial',
    'limpieza',
    'mrp',
    'proyectos',
    'qa',
    'root',
    'usuarios',
    'vins',
]
