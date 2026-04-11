"""Modelos Pydantic compartidos (extraídos de server.py)."""
from typing import Dict, List, Literal, Optional

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
    contexto_pantalla: Optional[str] = None
    crear_tarea_correccion: bool = False
    hashtags: List[str] = []


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


class CodigoGeneradorPayload(BaseModel):
    codigo: str = Field(..., min_length=1, max_length=120)
    procesos: List[str] = Field(..., min_length=1)
    descripcion: Optional[str] = ""
    material: Optional[str] = ""
    largo: Optional[float] = None
    ancho: Optional[float] = None
    espesor: Optional[float] = None
    simetria: bool = False
    detalle_simetria: Optional[str] = ""
    referencia_plano: Optional[str] = ""
    usuario: Optional[str] = "GeneradorCodigo"


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


# ============================================================================
# USUARIO - COLOR ASSIGNMENT
# ============================================================================

class UsuarioColorUpdate(BaseModel):
    """Payload para actualizar el color de un usuario."""

    model_config = ConfigDict(populate_by_name=True)

    color_hex: str = Field(
        ...,
        pattern=r'^#[0-9A-Fa-f]{6}$',
        description="Color hexadecimal (ej: #FF8C00)",
        examples=["#FF8C00", "#4ECDC4", "#FF6B6B"]
    )


class UsuarioColorResponse(BaseModel):
    """Respuesta con información de color del usuario."""

    model_config = ConfigDict(populate_by_name=True, from_attributes=True)

    usuario_login: str = Field(..., alias="usuarioLogin")
    color_hex: str = Field(..., alias="colorHex")


# ============================================================================
# GESTOR DE TAREAS - VOZ A JSON (v15.5)
# ============================================================================

class TranscripcionVozPayload(BaseModel):
    """Payload para procesar transcripción de voz (Whisper) a JSON de tarea."""

    model_config = ConfigDict(populate_by_name=True)

    transcripcion: str = Field(
        ...,
        min_length=10,
        max_length=5000,
        description="Texto de la transcripción (ej: salida de Whisper)"
    )

    minutos_base: int = Field(
        default=30,
        ge=5,
        le=480,
        description="Minutos base para cálculo de complejidad (5-480, default 30)"
    )

    incluir_metadata: bool = Field(
        default=True,
        description="Si True, agrega timestamps y versión en meta_json"
    )


class ArchivoAudioPayload(BaseModel):
    """Payload para transcribir archivo de audio completo (Whisper)."""

    model_config = ConfigDict(populate_by_name=True)

    ruta_archivo: str = Field(
        ...,
        description="Ruta local o URL del archivo de audio (.mp3, .wav, .m4a, etc.)"
    )

    idioma: str = Field(
        default="es",
        description="Código ISO del idioma (ej: 'es', 'en', 'pt')"
    )

    minutos_base: int = Field(
        default=30,
        ge=5,
        le=480,
        description="Minutos base para cálculo de complejidad"
    )


class TareaDesdeVozResponse(BaseModel):
    """Respuesta con JSON de tarea generado desde voz."""

    model_config = ConfigDict(populate_by_name=True)

    titulo: str = Field(..., max_length=50)
    descripcion: str = Field(..., max_length=4000)
    usuario_asignado: str = Field(..., max_length=200)
    minutos_estimados: int = Field(..., ge=0)
    priority_rank: int = Field(..., ge=0, le=2)
    tipo_tarea: str = Field(default="MANUAL")
    source_type: str = Field(default="VOZ_LOCAL")
    meta_json: str = Field(..., description="JSON serializado con metadata")

    # Metadata adicional para confirmación
    transcripcion_procesada: str = Field(..., description="Transcripción original")
    entidades_detectadas: Dict[str, Optional[str]] = Field(
        default_factory=dict,
        description="Area, Pieza y otra info detectada por NER"
    )


