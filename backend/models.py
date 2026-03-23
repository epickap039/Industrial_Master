"""Modelos Pydantic compartidos (extraídos de server.py)."""
from typing import List, Optional

from pydantic import BaseModel, ConfigDict


class MirrorConfig(BaseModel):
    activa: bool


class MaterialPayload(BaseModel):
    material: str


class LoginRequest(BaseModel):
    username: str
    password: str


class MaterialOficial(BaseModel):
    descripcion: str


class TractoPayload(BaseModel):
    nombre: str


class TipoProyectoPayload(BaseModel):
    id_tracto: int
    nombre: str


class VersionPayload(BaseModel):
    id_tipo: int
    nombre: str


class ClientePayload(BaseModel):
    id_version: int
    nombre: str


class RevisionPayload(BaseModel):
    nombre_revision: Optional[str] = None  # Ignorado: nombre se auto-genera
    notas: Optional[str] = None


class VINPayload(BaseModel):
    vin: str
    notas: Optional[str] = None
    observaciones: Optional[str] = None


class NotasReplacePayload(BaseModel):
    observaciones: Optional[str] = None
    notas: Optional[str] = None


class DeleteVinPayload(BaseModel):
    password: str
    motivo: Optional[str] = None


class BranchingPayload(BaseModel):
    id_revision_origen: int
    tipo_cambio: str  # 'GLOBAL' | 'ESPECIFICO'
    lista_clientes: Optional[List[int]] = None  # IDs para ESPECIFICO


class BugReportPayload(BaseModel):
    usuario: str
    modulo: str
    gravedad: str
    descripcion: str
    captura: Optional[str] = None


class ClonarPayload(BaseModel):
    id_revision_origen: int
    id_revision_destino: int
    rama_cliente: bool = False
    id_cliente_destino: Optional[int] = None


class PropagarPayload(BaseModel):
    codigo_pieza: str
    nueva_cantidad: float
    id_revisiones: list[int]


class EstacionPayload(BaseModel):
    id_revision: int
    nombre: str


class EnsamblePayload(BaseModel):
    id_estacion: int
    nombre: str


class BOMPayload(BaseModel):
    id_ensamble: int
    codigo_pieza: str
    cantidad: float


class AsignarRevisionPayload(BaseModel):
    id_revision_asignada: Optional[int] = None


class LogAuditoriaPayload(BaseModel):
    motivo: str = ""
    observaciones: str = ""


class EliminarRevisionPayload(BaseModel):
    password: str = ""
    motivo: str = ""


class BuscarPlanosPayload(BaseModel):
    codigos: List[str]
    ruta_base: str = ""  # Si se envía, tiene prioridad sobre RUTA_PLANOS


class BOMPiezaUpdate(BaseModel):
    cantidad: float


class PiezaArbolItem(BaseModel):
    """Pieza dentro del árbol BOM (estación → ensamble → pieza)."""

    model_config = ConfigDict(extra="allow")  # Permite campos extra sin fallar
    id: int
    id_estructura: Optional[int] = None  # Alias explícito del PK de Tbl_BOM_Estructura
    codigo: str
    descripcion: Optional[str] = ""
    cantidad: float
    observaciones: Optional[str] = ""
    simetria: Optional[str] = ""
    material: Optional[str] = ""
    medida: Optional[str] = ""
    proceso_primario: Optional[str] = ""
    proceso_1: Optional[str] = ""
    proceso_2: Optional[str] = ""
    proceso_3: Optional[str] = ""
    link_drive: Optional[str] = ""
    largo_cad: Optional[str] = ""
    ancho_cad: Optional[str] = ""
    espesor_cad: Optional[str] = ""
    tiene_dxf: Optional[str] = "No"


class PiezaPlanaItem(BaseModel):
    """Fila de la vista plana BOM (explosión jerárquica)."""

    model_config = ConfigDict(extra="allow")
    nivel: int
    codigo_padre: Optional[str] = ""
    codigo_pieza: Optional[str] = ""
    descripcion: Optional[str] = ""
    cantidad: Optional[float] = None
    material: Optional[str] = ""
    medida: Optional[str] = ""
    proceso_primario: Optional[str] = ""
    proceso_1: Optional[str] = ""
    proceso_2: Optional[str] = ""
    proceso_3: Optional[str] = ""
    largo_cad: Optional[str] = ""
    ancho_cad: Optional[str] = ""
    espesor_cad: Optional[str] = ""
    tiene_dxf: Optional[str] = "No"
    nombre_estacion: Optional[str] = ""
    nombre_ensamble: Optional[str] = ""
    id_bom: Optional[int] = None
    id_estructura: Optional[int] = None  # Alias explícito del PK de Tbl_BOM_Estructura


class SincronizacionItem(BaseModel):
    Codigo_Pieza: str
    Descripcion: Optional[str] = None
    Medida: Optional[str] = None
    Material: Optional[str] = None
    Link_Drive: Optional[str] = None
    Simetria: Optional[str] = None
    Proceso_Primario: Optional[str] = None
    Proceso_1: Optional[str] = None
    Proceso_2: Optional[str] = None
    Proceso_3: Optional[str] = None
    Modificado_Por: Optional[str] = None
    Estado: str

    model_config = ConfigDict(extra="ignore")


class MasivoUpdate(BaseModel):
    old_desc: str
    new_desc: str
    usuario: str


class ScanCADPayload(BaseModel):
    root_path: str


class CollectRequest(BaseModel):
    source_folder: str
