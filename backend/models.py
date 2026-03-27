"""Modelos Pydantic compartidos (extraídos de server.py)."""
from typing import List, Literal, Optional

from pydantic import AliasChoices, BaseModel, ConfigDict, Field, field_validator


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


class MaestroPiezaBomPayload(BaseModel):
    """Datos mínimos para alta en Tbl_Maestro_Piezas cuando el código no existe aún."""

    descripcion: str
    material: str
    proceso_primario: str
    proceso_1: str = ""
    proceso_2: str = ""
    proceso_3: str = ""


class BOMPayload(BaseModel):
    id_ensamble: int
    codigo_pieza: str
    cantidad: float
    observaciones: str = ""
    maestro: Optional[MaestroPiezaBomPayload] = None


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


def _coerce_dim_cad(v):
    """Acepta str/float/int desde BD o JSON; devuelve float o None (sin truncar decimales)."""
    if v is None or v == "":
        return None
    if isinstance(v, bool):
        return None
    try:
        import numpy as np
        if isinstance(v, (np.floating, np.integer)):
            x = float(v.item()) if hasattr(v, "item") else float(v)
            return float(x)
    except Exception:
        pass
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        s = v.strip().replace(",", ".")
        if s.lower() in ("", "nan", "none", "-", "n/a"):
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


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
    largo_cad: Optional[float] = None
    ancho_cad: Optional[float] = None
    espesor_cad: Optional[float] = None
    tiene_dxf: Optional[str] = "No"

    @field_validator("largo_cad", "ancho_cad", "espesor_cad", mode="before")
    @classmethod
    def _v_dim_cad_arbol(cls, v):
        return _coerce_dim_cad(v)


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
    largo_cad: Optional[float] = None
    ancho_cad: Optional[float] = None
    espesor_cad: Optional[float] = None
    tiene_dxf: Optional[str] = "No"

    @field_validator("largo_cad", "ancho_cad", "espesor_cad", mode="before")
    @classmethod
    def _v_dim_cad_plana(cls, v):
        return _coerce_dim_cad(v)
    nombre_estacion: Optional[str] = ""
    nombre_ensamble: Optional[str] = ""
    id_bom: Optional[int] = None
    id_estructura: Optional[int] = None  # Alias explícito del PK de Tbl_BOM_Estructura


class SincronizacionItem(BaseModel):
    """Payload de fila Excel → maestro. descripcion/material son independientes (JSON camel/pascal/minúsculas)."""

    Codigo_Pieza: str
    Descripcion: str = Field(
        default="",
        validation_alias=AliasChoices("Descripcion", "descripcion"),
    )
    Medida: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("Medida", "medida"),
    )
    Material: str = Field(
        default="",
        validation_alias=AliasChoices("Material", "material"),
    )
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
    """Estandarización masiva: `old_desc`/`new_desc` son el valor viejo y nuevo del campo indicado en `campo`."""

    old_desc: str
    new_desc: str
    usuario: str = ""
    campo: Literal["material", "descripcion"] = "material"


class ScanCADPayload(BaseModel):
    root_path: str
    solo_faltantes: bool = False


class CollectRequest(BaseModel):
    source_folder: str
    solo_faltantes: bool = False
