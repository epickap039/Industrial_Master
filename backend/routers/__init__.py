"""Routers FastAPI (Industrial Manager)."""
from . import analytics
from . import auth
from . import bom
from . import cad
from . import catalog
from . import config_api
from . import engineering
from . import excel
from . import historial
from . import limpieza
from . import mrp
from . import proyectos
from . import qa
from . import root
from . import vins

__all__ = [
    'analytics',
    'auth',
    'bom',
    'cad',
    'catalog',
    'config_api',
    'engineering',
    'excel',
    'historial',
    'limpieza',
    'mrp',
    'proyectos',
    'qa',
    'root',
    'vins',
]
