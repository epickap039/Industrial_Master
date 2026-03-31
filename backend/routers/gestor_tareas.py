"""Gestor de tareas de ingeniería (Radar / Manual)."""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from audit_service import registrar_log_global
from database import get_db_connection
from user_context import resolve_actor_user

router = APIRouter()


class ChecklistItemPayload(BaseModel):
    nombre: str = Field(..., min_length=1)
    minutos: int = 0


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


class UpdateCheckPayload(BaseModel):
    completado: bool = True


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
            "tipo": _pick(t_cols, "Tipo_Tarea", "Tipo"),
            "titulo": _pick(t_cols, "Titulo", "Nombre_Tarea"),
            "descripcion": _pick(t_cols, "Descripcion", "Detalle"),
            "codigo": _pick(t_cols, "Codigo_Pieza", "Codigo"),
            "estado": _pick(t_cols, "Estado", "Status"),
            "progreso": _pick(t_cols, "Porcentaje_Progreso", "Progreso"),
            "usuario": _pick(t_cols, "Usuario_Creador", "Usuario"),
            "minutos": _pick(t_cols, "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "meta": _pick(t_cols, "Meta_JSON", "Datos_JSON", "Contexto_JSON"),
            "titulo_cambio": _pick(t_cols, "Titulo_Cambio"),
        }
        map_check = {
            "nombre": _pick(c_cols, "Nombre_Item", "Item", "Descripcion"),
            "minutos": _pick(c_cols, "Minutos_Estimados", "Tiempo_Estimado_Min"),
            "completado": _pick(c_cols, "Completado", "Hecho", "Status"),
            "orden": _pick(c_cols, "Orden", "Sort"),
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
            insert_cols.append(map_task["meta"])
            insert_vals.append(json.dumps(payload.meta, ensure_ascii=False))
        tc = (payload.titulo_cambio or "").strip()
        col_tc = map_task.get("titulo_cambio")
        if tc and col_tc:
            insert_cols.append(col_tc)
            insert_vals.append(tc)

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
            if map_check["nombre"]:
                c_ins_cols.append(map_check["nombre"])
                c_ins_vals.append(item.nombre.strip())
            if map_check["minutos"]:
                c_ins_cols.append(map_check["minutos"])
                c_ins_vals.append(int(item.minutos or 0))
            if map_check["completado"]:
                c_ins_cols.append(map_check["completado"])
                c_ins_vals.append(0)
            if map_check["orden"]:
                c_ins_cols.append(map_check["orden"])
                c_ins_vals.append(idx)

            c_cols_sql = ", ".join(c_ins_cols)
            c_vals_sql = ", ".join(["?"] * len(c_ins_vals))
            cur.execute(
                f"INSERT INTO Tbl_Gestor_Checklist ({c_cols_sql}) VALUES ({c_vals_sql})",
                tuple(c_ins_vals),
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
        t_titulo = _pick(t_cols, "Titulo", "Nombre_Tarea") or t_pk
        t_estado = _pick(t_cols, "Estado", "Status")
        t_progreso = _pick(t_cols, "Porcentaje_Progreso", "Progreso")
        t_tipo = _pick(t_cols, "Tipo_Tarea", "Tipo")
        c_nombre = _pick(c_cols, "Nombre_Item", "Item", "Descripcion") or c_pk
        c_done = _pick(c_cols, "Completado", "Hecho", "Status")
        c_orden = _pick(c_cols, "Orden", "Sort")

        cur.execute(f"SELECT * FROM Tbl_Gestor_Tareas ORDER BY {t_pk} DESC")
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

            tasks.append(
                {
                    "id_tarea": task_id,
                    "tipo": m.get(t_tipo),
                    "titulo": m.get(t_titulo),
                    "estado": m.get(t_estado),
                    "porcentaje_progreso": m.get(t_progreso) if t_progreso else calc_progress,
                    "checklist": [
                        {
                            "id_check": ch.get(c_pk),
                            "nombre": ch.get(c_nombre),
                            "completado": ch.get(c_done),
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

        cur.execute(
            f"UPDATE Tbl_Gestor_Checklist SET {c_done} = ? WHERE {c_pk} = ?",
            (1 if payload.completado else 0, id_check),
        )
        if (cur.rowcount or 0) == 0:
            raise HTTPException(status_code=404, detail="Check no encontrado")

        cur.execute(f"SELECT {c_fk_tarea} FROM Tbl_Gestor_Checklist WHERE {c_pk} = ?", (id_check,))
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Check sin tarea padre")
        id_tarea = int(row[0])

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
            vals.append("Terminado" if progress >= 100 else "En proceso")
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
