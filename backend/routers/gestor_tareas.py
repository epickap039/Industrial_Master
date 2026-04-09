"""Gestor de tareas de ingeniería (Radar / Manual)."""
from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import pyodbc
from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from pydantic import AliasChoices, BaseModel, ConfigDict, Field

from admin_master_password import assert_admin_master_password_matches
from audit_service import registrar_log_global
from database import get_db_connection
from user_context import resolve_actor_user
from voice_to_json_converter import (
    convertir_transcripcion_a_json,
    extraer_usuario,
    extraer_area,
    extraer_pieza,
    inicializar_whisper_gpu,
    transcribir_audio,
    validar_json_tarea,
)
from models import TranscripcionVozPayload, ArchivoAudioPayload, TareaDesdeVozResponse

router = APIRouter()

# Misma cadena que engineering._GRUPO_INDEFINIDO_SW (sin usar "Global" en checklist nuevo).
_GRUPO_CHECKLIST_SIN_JERARQUIA = "[Indefinido] > [Indefinido] > [Indefinido]"


class ChecklistItemPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    nombre: str = Field(..., min_length=1)
    minutos: int = 0
    grupo: str = Field(
        default=_GRUPO_CHECKLIST_SIN_JERARQUIA,
        validation_alias=AliasChoices("grupo", "categoria"),
    )
    texto_secundario: str = Field(
        default="",
        validation_alias=AliasChoices("texto_secundario", "Texto_Secundario"),
    )


class CrearTareaPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    tipo: str = Field(..., min_length=1)  # RADAR | MANUAL
    titulo: str = Field(..., min_length=1)
    descripcion: str = ""
    codigo_pieza: str = ""
    minutos_estimados: int = 0
    checklist: List[ChecklistItemPayload] = Field(default_factory=list)
    meta: Dict[str, Any] = Field(default_factory=dict)
    titulo_cambio: str = Field(default="", alias="Titulo_Cambio")
    usuario_asignado: str = ""


class UpdateCheckPayload(BaseModel):
    completado: bool = True


class CancelarTareaPayload(BaseModel):
    motivo_cancelacion: str = Field(..., min_length=3, max_length=4000)


class CrearManualPayload(BaseModel):
    """Alta manual desde Centro de Comando (sin checklist obligatorio)."""

    titulo: str = Field(..., min_length=1, max_length=500)
    descripcion: str = Field(default="", max_length=4000)
    responsable: str = Field(..., min_length=1, max_length=200)
    categoria: str = Field(..., min_length=1, max_length=200)
    checklist: List[ChecklistItemPayload] = Field(default_factory=list)
    minutos_estimados: int = 0
    sin_tiempo_estimado: bool = False
    imagen_base64: Optional[str] = Field(
        default=None,
        description="Imagen en Base64 (sin prefijo data:); se guarda en Meta_JSON.",
    )


class ReordenarItemPayload(BaseModel):
    id_tarea: int = Field(..., ge=1)
    priority_rank: int = Field(..., ge=0)


class ReordenarPayload(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    items: List[ReordenarItemPayload] = Field(..., min_length=1)
    suspender_otras_mismo_responsable: bool = False
    id_tarea_prioridad_urgente: Optional[int] = Field(
        default=None,
        ge=1,
        description="Tarea en prioridad crítica; requerida si suspender_otras_mismo_responsable.",
    )


class ActualizarEstadoPayload(BaseModel):
    estado: str = Field(..., min_length=1, max_length=100)
    motivo_pausa: Optional[str] = Field(
        default=None,
        description="Obligatorio si el estado es pausa (Falta material | Avería | Aprobación).",
    )


_REASON_ID_TEXTO: Dict[int, str] = {
    1: "Falta material",
    2: "Avería",
    3: "Aprobación",
    4: "Prioridad Urgente asignada",
}


_MOTIVOS_PAUSA_VALIDOS = (
    "Falta material",
    "Avería",
    "Aprobación",
    "Prioridad Urgente asignada",
)


def _motivo_pausa_a_reason_id(motivo: str) -> int:
    m = motivo.strip()
    mapping = {
        "Falta material": 1,
        "Avería": 2,
        "Aprobación": 3,
        "Prioridad Urgente asignada": 4,
    }
    return mapping.get(m, 0)


def _source_type_from_tipo_api(tipo: str) -> str:
    u = tipo.strip().upper()
    if u == "RADAR":
        return "Radar"
    if u == "MANUAL":
        return "Manual"
    return tipo.strip()


def _ensure_cycle_and_priority(
    cur: Any,
    t_cols: List[str],
    t_pk: str,
    id_tarea: int,
) -> None:
    col_fc = _pick(t_cols, "Fecha_Inicio_Ciclo", "Fecha_Inicio")
    col_pr = _pick(t_cols, "PriorityRank", "Prioridad_Orden", "Sort_Order")
    sets: List[str] = []
    vals: List[Any] = []
    if col_fc:
        sets.append(f"{col_fc} = ?")
        vals.append(datetime.now(timezone.utc))
    if col_pr:
        sets.append(f"{col_pr} = ?")
        vals.append(id_tarea)
    if not sets:
        return
    vals.append(id_tarea)
    cur.execute(
        f"UPDATE Tbl_Gestor_Tareas SET {', '.join(sets)} WHERE {t_pk} = ?",
        tuple(vals),
    )


def _apply_source_and_assignee_post_insert(
    cur: Any,
    t_cols: List[str],
    t_pk: str,
    id_tarea: int,
    tipo: str,
    usuario_asignado: str,
) -> None:
    col_st = _pick(t_cols, "SourceType", "Source_Type")
    col_ca = _pick_assignee_col(t_cols)
    sets: List[str] = []
    vals: List[Any] = []
    if col_st:
        sets.append(f"{col_st} = ?")
        vals.append(_source_type_from_tipo_api(tipo))
    ua = (usuario_asignado or "").strip()
    if ua and col_ca:
        sets.append(f"{col_ca} = ?")
        vals.append(ua)
    if not sets:
        return
    vals.append(id_tarea)
    cur.execute(
        f"UPDATE Tbl_Gestor_Tareas SET {', '.join(sets)} WHERE {t_pk} = ?",
        tuple(vals),
    )


def _audit_estado_tabla_existe(cur: Any) -> bool:
    cur.execute(
        """
        SELECT 1 FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_NAME = 'Tbl_Gestor_Tarea_Estado_Auditoria'
        """
    )
    return cur.fetchone() is not None


def _audit_id_tarea_col(cur: Any) -> Optional[str]:
    """FK hacia tarea en auditoría (variantes Id_Tarea / ID_Tarea)."""
    if not _audit_estado_tabla_existe(cur):
        return None
    cols = _get_cols(cur, "Tbl_Gestor_Tarea_Estado_Auditoria")
    return _pick(cols, "ID_Tarea", "Id_Tarea", "Tarea_ID", "id_tarea")


def _insertar_fila_auditoria_estado(
    cur: Any,
    id_tarea: int,
    estado_ant: Optional[str],
    estado_nuevo: str,
    motivo_pausa: Optional[str],
    reason_id: Optional[int],
    pause_time: Optional[datetime],
) -> None:
    if not _audit_estado_tabla_existe(cur):
        return
    cur.execute(
        """
        INSERT INTO Tbl_Gestor_Tarea_Estado_Auditoria
            (ID_Tarea, Estado_Anterior, Estado_Nuevo, Motivo_Pausa, ReasonID, PauseTime)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (id_tarea, estado_ant, estado_nuevo, motivo_pausa, reason_id, pause_time),
    )


def _aplicar_pausa_por_motivo(
    cur: Any,
    t_cols: List[str],
    t_pk: str,
    id_tarea: int,
    motivo: str,
) -> None:
    """Pausa una fila de tarea; ignora canceladas o ya terminadas al 100 %."""
    if motivo not in _MOTIVOS_PAUSA_VALIDOS:
        return
    t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")
    t_pause = _pick(t_cols, "PauseTime", "Pause_Time")
    t_reason = _pick(t_cols, "PauseReasonID", "Pause_Reason_ID")
    t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
    if not t_estado:
        return
    cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?", (id_tarea,))
    row = cur.fetchone()
    if not row:
        return
    colnames = [d[0] for d in cur.description]
    m = {k: v for k, v in zip(colnames, row)}
    estado_ant = str(m.get(t_estado) or "")
    if "cancel" in estado_ant.lower():
        return
    if t_progreso:
        try:
            if int(m.get(t_progreso) or 0) >= 100:
                return
        except (TypeError, ValueError):
            pass
    nuevo = "Pausado"
    pause_dt = datetime.now(timezone.utc)
    reason_id = _motivo_pausa_a_reason_id(motivo)
    set_parts: List[str] = [f"{t_estado} = ?"]
    set_vals: List[Any] = [nuevo]
    if t_pause:
        set_parts.append(f"{t_pause} = ?")
        set_vals.append(pause_dt)
    if t_reason:
        set_parts.append(f"{t_reason} = ?")
        set_vals.append(reason_id)
    set_vals.append(id_tarea)
    cur.execute(
        f"UPDATE Tbl_Gestor_Tareas SET {', '.join(set_parts)} WHERE {t_pk} = ?",
        tuple(set_vals),
    )
    _insertar_fila_auditoria_estado(
        cur, id_tarea, estado_ant, nuevo, motivo, reason_id, pause_dt
    )


def _estado_desde_progreso(progress: int) -> str:
    """Regla estricta Andon para checklist (no aplica a tareas canceladas)."""
    if progress <= 0:
        return "Pendiente"
    if progress >= 100:
        return "Terminado"
    return "En Proceso"


def _motivo_cancel_desde_fila(
    m: Dict[str, Any],
    col_motivo: Optional[str],
    col_meta: Optional[str],
) -> Optional[str]:
    if col_motivo:
        v = m.get(col_motivo)
        if v is not None and str(v).strip():
            return str(v).strip()
    if not col_meta:
        return None
    raw = m.get(col_meta)
    if raw is None:
        return None
    try:
        jd = json.loads(raw) if isinstance(raw, str) else raw
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(jd, dict):
        return None
    for k in ("motivo_cancelacion", "Motivo_Cancelacion", "motivo"):
        x = jd.get(k)
        if x is not None and str(x).strip():
            return str(x).strip()
    return None


def _get_cols(cur, table: str) -> List[str]:
    cur.execute(
        """
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = ?
        """,
        (table,),
    )
    return [str(r[0]) for r in cur.fetchall()]


def _pick(cols: List[str], *candidates: str) -> Optional[str]:
    lower = {c.lower(): c for c in cols}
    for cand in candidates:
        if cand.lower() in lower:
            return lower[cand.lower()]
    return None


def _pk_like(cols: List[str], keyword: str) -> Optional[str]:
    for c in cols:
        lc = c.lower()
        if lc.startswith("id_") and keyword in lc:
            return c
    for c in cols:
        if c.lower().startswith("id_"):
            return c
    return None


def _pick_tipo_tarea_col(cols: List[str]) -> Optional[str]:
    """Nombres habituales y variantes en distintas versiones del esquema."""
    return _pick(
        cols,
        "Tipo_Tarea",
        "Tipo",
        "TipoTarea",
        "Tipo_Tarea_Origen",
        "Clase_Tarea",
        "Categoria_Tarea",
        "Tipo_Origen",
    )


def _pick_assignee_col(cols: List[str]) -> Optional[str]:
    """Columna del responsable en Tbl_Gestor_Tareas (mismo criterio que alta de tarea)."""
    return _pick(
        cols,
        "CurrentAssignee",
        "Current_Assignee",
        "Usuario_Asignado",
        "UsuarioAsignado",
        "Asignado_A",
        "Responsable",
    )


def _grupo_desde_fila_check(
    ch: Dict[str, Any],
    grupo_col: Optional[str],
    meta_col: Optional[str],
) -> str:
    if grupo_col:
        v = ch.get(grupo_col)
        if v is not None and str(v).strip():
            return str(v).strip()
    if meta_col:
        raw = ch.get(meta_col)
        if raw is None:
            return _GRUPO_CHECKLIST_SIN_JERARQUIA
        try:
            parsed = json.loads(raw) if isinstance(raw, str) else raw
        except (json.JSONDecodeError, TypeError):
            return _GRUPO_CHECKLIST_SIN_JERARQUIA
        if isinstance(parsed, dict):
            for k in ("grupo", "categoria", "_grupo"):
                x = parsed.get(k)
                if x is not None and str(x).strip():
                    return str(x).strip()
    return _GRUPO_CHECKLIST_SIN_JERARQUIA


def _texto_secundario_desde_fila_check(
    ch: Dict[str, Any],
    meta_col: Optional[str],
) -> Optional[str]:
    if not meta_col:
        return None
    raw = ch.get(meta_col)
    if raw is None:
        return None
    try:
        parsed = json.loads(raw) if isinstance(raw, str) else raw
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(parsed, dict):
        return None
    for k in ("texto_secundario", "Texto_Secundario"):
        x = parsed.get(k)
        if x is not None and str(x).strip():
            return str(x).strip()
    return None


def _checklist_meta_json(grupo: str, texto_secundario: str) -> str:
    g = (grupo or "").strip() or _GRUPO_CHECKLIST_SIN_JERARQUIA
    obj: Dict[str, Any] = {"grupo": g}
    ts = (texto_secundario or "").strip()
    if ts:
        obj["texto_secundario"] = ts
    return json.dumps(obj, ensure_ascii=False)


def _dt_iso(v: Any) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, datetime):
        if v.tzinfo is None:
            return v.replace(tzinfo=timezone.utc).isoformat()
        return v.astimezone(timezone.utc).isoformat()
    return str(v)


def _coalesce_fecha_cierre_desde_fila(m: Dict[str, Any]) -> Any:
    """
    Primera fecha no nula entre columnas de cierre o ultima modificacion.
    Evita que si Fecha_Cierre existe en la tabla pero esta NULL, el API
    devuelva fecha_cierre vacio aunque Ultima_Modificacion u otra columna si tenga valor.
    """
    priority = [
        "Fecha_Cierre",
        "Fecha_Completado",
        "Fecha_Finalizacion",
        "Fecha_Fin",
        "Fecha_Terminado",
        "Ultima_Modificacion",
        "Fecha_Modificacion",
        "Fecha_Actualizacion",
        "UpdatedAt",
    ]
    by_lower = {str(k).lower(): k for k in m.keys()}
    for name in priority:
        k = by_lower.get(name.lower())
        if not k:
            continue
        v = m.get(k)
        if v is None:
            continue
        s = str(v).strip()
        if not s or s.lower() == "none":
            continue
        return v
    return None


def _fecha_cierre_desde_meta(raw_meta: Any) -> Any:
    """fecha_cierre / fecha_fin guardadas en Meta_JSON (cancelacion, etc.)."""
    if raw_meta is None:
        return None
    try:
        parsed = json.loads(raw_meta) if isinstance(raw_meta, str) else raw_meta
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(parsed, dict):
        return None
    for k in ("fecha_cierre", "fecha_fin", "Fecha_Cierre", "fecha_completado"):
        x = parsed.get(k)
        if x is not None and str(x).strip() and str(x).lower() != "none":
            return x
    return None


def _as_bool_cell(v: Any) -> bool:
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    s = str(v).lower()
    return s in ("1", "true", "yes", "si", "sí")


def _int_or_none(v: Any) -> Optional[int]:
    if v is None:
        return None
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _tipo_desde_meta_fila(raw_meta: Any) -> Optional[str]:
    if raw_meta is None:
        return None
    try:
        jd = json.loads(raw_meta) if isinstance(raw_meta, str) else raw_meta
        if not isinstance(jd, dict):
            return None
        v = jd.get("_origen_crear_api") or jd.get("_origen_crear") or jd.get("tipo_flujo")
        if v is None:
            return None
        s = str(v).strip()
        return s if s else None
    except (json.JSONDecodeError, TypeError, ValueError):
        return None


@router.post("/api/tareas/crear")
def crear_tarea(
    payload: CrearTareaPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        if not t_cols or not c_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")

        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        c_pk = _pk_like(c_cols, "check") or "ID_Check"
        c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")

        if not c_fk_tarea:
            raise HTTPException(status_code=500, detail="No se encontró FK de checklist a tarea")

        map_task = {
            "tipo": _pick_tipo_tarea_col(t_cols),
            "titulo": _pick(t_cols, "Titulo", "Nombre_Tarea"),
            "descripcion": _pick(t_cols, "Descripcion", "Detalle"),
            "codigo": _pick(t_cols, "Codigo_Pieza", "Codigo"),
            "estado": _pick(t_cols, "Estado", "Status"),
            "progreso": _pick(t_cols, "Porcentaje_Progreso", "Progreso"),
            "usuario": _pick(t_cols, "Usuario_Creador", "Usuario"),
            "minutos": _pick(t_cols, "Duracion_Minutos", "Tiempo_Total_Estimado", "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "meta": _pick(t_cols, "Meta_JSON", "Datos_JSON", "Contexto_JSON"),
            "titulo_cambio": _pick(t_cols, "Titulo_Cambio"),
            "usuario_asignado": _pick(
                t_cols,
                "Usuario_Asignado",
                "UsuarioAsignado",
                "Asignado_A",
                "Responsable",
            ),
        }
        map_check = {
            "nombre": _pick(c_cols, "Nombre_Item", "Item", "Descripcion"),
            "minutos": _pick(c_cols, "Tiempo_Estimado", "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "completado": _pick(c_cols, "Completado", "Hecho", "Status"),
            "orden": _pick(c_cols, "Orden", "Sort"),
            "grupo_col": _pick(
                c_cols,
                "Grupo",
                "Grupo_Item",
                "Categoria",
                "Categoria_Item",
            ),
            "meta_check": _pick(
                c_cols,
                "Meta_JSON",
                "Meta_Item",
                "Datos_JSON",
                "Contexto_JSON",
                "Observaciones_JSON",
            ),
        }

        insert_cols: List[str] = []
        insert_vals: List[Any] = []
        if map_task["tipo"]:
            insert_cols.append(map_task["tipo"])
            insert_vals.append(payload.tipo.strip().upper())
        if map_task["titulo"]:
            insert_cols.append(map_task["titulo"])
            insert_vals.append(payload.titulo.strip())
        if map_task["descripcion"]:
            insert_cols.append(map_task["descripcion"])
            insert_vals.append(payload.descripcion.strip())
        if map_task["codigo"]:
            insert_cols.append(map_task["codigo"])
            insert_vals.append(payload.codigo_pieza.strip().upper() or None)
        if map_task["estado"]:
            insert_cols.append(map_task["estado"])
            insert_vals.append("Pendiente")
        if map_task["progreso"]:
            insert_cols.append(map_task["progreso"])
            insert_vals.append(0)
        if map_task["usuario"]:
            insert_cols.append(map_task["usuario"])
            insert_vals.append(usr)
        if map_task["minutos"]:
            insert_cols.append(map_task["minutos"])
            insert_vals.append(int(payload.minutos_estimados or 0))
        if map_task["meta"]:
            meta_dict: Dict[str, Any] = dict(payload.meta) if payload.meta else {}
            meta_dict["_origen_crear_api"] = payload.tipo.strip().upper()
            insert_cols.append(map_task["meta"])
            insert_vals.append(json.dumps(meta_dict, ensure_ascii=False))
        tc = (payload.titulo_cambio or "").strip()
        col_tc = map_task.get("titulo_cambio")
        if tc and col_tc:
            insert_cols.append(col_tc)
            insert_vals.append(tc)

        ua = (payload.usuario_asignado or "").strip()
        col_ua = map_task.get("usuario_asignado")
        if ua and col_ua:
            insert_cols.append(col_ua)
            insert_vals.append(ua)

        if not insert_cols:
            raise HTTPException(status_code=500, detail="No se pudo mapear columnas para insertar tarea")

        cols_sql = ", ".join(insert_cols)
        params_sql = ", ".join(["?"] * len(insert_vals))
        cur.execute(
            f"""
            INSERT INTO Tbl_Gestor_Tareas ({cols_sql})
            OUTPUT INSERTED.{t_pk}
            VALUES ({params_sql})
            """,
            tuple(insert_vals),
        )
        id_tarea = int(cur.fetchone()[0])

        for idx, item in enumerate(payload.checklist, start=1):
            c_ins_cols = [c_fk_tarea]
            c_ins_vals: List[Any] = [id_tarea]
            g_val = (item.grupo or "").strip() or _GRUPO_CHECKLIST_SIN_JERARQUIA
            ts_sec = (item.texto_secundario or "").strip()
            nombre_ins = item.nombre.strip()
            if ts_sec and not map_check.get("meta_check"):
                nombre_ins = f"{nombre_ins}\n{ts_sec}"
            if map_check["nombre"]:
                c_ins_cols.append(map_check["nombre"])
                c_ins_vals.append(nombre_ins)
            if map_check["minutos"]:
                c_ins_cols.append(map_check["minutos"])
                c_ins_vals.append(int(item.minutos or 0))
            if map_check["completado"]:
                c_ins_cols.append(map_check["completado"])
                c_ins_vals.append(0)
            if map_check["orden"]:
                c_ins_cols.append(map_check["orden"])
                c_ins_vals.append(idx)

            meta_json = _checklist_meta_json(g_val, item.texto_secundario or "")
            if map_check.get("grupo_col"):
                c_ins_cols.append(map_check["grupo_col"])
                c_ins_vals.append(g_val)
            if map_check.get("meta_check"):
                c_ins_cols.append(map_check["meta_check"])
                c_ins_vals.append(meta_json)

            c_cols_sql = ", ".join(c_ins_cols)
            c_vals_sql = ", ".join(["?"] * len(c_ins_vals))
            cur.execute(
                f"INSERT INTO Tbl_Gestor_Checklist ({c_cols_sql}) VALUES ({c_vals_sql})",
                tuple(c_ins_vals),
            )

        _ensure_cycle_and_priority(cur, t_cols, t_pk, id_tarea)
        _apply_source_and_assignee_post_insert(
            cur, t_cols, t_pk, id_tarea, payload.tipo, payload.usuario_asignado
        )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "CREAR_TAREA",
            "",
            f"id_tarea={id_tarea};tipo={payload.tipo};titulo={payload.titulo[:80]}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id_tarea": id_tarea, "id_check_pk": c_pk}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/tareas/crear_manual")
def crear_tarea_manual(
    payload: CrearManualPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        if not t_cols or not c_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")

        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        c_pk = _pk_like(c_cols, "check") or "ID_Check"
        c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")

        if not c_fk_tarea:
            raise HTTPException(status_code=500, detail="No se encontró FK de checklist a tarea")

        map_task = {
            "tipo": _pick_tipo_tarea_col(t_cols),
            "titulo": _pick(t_cols, "Titulo", "Nombre_Tarea"),
            "descripcion": _pick(t_cols, "Descripcion", "Detalle"),
            "codigo": _pick(t_cols, "Codigo_Pieza", "Codigo"),
            "estado": _pick(t_cols, "Estado", "Status"),
            "progreso": _pick(t_cols, "Porcentaje_Progreso", "Progreso"),
            "usuario": _pick(t_cols, "Usuario_Creador", "Usuario"),
            "minutos": _pick(t_cols, "Duracion_Minutos", "Tiempo_Total_Estimado", "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "meta": _pick(t_cols, "Meta_JSON", "Datos_JSON", "Contexto_JSON"),
            "titulo_cambio": _pick(t_cols, "Titulo_Cambio"),
            "usuario_asignado": _pick(
                t_cols,
                "Usuario_Asignado",
                "UsuarioAsignado",
                "Asignado_A",
                "Responsable",
            ),
        }
        map_check = {
            "nombre": _pick(c_cols, "Nombre_Item", "Item", "Descripcion"),
            "minutos": _pick(c_cols, "Tiempo_Estimado", "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "completado": _pick(c_cols, "Completado", "Hecho", "Status"),
            "orden": _pick(c_cols, "Orden", "Sort"),
            "grupo_col": _pick(
                c_cols,
                "Grupo",
                "Grupo_Item",
                "Categoria",
                "Categoria_Item",
            ),
            "meta_check": _pick(
                c_cols,
                "Meta_JSON",
                "Meta_Item",
                "Datos_JSON",
                "Contexto_JSON",
                "Observaciones_JSON",
            ),
        }

        insert_cols: List[str] = []
        insert_vals: List[Any] = []
        if map_task["tipo"]:
            insert_cols.append(map_task["tipo"])
            insert_vals.append("MANUAL")
        if map_task["titulo"]:
            insert_cols.append(map_task["titulo"])
            insert_vals.append(payload.titulo.strip())
        if map_task["descripcion"]:
            insert_cols.append(map_task["descripcion"])
            insert_vals.append(payload.descripcion.strip())
        if map_task["codigo"]:
            insert_cols.append(map_task["codigo"])
            insert_vals.append(None)
        if map_task["estado"]:
            insert_cols.append(map_task["estado"])
            insert_vals.append("Pendiente")
        if map_task["progreso"]:
            insert_cols.append(map_task["progreso"])
            insert_vals.append(0)
        if map_task["usuario"]:
            insert_cols.append(map_task["usuario"])
            insert_vals.append(usr)
        if map_task["minutos"]:
            insert_cols.append(map_task["minutos"])
            minutos_val = 0 if payload.sin_tiempo_estimado else int(payload.minutos_estimados or 0)
            insert_vals.append(minutos_val)
        if map_task["meta"]:
            meta_dict: Dict[str, Any] = {
                "categoria": payload.categoria.strip(),
                "_origen_crear_api": "MANUAL",
                "source_type": "Manual",
            }
            desc_m = (payload.descripcion or "").strip()
            if desc_m:
                meta_dict["descripcion"] = desc_m
            if payload.sin_tiempo_estimado:
                meta_dict["sin_tiempo_estimado"] = True
            img = (payload.imagen_base64 or "").strip()
            if img:
                meta_dict["imagen_adjunta_base64"] = img
            insert_cols.append(map_task["meta"])
            insert_vals.append(json.dumps(meta_dict, ensure_ascii=False))

        col_tc = map_task.get("titulo_cambio")
        if col_tc:
            insert_cols.append(col_tc)
            insert_vals.append(payload.titulo.strip())

        ua = payload.responsable.strip()
        col_ua = map_task.get("usuario_asignado")
        if ua and col_ua:
            insert_cols.append(col_ua)
            insert_vals.append(ua)

        col_st = _pick(t_cols, "SourceType", "Source_Type")
        if col_st:
            insert_cols.append(col_st)
            insert_vals.append("Manual")
        col_ca = _pick_assignee_col(t_cols)
        if col_ca and ua and col_ca != col_ua:
            insert_cols.append(col_ca)
            insert_vals.append(ua)

        # MEJORA INTEGRAL v15.5: Agregar Hora_Inicio
        col_hora_inicio = _pick(t_cols, "Hora_Inicio", "HoraInicio", "Hora_Creacion")
        if col_hora_inicio:
            # Registrar hora actual en formato TIME (HH:MM:SS)
            hora_actual = datetime.now(timezone.utc).strftime("%H:%M:%S")
            insert_cols.append(col_hora_inicio)
            insert_vals.append(hora_actual)

        if not insert_cols:
            raise HTTPException(status_code=500, detail="No se pudo mapear columnas para insertar tarea")

        cols_sql = ", ".join(insert_cols)
        params_sql = ", ".join(["?"] * len(insert_vals))
        cur.execute(
            f"""
            INSERT INTO Tbl_Gestor_Tareas ({cols_sql})
            OUTPUT INSERTED.{t_pk}
            VALUES ({params_sql})
            """,
            tuple(insert_vals),
        )
        id_tarea = int(cur.fetchone()[0])

        for idx, item in enumerate(payload.checklist, start=1):
            c_ins_cols = [c_fk_tarea]
            c_ins_vals: List[Any] = [id_tarea]
            g_val = (item.grupo or "").strip() or _GRUPO_CHECKLIST_SIN_JERARQUIA
            ts_sec = (item.texto_secundario or "").strip()
            nombre_ins = item.nombre.strip()
            if ts_sec and not map_check.get("meta_check"):
                nombre_ins = f"{nombre_ins}\n{ts_sec}"
            if map_check["nombre"]:
                c_ins_cols.append(map_check["nombre"])
                c_ins_vals.append(nombre_ins)
            if map_check["minutos"]:
                c_ins_cols.append(map_check["minutos"])
                c_ins_vals.append(int(item.minutos or 0))
            if map_check["completado"]:
                c_ins_cols.append(map_check["completado"])
                c_ins_vals.append(0)
            if map_check["orden"]:
                c_ins_cols.append(map_check["orden"])
                c_ins_vals.append(idx)

            meta_json = _checklist_meta_json(g_val, item.texto_secundario or "")
            if map_check.get("grupo_col"):
                c_ins_cols.append(map_check["grupo_col"])
                c_ins_vals.append(g_val)
            if map_check.get("meta_check"):
                c_ins_cols.append(map_check["meta_check"])
                c_ins_vals.append(meta_json)

            c_cols_sql = ", ".join(c_ins_cols)
            c_vals_sql = ", ".join(["?"] * len(c_ins_vals))
            cur.execute(
                f"INSERT INTO Tbl_Gestor_Checklist ({c_cols_sql}) VALUES ({c_vals_sql})",
                tuple(c_ins_vals),
            )

        _ensure_cycle_and_priority(cur, t_cols, t_pk, id_tarea)

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "CREAR_TAREA_MANUAL",
            "",
            f"id_tarea={id_tarea};categoria={payload.categoria[:80]}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id_tarea": id_tarea, "id_check_pk": c_pk}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.put("/api/tareas/reordenar")
def reordenar_tareas(
    payload: ReordenarPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        if not t_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")
        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        col_pr = _pick(t_cols, "PriorityRank", "Prioridad_Orden", "Sort_Order")
        if not col_pr:
            raise HTTPException(
                status_code=500,
                detail="No existe columna PriorityRank (ejecute add_gestor_comando_directivo.sql)",
            )
        for it in payload.items:
            cur.execute(
                f"UPDATE Tbl_Gestor_Tareas SET {col_pr} = ? WHERE {t_pk} = ?",
                (it.priority_rank, it.id_tarea),
            )
            if (cur.rowcount or 0) == 0:
                raise HTTPException(status_code=404, detail=f"Tarea {it.id_tarea} no encontrada")

        if payload.suspender_otras_mismo_responsable:
            uid = payload.id_tarea_prioridad_urgente
            if not uid:
                raise HTTPException(
                    status_code=400,
                    detail="id_tarea_prioridad_urgente es obligatorio cuando suspender_otras_mismo_responsable es true",
                )
            ranks = {it.id_tarea: it.priority_rank for it in payload.items}
            if ranks.get(uid) != 0:
                raise HTTPException(
                    status_code=400,
                    detail="La tarea urgente debe enviarse con priority_rank 0",
                )
            t_ca = _pick_assignee_col(t_cols)
            if not t_ca:
                raise HTTPException(
                    status_code=500,
                    detail=(
                        "No hay columna de responsable en Tbl_Gestor_Tareas para suspender "
                        "otras tareas (se espera una de: CurrentAssignee, Usuario_Asignado, "
                        "UsuarioAsignado, Asignado_A, Responsable)"
                    ),
                )
            cur.execute(
                f"SELECT [{t_ca}] FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?",
                (uid,),
            )
            r0 = cur.fetchone()
            assignee_raw = r0[0] if r0 else None
            assignee_s = str(assignee_raw).strip() if assignee_raw is not None else ""
            if assignee_s:
                cur.execute(
                    f"SELECT [{t_pk}] FROM Tbl_Gestor_Tareas WHERE [{t_ca}] = ? AND [{t_pk}] <> ?",
                    (assignee_s, uid),
                )
                for (oid,) in cur.fetchall():
                    try:
                        oid_i = int(oid)
                    except (TypeError, ValueError):
                        continue
                    _aplicar_pausa_por_motivo(
                        cur, t_cols, t_pk, oid_i, "Prioridad Urgente asignada"
                    )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "REORDENAR_TAREAS",
            "",
            f"n={len(payload.items)};suspend={payload.suspender_otras_mismo_responsable}",
            usr,
        )
        conn.commit()
        return {"ok": True, "actualizadas": len(payload.items)}
    except HTTPException:
        conn.rollback()
        raise
    except pyodbc.Error as e:
        conn.rollback()
        parts = [str(x).strip() for x in e.args if x is not None and str(x).strip()]
        sql_hint = " | ".join(parts) if parts else repr(e)
        raise HTTPException(
            status_code=400,
            detail=(
                "Error de base de datos al reordenar o suspender tareas. "
                f"Revise columnas y datos enviados. Detalle: {sql_hint}"
            ),
        )
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.put("/api/tareas/estado/{id_tarea}")
def actualizar_estado_tarea(
    id_tarea: int,
    payload: ActualizarEstadoPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    nuevo = payload.estado.strip()
    nuevo_lower = nuevo.lower()
    es_pausa = "paus" in nuevo_lower

    if es_pausa:
        if not payload.motivo_pausa or not payload.motivo_pausa.strip():
            raise HTTPException(
                status_code=400,
                detail="motivo_pausa es obligatorio al pausar (Falta material | Avería | Aprobación).",
            )
        mp = payload.motivo_pausa.strip()
        if mp not in _MOTIVOS_PAUSA_VALIDOS:
            raise HTTPException(
                status_code=400,
                detail=f"motivo_pausa debe ser uno de: {', '.join(_MOTIVOS_PAUSA_VALIDOS)}",
            )

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        if not t_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")
        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")
        t_pause = _pick(t_cols, "PauseTime", "Pause_Time")
        t_reason = _pick(t_cols, "PauseReasonID", "Pause_Reason_ID")

        if not t_estado:
            raise HTTPException(status_code=500, detail="No se encontró columna Estado en la tarea")

        cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?", (id_tarea,))
        colnames = [d[0] for d in cur.description]
        trow = cur.fetchone()
        if not trow:
            raise HTTPException(status_code=404, detail="Tarea no encontrada")
        m = {k: v for k, v in zip(colnames, trow)}
        estado_ant = str(m.get(t_estado) or "") if t_estado else None

        pause_dt: Optional[datetime] = None
        reason_id: Optional[int] = None
        motivo_txt: Optional[str] = None

        set_parts: List[str] = [f"{t_estado} = ?"]
        set_vals: List[Any] = [nuevo]

        if es_pausa:
            pause_dt = datetime.now(timezone.utc)
            motivo_txt = payload.motivo_pausa.strip() if payload.motivo_pausa else None
            reason_id = _motivo_pausa_a_reason_id(motivo_txt or "")
            if t_pause:
                set_parts.append(f"{t_pause} = ?")
                set_vals.append(pause_dt)
            if t_reason:
                set_parts.append(f"{t_reason} = ?")
                set_vals.append(reason_id)
        else:
            if t_pause:
                set_parts.append(f"{t_pause} = ?")
                set_vals.append(None)
            if t_reason:
                set_parts.append(f"{t_reason} = ?")
                set_vals.append(None)
            if "terminad" in nuevo_lower and "terminad" not in str(estado_ant or "").lower():
                _append_fecha_cierre_update(t_cols, set_parts, set_vals)

                # MEJORA INTEGRAL v15.5: Agregar Hora_Fin cuando se completa
                col_hora_fin = _pick(t_cols, "Hora_Fin", "HoraFin", "Hora_Cierre")
                if col_hora_fin:
                    hora_actual = datetime.now(timezone.utc).strftime("%H:%M:%S")
                    set_parts.append(f"{col_hora_fin} = ?")
                    set_vals.append(hora_actual)

                # Calcular duración en minutos
                col_duracion = _pick(t_cols, "Duracion_Minutos", "DuracionMinutos", "Minutos_Duracion")
                if col_duracion:
                    # Obtener Hora_Inicio
                    col_hora_inicio = _pick(t_cols, "Hora_Inicio", "HoraInicio", "Hora_Creacion")
                    if col_hora_inicio and col_hora_inicio in m:
                        hora_inicio_str = str(m.get(col_hora_inicio) or "")
                        if hora_inicio_str:
                            try:
                                # Parsear horas HH:MM:SS
                                h_inicio = datetime.strptime(hora_inicio_str.split('.')[0], "%H:%M:%S")
                                h_fin = datetime.now(timezone.utc)
                                duracion_minutos = int((h_fin - h_inicio.replace(hour=h_fin.hour, minute=h_fin.minute, second=h_fin.second)).total_seconds() / 60)
                                set_parts.append(f"{col_duracion} = ?")
                                set_vals.append(max(0, duracion_minutos))
                            except Exception:
                                pass  # Si no se puede calcular, no agregar

        set_vals.append(id_tarea)
        cur.execute(
            f"UPDATE Tbl_Gestor_Tareas SET {', '.join(set_parts)} WHERE {t_pk} = ?",
            tuple(set_vals),
        )

        _insertar_fila_auditoria_estado(
            cur,
            id_tarea,
            estado_ant,
            nuevo,
            motivo_txt if es_pausa else None,
            reason_id if es_pausa else None,
            pause_dt if es_pausa else None,
        )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "UPDATE_ESTADO_TAREA",
            "",
            f"id_tarea={id_tarea};estado={nuevo[:40]}",
            usr,
        )
        conn.commit()
        return {
            "ok": True,
            "id_tarea": id_tarea,
            "estado": nuevo,
            "pause_time": pause_dt.isoformat() if pause_dt else None,
            "reason_id": reason_id,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


def _fila_es_tarea_manual(m: Dict[str, Any], t_source_type: Optional[str], t_tipo: Optional[str]) -> bool:
    if t_source_type:
        v = str(m.get(t_source_type) or "").strip().lower()
        if v == "manual":
            return True
    if t_tipo:
        v = str(m.get(t_tipo) or "").strip().upper()
        if v == "MANUAL":
            return True
    return False


def _append_fecha_cierre_update(
    t_cols: List[str],
    set_parts: List[str],
    set_vals: List[Any],
) -> None:
    """Escribe fecha de cierre (o columna equivalente) para bitácora / GET lista."""
    t_fc = _pick(
        t_cols,
        "Fecha_Cierre",
        "Fecha_Completado",
        "Fecha_Finalizacion",
        "Fecha_Fin",
        "Fecha_Terminado",
    )
    if not t_fc:
        t_fc = _pick(
            t_cols,
            "Ultima_Modificacion",
            "Fecha_Modificacion",
            "Fecha_Actualizacion",
            "UpdatedAt",
        )
    if t_fc:
        set_parts.append(f"{t_fc} = ?")
        set_vals.append(datetime.now(timezone.utc))


@router.put("/api/tareas/finalizar_manual/{id_tarea}")
def finalizar_manual(
    id_tarea: int,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """Cierra una tarea manual: checklist al 100 %, progreso 100, estado Terminado."""
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        if not t_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")

        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")
        t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
        t_source_type = _pick(t_cols, "SourceType", "Source_Type")
        t_tipo = _pick_tipo_tarea_col(t_cols)

        if not t_estado:
            raise HTTPException(status_code=500, detail="No se encontró columna Estado en la tarea")

        cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?", (id_tarea,))
        colnames = [d[0] for d in cur.description]
        trow = cur.fetchone()
        if not trow:
            raise HTTPException(status_code=404, detail="Tarea no encontrada")
        m = {k: v for k, v in zip(colnames, trow)}

        if not _fila_es_tarea_manual(m, t_source_type, t_tipo):
            raise HTTPException(
                status_code=400,
                detail="Solo tareas manuales pueden finalizarse con este endpoint",
            )

        est_actual = str(m.get(t_estado) or "").lower()
        if "cancel" in est_actual:
            raise HTTPException(status_code=400, detail="La tarea está cancelada")
        if "paus" in est_actual:
            raise HTTPException(status_code=400, detail="La tarea está pausada; reanúdela primero")

        if c_cols:
            c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")
            c_done = _pick(c_cols, "Completado", "Hecho", "Status")
            if c_fk_tarea and c_done:
                cur.execute(
                    f"UPDATE Tbl_Gestor_Checklist SET {c_done} = ? WHERE {c_fk_tarea} = ?",
                    (1, id_tarea),
                )

        set_parts: List[str] = []
        set_vals: List[Any] = []
        if t_progreso:
            set_parts.append(f"{t_progreso} = ?")
            set_vals.append(100)
        set_parts.append(f"{t_estado} = ?")
        set_vals.append("Terminado")
        _append_fecha_cierre_update(t_cols, set_parts, set_vals)
        set_vals.append(id_tarea)
        cur.execute(
            f"UPDATE Tbl_Gestor_Tareas SET {', '.join(set_parts)} WHERE {t_pk} = ?",
            tuple(set_vals),
        )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "FINALIZAR_MANUAL",
            "",
            f"id_tarea={id_tarea}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id_tarea": id_tarea, "porcentaje_progreso": 100, "estado": "Terminado"}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/tareas/lista")
def listar_tareas():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        if not t_cols or not c_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")

        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        c_pk = _pk_like(c_cols, "check") or "ID_Check"
        c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")
        t_titulo = _pick(t_cols, "Titulo", "Nombre_Tarea")
        t_titulo_cambio = _pick(t_cols, "Titulo_Cambio")
        t_usuario_asignado = _pick(
            t_cols,
            "Usuario_Asignado",
            "UsuarioAsignado",
            "Asignado_A",
            "Responsable",
        )
        t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")
        t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
        t_tipo = _pick_tipo_tarea_col(t_cols)
        t_meta = _pick(t_cols, "Meta_JSON", "Datos_JSON", "Contexto_JSON")
        t_motivo_cancel = _pick(
            t_cols,
            "Motivo_Cancelacion",
            "Motivo_Cancelado",
            "Razon_Cancelacion",
            "Motivo_Cancelación",
        )
        c_nombre = _pick(c_cols, "Nombre_Item", "Item", "Descripcion") or c_pk
        c_done = _pick(c_cols, "Completado", "Hecho", "Status")
        c_orden = _pick(c_cols, "Orden", "Sort")
        c_grupo = _pick(
            c_cols,
            "Grupo",
            "Grupo_Item",
            "Categoria",
            "Categoria_Item",
        )
        c_check_meta = _pick(
            c_cols,
            "Meta_JSON",
            "Meta_Item",
            "Datos_JSON",
            "Contexto_JSON",
            "Observaciones_JSON",
        )
        t_source_type = _pick(t_cols, "SourceType", "Source_Type")
        t_current_assignee = _pick_assignee_col(t_cols)
        t_priority = _pick(t_cols, "PriorityRank", "Prioridad_Orden", "Sort_Order")
        t_pause_time = _pick(t_cols, "PauseTime", "Pause_Time")
        t_pause_reason = _pick(t_cols, "PauseReasonID", "Pause_Reason_ID")
        t_critico = _pick(t_cols, "Critico", "Es_Critico", "Critica")
        t_fecha_ciclo = _pick(
            t_cols,
            "Fecha_Inicio_Ciclo",
            "Fecha_Inicio",
        )
        t_fecha_creacion = _pick(
            t_cols,
            "Fecha_Creacion",
            "FechaCreacion",
            "CreatedAt",
            "Fecha_Creado",
            "Fecha_Alta",
        )
        t_fecha_cierre = _pick(
            t_cols,
            "Fecha_Cierre",
            "Fecha_Completado",
            "Fecha_Finalizacion",
            "Fecha_Fin",
            "Fecha_Terminado",
            "Ultima_Modificacion",
            "Fecha_Modificacion",
            "Fecha_Actualizacion",
            "UpdatedAt",
        )
        t_usuario_completado = _pick(
            t_cols,
            "Usuario_Completador",
            "Completado_Por",
            "Usuario_Cierre",
            "Modificado_Por",
            "Usuario_Modifico",
            "Usuario_Ultima_Modificacion",
        )
        t_descripcion = _pick(t_cols, "Descripcion", "Detalle", "Descripcion_Tarea")
        t_minutos_est = _pick(t_cols, "Duracion_Minutos", "Tiempo_Total_Estimado", "Minutos_Estimados", "Tiempo_Estimado_Min")

        order_sql = f"ORDER BY {t_pk} DESC"
        if t_priority:
            order_sql = (
                f"ORDER BY CASE WHEN [{t_priority}] IS NULL THEN 1 ELSE 0 END, "
                f"[{t_priority}] ASC, [{t_pk}] DESC"
            )

        cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas {order_sql}")
        t_rows = cur.fetchall()
        t_colnames = [d[0] for d in cur.description]
        tasks: List[Dict[str, Any]] = []

        for row in t_rows:
            m = {k: v for k, v in zip(t_colnames, row)}
            task_id = int(m[t_pk])
            cur.execute(
                f"SELECT * FROM Tbl_Gestor_Checklist WHERE {c_fk_tarea} = ?"
                + (f" ORDER BY {c_orden}" if c_orden else ""),
                (task_id,),
            )
            c_rows = cur.fetchall()
            c_colnames = [d[0] for d in cur.description]
            checks = [{k: v for k, v in zip(c_colnames, cr)} for cr in c_rows]

            total = len(checks)
            done = 0
            for ch in checks:
                dv = ch.get(c_done) if c_done else 0
                done += 1 if str(dv).lower() in ("1", "true", "si", "sí") else 0
            calc_progress = int((done / total) * 100) if total else int(m.get(t_progreso) or 0)

            tipo_val = m.get(t_tipo) if t_tipo else None
            if tipo_val is not None and str(tipo_val).strip() == "":
                tipo_val = None
            if tipo_val is None and t_meta:
                tipo_val = _tipo_desde_meta_fila(m.get(t_meta))

            def _norm_cell(v: Any) -> Optional[str]:
                if v is None:
                    return None
                s = str(v).strip()
                if not s or s.lower() == "none":
                    return None
                return s

            titulo_cambio_s = _norm_cell(m.get(t_titulo_cambio) if t_titulo_cambio else None)
            titulo_s = _norm_cell(m.get(t_titulo) if t_titulo else None)
            titulo_para_api = titulo_cambio_s or titulo_s
            if titulo_para_api and titulo_para_api.isdigit() and int(titulo_para_api) == task_id:
                titulo_para_api = None

            ua_raw = m.get(t_usuario_asignado) if t_usuario_asignado else None
            usuario_asignado_val = _norm_cell(ua_raw)
            ca_cell = _norm_cell(m.get(t_current_assignee)) if t_current_assignee else None
            asignado_display = ca_cell or usuario_asignado_val

            motivo_canc = _motivo_cancel_desde_fila(m, t_motivo_cancel, t_meta)

            src_val = _norm_cell(m.get(t_source_type)) if t_source_type else None
            critico_val = _as_bool_cell(m.get(t_critico)) if t_critico else False

            fc_raw = _coalesce_fecha_cierre_desde_fila(m)
            if fc_raw is None and t_meta:
                fc_raw = _fecha_cierre_desde_meta(m.get(t_meta))

            tasks.append(
                {
                    "id_tarea": task_id,
                    "tipo": tipo_val,
                    "titulo": titulo_para_api,
                    "titulo_cambio": titulo_cambio_s,
                    "descripcion": _norm_cell(m.get(t_descripcion)) if t_descripcion else None,
                    "minutos_estimados": _int_or_none(m.get(t_minutos_est))
                    if t_minutos_est
                    else None,
                    "Usuario_Asignado": usuario_asignado_val,
                    "usuario_asignado": usuario_asignado_val,
                    "CurrentAssignee": ca_cell,
                    "current_assignee": ca_cell,
                    "asignado_display": asignado_display,
                    "source_type": src_val,
                    "SourceType": src_val,
                    "priority_rank": _int_or_none(m.get(t_priority)) if t_priority else None,
                    "pause_time": _dt_iso(m.get(t_pause_time)) if t_pause_time else None,
                    "pause_reason_id": _int_or_none(m.get(t_pause_reason)) if t_pause_reason else None,
                    "critico": critico_val,
                    "fecha_inicio_ciclo": _dt_iso(m.get(t_fecha_ciclo)) if t_fecha_ciclo else None,
                    "fecha_creacion": _dt_iso(m.get(t_fecha_creacion)) if t_fecha_creacion else None,
                    "fecha_cierre": _dt_iso(fc_raw),
                    "usuario_completado": _norm_cell(m.get(t_usuario_completado))
                    if t_usuario_completado
                    else None,
                    "meta": m.get(t_meta) if t_meta else None,
                    "estado": m.get(t_estado),
                    "Estado": m.get(t_estado),
                    "porcentaje_progreso": m.get(t_progreso) if t_progreso else calc_progress,
                    "motivo_cancelacion": motivo_canc,
                    "checklist": [
                        {
                            "id_check": ch.get(c_pk),
                            "nombre": ch.get(c_nombre),
                            "completado": ch.get(c_done),
                            "grupo": _grupo_desde_fila_check(ch, c_grupo, c_check_meta),
                            "texto_secundario": _texto_secundario_desde_fila_check(
                                ch, c_check_meta
                            ),
                            "raw": ch,
                        }
                        for ch in checks
                    ],
                }
            )
        return tasks
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.put("/api/tareas/check/{id_check}")
def marcar_check(
    id_check: int,
    payload: UpdateCheckPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        c_pk = _pk_like(c_cols, "check") or "ID_Check"
        c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")
        c_done = _pick(c_cols, "Completado", "Hecho", "Status")
        t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
        t_estado = _pick(t_cols, "Estado", "Status")

        if not c_fk_tarea or not c_done:
            raise HTTPException(status_code=500, detail="No se pudo mapear columnas checklist")

        cur.execute(f"SELECT {c_fk_tarea} FROM Tbl_Gestor_Checklist WHERE {c_pk} = ?", (id_check,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Check sin tarea padre")
        id_tarea = int(row[0])

        prev_prog = 0
        if t_progreso:
            cur.execute(
                f"SELECT {t_progreso} FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?",
                (id_tarea,),
            )
            pr = cur.fetchone()
            if pr and pr[0] is not None:
                try:
                    prev_prog = int(pr[0])
                except (TypeError, ValueError):
                    prev_prog = 0

        if t_estado:
            cur.execute(
                f"SELECT {t_estado} FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?",
                (id_tarea,),
            )
            st_row = cur.fetchone()
            if st_row and "cancel" in str(st_row[0] or "").lower():
                raise HTTPException(
                    status_code=400,
                    detail="La tarea está cancelada; no se puede modificar el checklist.",
                )
            if st_row and "paus" in str(st_row[0] or "").lower():
                raise HTTPException(
                    status_code=400,
                    detail="La tarea está pausada; reanude antes de modificar el checklist.",
                )

        cur.execute(
            f"UPDATE Tbl_Gestor_Checklist SET {c_done} = ? WHERE {c_pk} = ?",
            (1 if payload.completado else 0, id_check),
        )
        if (cur.rowcount or 0) == 0:
            raise HTTPException(status_code=404, detail="Check no encontrado")

        cur.execute(f"SELECT COUNT(*) FROM Tbl_Gestor_Checklist WHERE {c_fk_tarea} = ?", (id_tarea,))
        total = int(cur.fetchone()[0] or 0)
        cur.execute(
            f"SELECT COUNT(*) FROM Tbl_Gestor_Checklist WHERE {c_fk_tarea} = ? AND {c_done} IN (1, '1', 'true', 'TRUE')",
            (id_tarea,),
        )
        done = int(cur.fetchone()[0] or 0)
        progress = int((done / total) * 100) if total else 0

        set_parts = []
        vals: List[Any] = []
        if t_progreso:
            set_parts.append(f"{t_progreso} = ?")
            vals.append(progress)
        if t_estado:
            set_parts.append(f"{t_estado} = ?")
            vals.append(_estado_desde_progreso(progress))
        if progress >= 100 and prev_prog < 100:
            _append_fecha_cierre_update(t_cols, set_parts, vals)
        if set_parts:
            vals.append(id_tarea)
            cur.execute(
                f"UPDATE Tbl_Gestor_Tareas SET {', '.join(set_parts)} WHERE {t_pk} = ?",
                tuple(vals),
            )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "UPDATE_CHECK",
            "",
            f"id_check={id_check};id_tarea={id_tarea};progress={progress}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id_tarea": id_tarea, "porcentaje_progreso": progress}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.put("/api/tareas/cancelar/{id_tarea}")
def cancelar_tarea(
    id_tarea: int,
    payload: CancelarTareaPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        if not t_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")
        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")
        t_meta = _pick(t_cols, "Meta_JSON", "Datos_JSON", "Contexto_JSON")
        t_motivo_cancel = _pick(
            t_cols,
            "Motivo_Cancelacion",
            "Motivo_Cancelado",
            "Razon_Cancelacion",
            "Motivo_Cancelación",
        )

        if not t_estado:
            raise HTTPException(
                status_code=500,
                detail="No se encontró columna de estado (Estado / Estado_Tarea) en la tarea",
            )
        if not t_motivo_cancel and not t_meta:
            raise HTTPException(
                status_code=500,
                detail="Falta columna Motivo_Cancelacion o Meta_JSON en Tbl_Gestor_Tareas para guardar el motivo",
            )

        cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas WHERE {t_pk} = ?", (id_tarea,))
        colnames = [d[0] for d in cur.description]
        trow = cur.fetchone()
        if not trow:
            raise HTTPException(status_code=404, detail="Tarea no encontrada")
        m = {k: v for k, v in zip(colnames, trow)}
        est_actual = str(m.get(t_estado) or "").lower()
        if "cancel" in est_actual:
            raise HTTPException(status_code=400, detail="La tarea ya está cancelada")

        motivo_txt = payload.motivo_cancelacion.strip()

        set_parts: List[str] = []
        set_vals: List[Any] = []

        set_parts.append(f"{t_estado} = ?")
        set_vals.append("Cancelado")

        if t_motivo_cancel:
            set_parts.append(f"{t_motivo_cancel} = ?")
            set_vals.append(motivo_txt)
        elif t_meta:
            raw_meta = m.get(t_meta)
            jd: Dict[str, Any] = {}
            if raw_meta:
                try:
                    parsed = json.loads(raw_meta) if isinstance(raw_meta, str) else raw_meta
                    if isinstance(parsed, dict):
                        jd = dict(parsed)
                except (json.JSONDecodeError, TypeError):
                    jd = {}
            jd["motivo_cancelacion"] = motivo_txt
            jd["fecha_cancelacion"] = datetime.now(timezone.utc).isoformat()
            set_parts.append(f"{t_meta} = ?")
            set_vals.append(json.dumps(jd, ensure_ascii=False))

        set_vals.append(id_tarea)
        cur.execute(
            f"UPDATE Tbl_Gestor_Tareas SET {', '.join(set_parts)} WHERE {t_pk} = ?",
            tuple(set_vals),
        )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "CANCELAR_TAREA",
            "",
            f"id_tarea={id_tarea};motivo_len={len(motivo_txt)}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id_tarea": id_tarea, "estado": "Cancelado"}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/tareas/bitacora/{id_tarea}")
def bitacora_tarea(id_tarea: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        if not _audit_estado_tabla_existe(cur):
            return []
        cur.execute(
            """
            SELECT Estado_Anterior, Estado_Nuevo, Motivo_Pausa, ReasonID, PauseTime
            FROM dbo.Tbl_Gestor_Tarea_Estado_Auditoria
            WHERE ID_Tarea = ?
            ORDER BY COALESCE(PauseTime, CAST('1900-01-01' AS DATETIME2)) DESC
            """,
            (id_tarea,),
        )
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        eventos: List[Dict[str, Any]] = []
        for row in rows:
            m = {k: v for k, v in zip(cols, row)}
            ant = str(m.get("Estado_Anterior") or "").strip() or "—"
            nue = str(m.get("Estado_Nuevo") or "").strip() or "—"
            mot_s = str(m.get("Motivo_Pausa") or "").strip()
            rid = m.get("ReasonID")
            try:
                ri = int(rid) if rid is not None else None
            except (TypeError, ValueError):
                ri = None
            if not mot_s and ri is not None and ri in _REASON_ID_TEXTO:
                mot_s = _REASON_ID_TEXTO[ri]
            pt = m.get("PauseTime")
            hora = _dt_iso(pt) if pt is not None else ""
            nue_l = nue.lower()
            if "paus" in nue_l and mot_s:
                texto = f"Tarea pausada: {mot_s}"
            elif "paus" in nue_l:
                texto = f"Tarea pausada ({ant} → {nue})"
            else:
                texto = f"Estado: {ant} → {nue}"
                if mot_s:
                    texto += f" · {mot_s}"
            eventos.append({"hora": hora, "texto": texto})
        return eventos
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.delete("/api/tareas/limpiar_historial")
def limpiar_historial(
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    assert_admin_master_password_matches(x_admin_master_password)
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        c_cols = _get_cols(cur, "Tbl_Gestor_Checklist")
        if not t_cols or not c_cols:
            raise HTTPException(status_code=500, detail="Tablas de gestor no disponibles")

        t_pk = _pk_like(t_cols, "tarea") or "ID_Tarea"
        c_fk_tarea = _pick(c_cols, "ID_Tarea", "Id_Tarea", "Tarea_ID")
        t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
        t_estado = _pick(t_cols, "Estado", "Status", "Estado_Tarea")

        if not t_progreso or not t_estado:
            raise HTTPException(status_code=500, detail="No se pudo mapear progreso/estado para limpiar historial")

        # Seleccionar tareas a borrar (TRY_CAST evita error si la columna no es numérica)
        cur.execute(
            f"""
            SELECT [{t_pk}] FROM dbo.Tbl_Gestor_Tareas
            WHERE COALESCE(TRY_CAST([{t_progreso}] AS INT), 0) >= 100
               OR [{t_estado}] = N'Cancelado'
               OR [{t_estado}] = N'Terminado'
            """
        )
        rows = cur.fetchall()
        if not rows:
            return {"status": "ok", "message": "No hay tareas en historial para limpiar", "borradas": 0}

        ids_a_borrar = [row[0] for row in rows]
        placeholders = ",".join("?" * len(ids_a_borrar))
        params = tuple(ids_a_borrar)

        try:
            conn.autocommit = False
        except Exception:
            pass

        # Transacción única: hijos primero (FK), luego tarea padre.
        # 1) Checklist
        cur.execute(
            f"DELETE FROM dbo.Tbl_Gestor_Checklist WHERE [{c_fk_tarea}] IN ({placeholders})",
            params,
        )
        # 2) Auditoría de estados (columna FK según esquema)
        audit_fk = _audit_id_tarea_col(cur)
        if audit_fk:
            cur.execute(
                f"DELETE FROM dbo.Tbl_Gestor_Tarea_Estado_Auditoria WHERE [{audit_fk}] IN ({placeholders})",
                params,
            )
        # 3) Tareas
        cur.execute(
            f"DELETE FROM dbo.Tbl_Gestor_Tareas WHERE [{t_pk}] IN ({placeholders})",
            params,
        )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "LIMPIAR_HISTORIAL",
            "",
            f"borradas={len(ids_a_borrar)}",
            usr,
        )
        conn.commit()
        return {"status": "ok", "borradas": len(ids_a_borrar)}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


# ============================================================================
# NUEVOS ENDPOINTS - TRANSCRIPCIÓN DE VOZ A TAREA (v15.5)
# ============================================================================

@router.post("/api/tareas/voz/procesar")
def procesar_transcripcion_voz(
    payload: TranscripcionVozPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Procesa transcripción de voz (texto) y retorna JSON listo para insertar.

    Endpoint: POST /api/tareas/voz/procesar

    Entrada:
        - transcripcion: Texto de la transcripción
        - minutos_base: Minutos base para cálculos (default 30)
        - incluir_metadata: Si agregar timestamps (default True)

    Retorna:
        - JSON con campos de tarea
        - Entidades detectadas (área, pieza)
        - Transcripción original
    """
    usr = resolve_actor_user(authorization, x_usuario)

    try:
        # Convertir transcripción a JSON
        json_tarea = convertir_transcripcion_a_json(
            payload.transcripcion,
            minutos_base=payload.minutos_base,
            incluir_metadata=payload.incluir_metadata,
        )

        # Validar estructura
        valido, error = validar_json_tarea(json_tarea)
        if not valido:
            raise HTTPException(status_code=422, detail=f"JSON inválido: {error}")

        # Construir respuesta con entidades detectadas
        respuesta = TareaDesdeVozResponse(
            titulo=json_tarea["titulo"],
            descripcion=json_tarea["descripcion"],
            usuario_asignado=json_tarea["usuario_asignado"],
            minutos_estimados=json_tarea["minutos_estimados"],
            priority_rank=json_tarea["priority_rank"],
            tipo_tarea=json_tarea["tipo_tarea"],
            source_type=json_tarea["source_type"],
            meta_json=json_tarea["meta_json"],
            transcripcion_procesada=payload.transcripcion,
            entidades_detectadas={
                "area": extraer_area(payload.transcripcion),
                "pieza": extraer_pieza(payload.transcripcion),
                "usuario_detectado": extraer_usuario(payload.transcripcion),
            },
        )

        registrar_log_global(
            None,
            "GESTOR_TAREAS",
            "VOZ_PROCESAR",
            f"titulo={json_tarea['titulo']}",
            f"prioridad={json_tarea['priority_rank']}",
            usr,
        )

        return respuesta.model_dump()

    except ValueError as e:
        raise HTTPException(status_code=400, detail=f"Error: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/api/tareas/voz/crear-desde-transcripcion")
def crear_tarea_desde_transcripcion(
    payload: TranscripcionVozPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Transcribe voz → JSON → Crea tarea en Tbl_Gestor_Tareas en un paso.

    Este endpoint combina:
    1. Procesamiento de transcripción → JSON
    2. Inserción en BD (como si fuera CrearManualPayload)

    Retorna: ID de tarea creada
    """
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()

    try:
        # Paso 1: Procesar transcripción
        json_tarea = convertir_transcripcion_a_json(
            payload.transcripcion,
            minutos_base=payload.minutos_base,
            incluir_metadata=payload.incluir_metadata,
        )

        valido, error = validar_json_tarea(json_tarea)
        if not valido:
            raise HTTPException(status_code=422, detail=f"JSON inválido: {error}")

        # Paso 2: Obtener columnas de BD
        t_cols = _get_cols(cur, "Tbl_Gestor_Tareas")
        if not t_cols:
            raise HTTPException(status_code=500, detail="Tabla Tbl_Gestor_Tareas no disponible")

        # Mapear columnas
        map_task = {
            "tipo": _pick_tipo_tarea_col(t_cols),
            "titulo": _pick(t_cols, "Titulo", "Nombre_Tarea"),
            "descripcion": _pick(t_cols, "Descripcion", "Detalle"),
            "estado": _pick(t_cols, "Estado", "Status"),
            "usuario": _pick(t_cols, "Usuario_Creador", "Usuario"),
            "minutos": _pick(t_cols, "Duracion_Minutos", "Tiempo_Estimado_Min", "Minutos_Estimados"),
            "meta": _pick(t_cols, "Meta_JSON", "Datos_JSON"),
            "usuario_asignado": _pick_assignee_col(t_cols),
            "priority_rank": _pick(t_cols, "Priority_Rank", "Prioridad", "PriorityRank"),
            "source_type": _pick(t_cols, "Source_Type", "Tipo_Origen"),
        }

        # Paso 3: Construir INSERT
        insert_cols = []
        insert_vals = []

        if map_task["tipo"]:
            insert_cols.append(map_task["tipo"])
            insert_vals.append("MANUAL")
        if map_task["titulo"]:
            insert_cols.append(map_task["titulo"])
            insert_vals.append(json_tarea["titulo"])
        if map_task["descripcion"]:
            insert_cols.append(map_task["descripcion"])
            insert_vals.append(json_tarea["descripcion"])
        if map_task["estado"]:
            insert_cols.append(map_task["estado"])
            insert_vals.append("Pendiente")
        if map_task["usuario"]:
            insert_cols.append(map_task["usuario"])
            insert_vals.append(usr)
        if map_task["minutos"]:
            insert_cols.append(map_task["minutos"])
            insert_vals.append(json_tarea["minutos_estimados"])
        if map_task["meta"]:
            insert_cols.append(map_task["meta"])
            insert_vals.append(json_tarea["meta_json"])
        if map_task["priority_rank"]:
            insert_cols.append(map_task["priority_rank"])
            insert_vals.append(json_tarea["priority_rank"])
        if map_task["source_type"]:
            insert_cols.append(map_task["source_type"])
            insert_vals.append("VOZ_LOCAL")

        # INSERT
        cols_str = ", ".join([f"[{c}]" for c in insert_cols])
        placeholders = ", ".join(["?" for _ in insert_vals])

        insert_sql = f"INSERT INTO dbo.Tbl_Gestor_Tareas ({cols_str}) OUTPUT INSERTED." + (
            _pk_like(t_cols, "tarea") or "ID_Tarea"
        ) + " VALUES (" + placeholders + ")"

        cur.execute(insert_sql, tuple(insert_vals))
        result = cur.fetchone()
        id_tarea_creada = result[0] if result else None

        # POST-INSERT: Asignar usuario si es diferente a "PENDIENTE"
        if json_tarea["usuario_asignado"] != "PENDIENTE" and map_task["usuario_asignado"]:
            _apply_source_and_assignee_post_insert(
                cur,
                t_cols,
                id_tarea_creada,
                json_tarea["usuario_asignado"],
                "VOZ_LOCAL",
            )

        registrar_log_global(
            cur,
            "GESTOR_TAREAS",
            "VOZ_CREAR",
            f"id={id_tarea_creada}, titulo={json_tarea['titulo']}",
            f"prioridad={json_tarea['priority_rank']}, usuario={json_tarea['usuario_asignado']}",
            usr,
        )

        conn.commit()

        return {
            "status": "ok",
            "id_tarea": id_tarea_creada,
            "titulo": json_tarea["titulo"],
            "usuario_asignado": json_tarea["usuario_asignado"],
            "priority_rank": json_tarea["priority_rank"],
            "message": f"Tarea creada desde transcripción VOZ # {id_tarea_creada}",
        }

    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/tareas/voz/disponible")
def voz_disponible():
    """
    Retorna si el servidor tiene faster-whisper instalado y listo.
    Hace un import dinamico para detectar instalaciones posteriores al arranque.
    """
    disponible = False
    try:
        from faster_whisper import WhisperModel as _  # noqa: F401
        disponible = True
    except ImportError:
        disponible = False
    return {
        "whisper_disponible": disponible,
        "mensaje": (
            "Transcripcion de audio lista."
            if disponible
            else "faster-whisper no instalado. Solo se admite transcripcion de texto."
        ),
    }


@router.post("/api/tareas/voz/transcribir-audio")
def transcribir_archivo_audio(
    payload: ArchivoAudioPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Transcribe archivo de audio (.mp3, .wav, .m4a) usando Whisper en GPU.

    IMPORTANTE: Requiere faster-whisper instalado (pip install faster-whisper).
    Si no está disponible retorna 503 con detalle claro.

    Endpoint: POST /api/tareas/voz/transcribir-audio

    Entrada:
        - ruta_archivo: Ruta local al archivo de audio (accesible desde el servidor)
        - idioma: Código ISO (default "es")
        - minutos_base: Minutos base para estimación (default 30)

    Retorna:
        - transcripcion: texto completo
        - json_tarea: objeto listo para insertar en Tbl_Gestor_Tareas
    """
    usr = resolve_actor_user(authorization, x_usuario)

    try:
        # Verificar disponibilidad antes de intentar cargar el modelo.
        whisper_ok = inicializar_whisper_gpu()
        if not whisper_ok:
            raise HTTPException(
                status_code=503,
                detail=(
                    "faster-whisper no disponible en este servidor. "
                    "Instala: pip install faster-whisper. "
                    "Usa POST /api/tareas/voz/procesar para enviar texto directamente."
                ),
            )

        # Transcribir archivo (debe ser accesible desde el servidor)
        transcripcion = transcribir_audio(payload.ruta_archivo, idioma=payload.idioma)
        if not transcripcion:
            raise HTTPException(
                status_code=400,
                detail="Transcripción vacía o error al leer el archivo de audio.",
            )

        json_tarea = convertir_transcripcion_a_json(
            transcripcion,
            minutos_base=payload.minutos_base,
            incluir_metadata=True,
        )

        registrar_log_global(
            None,
            "GESTOR_TAREAS",
            "VOZ_TRANSCRIBIR",
            f"archivo={payload.ruta_archivo}",
            f"idioma={payload.idioma}, caracteres={len(transcripcion)}",
            usr,
        )

        return {
            "status": "ok",
            "transcripcion": transcripcion,
            "json_tarea": json_tarea,
            "caracteres": len(transcripcion),
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/api/tareas/voz/transcribir-audio-upload")
async def transcribir_audio_upload(
    audio: UploadFile = File(...),
    idioma: str = Form(default="es"),
    minutos_base: int = Form(default=30),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Transcribe un archivo de audio enviado como multipart/form-data.

    Acepta .m4a, .mp3, .wav, .ogg, .webm desde cualquier cliente (Android, iOS, web).
    No requiere que el cliente y el servidor compartan sistema de archivos.

    Campos multipart:
        - audio  (file)     : binario del archivo de audio
        - idioma (string)   : código ISO del idioma, default "es"
        - minutos_base (int): minutos base para estimación, default 30

    Retorna el mismo esquema que /api/tareas/voz/transcribir-audio:
        { status, transcripcion, json_tarea, caracteres }
    """
    usr = resolve_actor_user(authorization, x_usuario)

    whisper_ok = inicializar_whisper_gpu()
    if not whisper_ok:
        raise HTTPException(
            status_code=503,
            detail=(
                "faster-whisper no disponible en este servidor. "
                "Instala: pip install faster-whisper"
            ),
        )

    # Detectar extensión desde el nombre original del archivo subido
    original_name = audio.filename or "audio.m4a"
    ext = os.path.splitext(original_name)[-1].lower() or ".m4a"
    allowed = {".m4a", ".mp3", ".wav", ".ogg", ".webm", ".flac", ".aac"}
    if ext not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Formato de audio no soportado: {ext}. Usa: {', '.join(sorted(allowed))}",
        )

    tmp_path: Optional[str] = None
    try:
        # Guardar bytes en archivo temporal para que Whisper pueda leerlos
        data = await audio.read()
        if not data:
            raise HTTPException(status_code=400, detail="El archivo de audio está vacío.")

        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
            tmp.write(data)
            tmp_path = tmp.name

        transcripcion = transcribir_audio(tmp_path, idioma=idioma)
        if not transcripcion:
            raise HTTPException(
                status_code=400,
                detail="Transcripción vacía. Verifica que el audio tenga habla audible.",
            )

        json_tarea = convertir_transcripcion_a_json(
            transcripcion,
            minutos_base=minutos_base,
            incluir_metadata=True,
        )

        registrar_log_global(
            None,
            "GESTOR_TAREAS",
            "VOZ_UPLOAD_TRANSCRIBIR",
            f"archivo={original_name}",
            f"idioma={idioma}, bytes={len(data)}, caracteres={len(transcripcion)}",
            usr,
        )

        return {
            "status": "ok",
            "transcripcion": transcripcion,
            "json_tarea": json_tarea,
            "caracteres": len(transcripcion),
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        # Limpiar archivo temporal siempre
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
