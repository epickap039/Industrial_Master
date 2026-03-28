"""API router: escÃ¡ner CAD."""
import ast
import io
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import traceback
import unicodedata
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import openpyxl
import pandas as pd
import pyodbc
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from audit_service import registrar_log_global
from database import get_db_connection, _int_from_count_row
from models import *
from user_context import resolve_actor_user

router = APIRouter()


def _cad_path_has_obsoleto(path: str) -> bool:
    """Ignora rutas cuyo nombre de archivo o cualquier carpeta contenga 'OBSOLETO'."""
    return "obsoleto" in path.replace("\\", "/").lower()


def _dedupe_paths_by_basename_newest(paths: List[str]) -> List[str]:
    """Por código (sin prefijo chapa) y extensión, conserva la ruta con mayor getmtime."""
    import re
    best: Dict[str, tuple[float, str]] = {}
    for p in paths:
        try:
            bn = os.path.basename(p)
            stem, ext = os.path.splitext(bn)
            key_stem = re.sub(r"(?i)^chapa desplegada - ", "", stem).strip().lower()
            key = f"{key_stem}_{ext.lower()}"
            mt = os.path.getmtime(p)
        except OSError:
            continue
        prev = best.get(key)
        if prev is None or mt > prev[0]:
            best[key] = (mt, p)
    return [t[1] for t in best.values()]


def _sanitize_excel_si_no(val: Any, default: str = "NO") -> str:
    """ASCII + mayúsculas para columnas VARCHAR cortas (Tiene_DXF, etc.).

    Evita 'String or binary data would be truncated' cuando Excel trae 'SÍ'
    o mojibake ('SÃ…') y la columna SQL es demasiado estrecha para UTF-8 multibyte.
    """
    if val is None:
        return default
    try:
        if pd.isna(val):
            return default
    except Exception:
        pass
    try:
        if isinstance(val, float) and math.isnan(val):
            return default
    except (TypeError, ValueError):
        pass
    raw = str(val).strip()
    if not raw or raw.lower() in ("nan", "none", "-", "n/a"):
        return default
    # Mojibake típico: UTF-8 leído como Latin-1
    if "Ã" in raw or "Â" in raw:
        try:
            raw = raw.encode("latin-1").decode("utf-8")
        except (UnicodeDecodeError, UnicodeEncodeError):
            pass
    nfd = unicodedata.normalize("NFD", raw)
    sin_tildes = "".join(c for c in nfd if unicodedata.category(c) != "Mn")
    ascii_only = "".join(c for c in sin_tildes if ord(c) < 128)
    u = ascii_only.upper().replace(" ", "")
    if not u:
        return default
    if u.startswith("S") or u in ("SI", "YES", "TRUE", "1", "Y"):
        return "SI"
    if u.startswith("N") or u in ("NO", "FALSE", "0"):
        return "NO"
    return default


def _clean_com_text(val: Any) -> str:
    """Texto desde win32com / Windows: strip y corrección común de mojibake (Latin-1 mal leído como UTF-8)."""
    if val is None:
        return ""
    try:
        if pd.isna(val):
            return ""
    except Exception:
        pass
    try:
        s = str(val).strip()
    except Exception:
        return ""
    if not s:
        return ""
    if "Ã" in s or "Â" in s:
        try:
            s = s.encode("latin-1").decode("utf-8").strip()
        except (UnicodeDecodeError, UnicodeEncodeError):
            pass
    return s


def _ascii_report_text(val: Any) -> str:
    """Cadenas del reporte CAD: ASCII sin acentos para Excel/BD (evita Ñ, ó, etc.)."""
    s = _clean_com_text(val)
    if not s:
        return ""
    nfd = unicodedata.normalize("NFD", s)
    out = "".join(
        c for c in nfd if unicodedata.category(c) != "Mn" and ord(c) < 128
    )
    return out if out else s


def _export_reporte_cad(
    df: pd.DataFrame,
    report_path: str,
    telemetry_lines: Optional[List[str]] = None,
) -> None:
    """Exporta xlsx (UTF-16 interno en XML vía openpyxl) y CSV con BOM para Excel en Windows."""
    df.to_excel(report_path, index=False, engine="openpyxl")

    _tel = telemetry_lines if telemetry_lines is not None else _cad_telemetry_snapshot()

    # Semáforo de colores en Excel (tolerancia 0.1 mm; L/A comparados por par)
    try:
        wb = openpyxl.load_workbook(report_path)
        ws = wb.active

        green_fill = PatternFill(start_color="c6efce", end_color="c6efce", fill_type="solid")
        yellow_fill = PatternFill(start_color="ffeb9c", end_color="ffeb9c", fill_type="solid")
        red_fill = PatternFill(start_color="ffc7ce", end_color="ffc7ce", fill_type="solid")

        headers = {cell.value: idx for idx, cell in enumerate(ws[1])}
        col_largo_cad = headers.get("Largo_CAD")
        col_ancho_cad = headers.get("Ancho_CAD")
        col_largo_dxf = headers.get("Largo_DXF")
        col_ancho_dxf = headers.get("Ancho_DXF")
        col_largo_nuevo = headers.get("Largo_DXF_Nuevo")
        col_ancho_nuevo = headers.get("Ancho_DXF_Nuevo")

        _TOL = 0.1

        def _cell_f(row, idx):
            if idx is None:
                return 0.0
            cell = row[idx]
            if cell.value is None or str(cell.value).strip() == "":
                return 0.0
            try:
                return float(cell.value)
            except (ValueError, TypeError):
                return 0.0

        if col_largo_cad is not None and col_ancho_cad is not None:
            for row in ws.iter_rows(min_row=2):
                try:
                    lc = _cell_f(row, col_largo_cad)
                    ac = _cell_f(row, col_ancho_cad)
                    ld = _cell_f(row, col_largo_dxf)
                    ad = _cell_f(row, col_ancho_dxf)
                    ln = _cell_f(row, col_largo_nuevo)
                    an = _cell_f(row, col_ancho_nuevo)

                    if lc == 0.0 or ac == 0.0:
                        fill = red_fill
                    elif (
                        ln > 0.0
                        and an > 0.0
                        and abs(lc - ln) <= _TOL
                        and abs(ac - an) <= _TOL
                    ):
                        fill = yellow_fill
                    elif ld > 0.0 and ad > 0.0 and (
                        abs(lc - ld) > _TOL or abs(ac - ad) > _TOL
                    ):
                        fill = red_fill
                    elif ld > 0.0 and ad > 0.0:
                        fill = green_fill
                    else:
                        fill = green_fill

                    for cell in row:
                        cell.fill = fill
                except (ValueError, TypeError):
                    for cell in row:
                        cell.fill = red_fill

        ws_tel = wb.create_sheet("TELEMETRIA_PROFUNDA", 1)
        ws_tel.cell(row=1, column=1, value="Log_COM_Secuencial")
        for i, line in enumerate(_tel, start=2):
            ws_tel.cell(row=i, column=1, value=line)

        wb.save(report_path)
    except Exception as e:
        print(f"Error aplicando colores al Excel: {e}")

    base, _, ext = report_path.rpartition(".")
    if ext.lower() == "xlsx":
        csv_path = f"{base}.csv"
    else:
        csv_path = f"{report_path}.csv"
    df.to_csv(csv_path, index=False, encoding="utf-8-sig")


# RaÃ­z `backend/` (equivalente a cuando server.py monolÃ­tico vivÃ­a ahÃ­; flags y tools/ siguen igual)
_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# === MÃ“DULO: ESCÃNER CAD (Fase 1) ===

try:
    import ezdxf
    from ezdxf import bbox as ezdxf_bbox
    import win32com.client
    import pythoncom
    print("MÃ³dulos CAD asÃ­ncronos (ezdxf, win32com, pythoncom) importados exitosamente.")
except ImportError as e:
    raise RuntimeError(f"LIBRERÃA FALTANTE: AsegÃºrate de correr 'pip install ezdxf pywin32'. Error: {e}")

scan_status = {
    "progress": 0,
    "total": 0,
    "status": "idle",
    "excel_path": "",
    "error": "",
    "warning_message": "",
    "current_file": "",
    "current_item": 0,
    "total_items": 0
}
abortar_escaneo_cad = False

# Tiempo máximo por pieza SolidWorks (COM bloqueante; no se puede cancelar la llamada en curso).
SW_PIECE_TIMEOUT_SEC = 90

# ── Filtro antichurros: excluye piezas comerciales ──────────────────────────────
# Se aplica en TODAS las consultas SQL que definen el universo de piezas a procesar.
_SQL_EXCLUIR_COMERCIALES = """
    AND (LOWER(CAST(Material AS NVARCHAR(200))) NOT LIKE '%comercial%'
         OR Material IS NULL)
"""

# SolidWorks swCustomInfoText — propiedades personalizadas de tipo texto
_SW_CUSTOM_INFO_TEXT = 30

# Carpeta local del pipeline maestro (escritorio) y subcarpeta DXF (solo local, no red)
def _piezas_a_procesar_desktop_dir() -> str:
    return os.path.join(os.path.expanduser("~"), "Desktop", "Piezas_A_Procesar")


cad_deep_telemetry_lock = threading.Lock()
cad_deep_telemetry_lines: List[str] = []
_cad_debug_log_lock = threading.Lock()


def _escribir_log(mensaje: str) -> None:
    """Consola + DEBUG_LOG.txt con timestamp (append)."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {mensaje}"
    print(line)
    try:
        dbg = os.path.join(_piezas_a_procesar_desktop_dir(), "DEBUG_LOG.txt")
        os.makedirs(os.path.dirname(dbg), exist_ok=True)
        with _cad_debug_log_lock:
            with open(dbg, "a", encoding="utf-8") as tf:
                tf.write(line + "\n")
    except Exception:
        pass


def _cad_telemetry_clear() -> None:
    global cad_deep_telemetry_lines
    with cad_deep_telemetry_lock:
        cad_deep_telemetry_lines = []
    try:
        dbg = os.path.join(_piezas_a_procesar_desktop_dir(), "DEBUG_LOG.txt")
        os.makedirs(os.path.dirname(dbg), exist_ok=True)
        with _cad_debug_log_lock:
            with open(dbg, "w", encoding="utf-8") as tf:
                tf.write("")
    except Exception:
        pass


def _cad_telemetry_append(codigo: str, msg: str) -> None:
    global cad_deep_telemetry_lines
    c = (codigo or "?").strip() or "?"
    line = f"[{c}] {msg}"
    with cad_deep_telemetry_lock:
        cad_deep_telemetry_lines.append(line)
    _escribir_log(line)


def _cad_telemetry_snapshot() -> List[str]:
    with cad_deep_telemetry_lock:
        return list(cad_deep_telemetry_lines)


_CHAPA_DESPLEGADA_PREFIX_RE = re.compile(r"(?i)^chapa desplegada - ")


def _normalize_chapa_stem(stem: str) -> str:
    """Quita prefijo 'Chapa desplegada - ' (cualquier mayúscula) del nombre base."""
    if not stem:
        return ""
    return re.sub(_CHAPA_DESPLEGADA_PREFIX_RE, "", str(stem).strip()).strip().upper()


def _parse_cutlist_length_mm(raw) -> Optional[float]:
    if raw is None:
        return None
    if isinstance(raw, (tuple, list)):
        if len(raw) > 1 and raw[1] is not None:
            raw = raw[1]
        elif len(raw) > 0:
            raw = raw[0]
        else:
            return None
    try:
        s = _clean_com_text(str(raw))
    except Exception:
        s = str(raw) if raw is not None else ""
    if not s:
        return None
    s = re.sub(r"[^\d.,\-]", "", s).replace(",", ".")
    try:
        v = float(s)
        return v if v > 0 else None
    except ValueError:
        return None


def _coalesce_sw_custom_property_get2_return(r) -> Any:
    """Valor útil de la tupla COM (Get2): prioriza el campo numérico / texto de medida."""
    if r is None:
        return None
    if not isinstance(r, (tuple, list)):
        return r
    if len(r) == 0:
        return None
    for i in range(len(r) - 1, -1, -1):
        piece = r[i]
        if piece in (None, "", False):
            continue
        if _parse_cutlist_length_mm(piece) is not None:
            return piece
    for i in range(len(r) - 1, -1, -1):
        piece = r[i]
        if piece not in (None, "", False):
            return piece
    return None


def _icm_get_property_raw(cm, name: str):
    """ICustomPropertyManager: Get2 (ByRef o retorno) → Get3 → Get."""
    if cm is None or not name:
        return None
    try:
        g2 = getattr(cm, "Get2", None)
        if callable(g2):
            import pythoncom
            import win32com.client as _wc
            try:
                v_out = _wc.VARIANT(pythoncom.VT_BSTR | pythoncom.VT_BYREF, "")
                g2(name, v_out)
                if getattr(v_out, "value", None) not in (None, "", False):
                    return v_out.value
            except (TypeError, AttributeError, Exception):
                pass
            try:
                r = g2(name)
                if isinstance(r, (tuple, list)):
                    ex = _coalesce_sw_custom_property_get2_return(r)
                    if ex is not None:
                        return ex
                elif r not in (None, "", False):
                    return r
            except Exception:
                pass
    except Exception:
        pass
    try:
        g3 = getattr(cm, "Get3", None)
        if callable(g3):
            r = g3(name)
            if isinstance(r, (tuple, list)):
                ex = _coalesce_sw_custom_property_get2_return(r)
                if ex is not None:
                    return ex
            elif r not in (None, "", False):
                return r
    except Exception:
        pass
    try:
        return cm.Get(name)
    except Exception:
        return None


def _sldprt_sheet_metal_feature_present(sw_model) -> bool:
    """True si el árbol incluye SheetMetal o FlatPattern."""
    try:
        feat = sw_model.FirstFeature()
        while feat is not None:
            try:
                t = feat.GetTypeName2 or ""
            except Exception:
                t = ""
            if t:
                tl = t.lower()
                if "sheetmetal" in tl or "flatpattern" in tl:
                    return True
            try:
                feat = feat.GetNextFeature()
            except Exception:
                break
    except Exception:
        pass
    return False


_CUTLIST_ES_LARGO = ("Largo del envolvente",)
_CUTLIST_ES_ANCHO = ("Ancho del envolvente",)
_CUTLIST_EN_LARGO = ("Bounding Box Length",)
_CUTLIST_EN_ANCHO = ("Bounding Box Width",)
_CUTLIST_ESP_NAMES = (
    "Espesor de chapa",
    "Sheet Metal Thickness",
    "Thickness",
)


def _walk_cutlist_folders_recursive(feat, acc: List[Any], depth: int = 0) -> None:
    """Recorre el árbol como la macro VBA: hermanos vía GetNextFeature, hijos vía GetFirstSubFeature."""
    while feat is not None and depth < 80:
        try:
            tname = feat.GetTypeName2() if callable(feat.GetTypeName2) else feat.GetTypeName2
        except Exception:
            tname = ""
        tl = str(tname or "").lower()
        if "cutlistfolder" in tl:
            acc.append(feat)
        sub = None
        try:
            sub = feat.GetFirstSubFeature()
        except Exception:
            sub = None
        if sub is not None:
            _walk_cutlist_folders_recursive(sub, acc, depth + 1)
        try:
            feat = feat.GetNextFeature()
        except Exception:
            break


def _telemetry_read_prop_mm(cm, codigo: str, prop_name: str) -> Optional[float]:
    try:
        raw = _icm_get_property_raw(cm, prop_name)
        v = _parse_cutlist_length_mm(raw)
    except Exception as e:
        _cad_telemetry_append(codigo, f"Error COM detectado: {e!r}")
        _cad_telemetry_append(
            codigo, f"Intentando leer propiedad '{prop_name}'... Vacío"
        )
        return None
    if v is not None and v > 0:
        _cad_telemetry_append(
            codigo, f"Intentando leer propiedad '{prop_name}'... Valor={v}"
        )
        return float(v)
    _cad_telemetry_append(
        codigo, f"Intentando leer propiedad '{prop_name}'... Vacío"
    )
    return None


def _read_envelope_dual_language_cm(cm, codigo: str) -> Optional[tuple]:
    """CutListFolder: primero ES (envolvente); si falta, EN (Bounding Box Length/Width)."""
    if cm is None:
        return None
    lg = _telemetry_read_prop_mm(cm, codigo, _CUTLIST_ES_LARGO[0])
    an = _telemetry_read_prop_mm(cm, codigo, _CUTLIST_ES_ANCHO[0])
    if lg is not None and an is not None and lg > 0 and an > 0:
        esp = 0.0
        for nm in _CUTLIST_ESP_NAMES:
            try:
                raw = _icm_get_property_raw(cm, nm)
                e = _parse_cutlist_length_mm(raw)
            except Exception as ex:
                _cad_telemetry_append(codigo, f"Error COM detectado: {ex!r}")
                e = None
            if e is not None and e > 0:
                _cad_telemetry_append(
                    codigo, f"Intentando leer propiedad '{nm}'... Valor={e}"
                )
                esp = float(e)
                break
            _cad_telemetry_append(
                codigo, f"Intentando leer propiedad '{nm}'... Vacío"
            )
        return (max(lg, an), min(lg, an), esp)
    _cad_telemetry_append(
        codigo,
        "CutList ES incompleto; reintentando inglés (Bounding Box Length / Width)...",
    )
    lg2 = _telemetry_read_prop_mm(cm, codigo, _CUTLIST_EN_LARGO[0])
    an2 = _telemetry_read_prop_mm(cm, codigo, _CUTLIST_EN_ANCHO[0])
    if lg2 is None or an2 is None or lg2 <= 0 or an2 <= 0:
        return None
    esp2 = 0.0
    for nm in _CUTLIST_ESP_NAMES:
        try:
            raw = _icm_get_property_raw(cm, nm)
            e = _parse_cutlist_length_mm(raw)
        except Exception as ex:
            _cad_telemetry_append(codigo, f"Error COM detectado: {ex!r}")
            e = None
        if e is not None and e > 0:
            esp2 = float(e)
            break
    return (max(lg2, an2), min(lg2, an2), esp2)


def _cm_from_cutlist_feature(feat) -> Optional[Any]:
    if feat is None:
        return None
    try:
        cm = feat.CustomPropertyManager("")
    except Exception:
        cm = None
    if cm is None:
        try:
            gcpm = getattr(feat, "GetCustomPropertyManager", None)
            if callable(gcpm):
                cm = gcpm("")
        except Exception:
            cm = None
    return cm


def _sldprt_cutlist_envelope_dims_mm(sw_model, codigo_log: str = "") -> Optional[tuple]:
    """Réplica estilo VBA: actualiza CutList, árbol recursivo → CutListFolder, CM sin SetSuppress2."""
    cid = (codigo_log or "?").strip() or "?"

    try:
        ext = sw_model.Extension
        if ext is not None:
            for _upd in ("UpdateCutList", "UpdateSheetMetalCutList"):
                fn = getattr(ext, _upd, None)
                if callable(fn):
                    try:
                        fn()
                        _cad_telemetry_append(cid, f"{_upd}() OK.")
                        break
                    except Exception as e:
                        _cad_telemetry_append(
                            cid, f"Error COM en {_upd}(): {e!r}"
                        )
    except Exception as e:
        _cad_telemetry_append(cid, f"Error COM (Extension/CutList): {e!r}")
    try:
        if callable(getattr(sw_model, "ForceRebuild3", None)):
            sw_model.ForceRebuild3(False)
        elif callable(getattr(sw_model, "ForceRebuild2", None)):
            sw_model.ForceRebuild2(False)
        elif callable(getattr(sw_model, "ForceRebuild", None)):
            sw_model.ForceRebuild()
    except Exception as e:
        _cad_telemetry_append(cid, f"Error COM en ForceRebuild: {e!r}")

    cutlist_feats: List[Any] = []
    try:
        root = sw_model.FirstFeature()
    except Exception as e:
        _cad_telemetry_append(cid, f"Error COM FirstFeature: {e!r}")
        root = None
    _walk_cutlist_folders_recursive(root, cutlist_feats, 0)
    if cutlist_feats:
        _cad_telemetry_append(
            cid,
            f"Intentando buscar CutListFolder... Éxito ({len(cutlist_feats)} carpeta(s))",
        )
    else:
        _cad_telemetry_append(cid, "Intentando buscar CutListFolder... Fallo")

    seen_ids: set = set()
    for clf in cutlist_feats:
        try:
            fid = id(clf)
        except Exception:
            fid = None
        if fid is not None:
            if fid in seen_ids:
                continue
            seen_ids.add(fid)

        out = _read_envelope_dual_language_cm(_cm_from_cutlist_feature(clf), cid)
        if out is not None:
            return out

        sub2 = None
        try:
            sub2 = clf.GetFirstSubFeature()
        except Exception:
            sub2 = None
        while sub2 is not None:
            out = _read_envelope_dual_language_cm(_cm_from_cutlist_feature(sub2), cid)
            if out is not None:
                return out
            try:
                sub2 = sub2.GetNextSubFeature()
            except Exception:
                break

    try:
        cmgr = sw_model.ConfigurationManager
        if cmgr is not None and cmgr.ActiveConfiguration is not None:
            conf_name = cmgr.ActiveConfiguration.Name
            cm = sw_model.Extension.CustomPropertyManager(conf_name)
            _cad_telemetry_append(cid, f"Fallback CM configuración '{conf_name}'...")
            out = _read_envelope_dual_language_cm(cm, cid)
            if out is not None:
                return out
    except Exception as e:
        _cad_telemetry_append(cid, f"Error COM (Configuration CM): {e!r}")

    try:
        cm = sw_model.Extension.CustomPropertyManager("")
        _cad_telemetry_append(cid, "Fallback CM documento (vacío)...")
        out = _read_envelope_dual_language_cm(cm, cid)
        if out is not None:
            return out
    except Exception as e:
        _cad_telemetry_append(cid, f"Error COM (CustomPropertyManager doc): {e!r}")

    return None


_DXF_CAD_AUDIT_TOL_MM = 1.0


def _dxf_bbox_largo_ancho_mm(dxf_path: str) -> Optional[tuple]:
    try:
        import ezdxf
        from ezdxf import bbox as _eb
        doc = ezdxf.readfile(dxf_path)
        ex = _eb.extents(doc.modelspace())
        if not ex.has_data:
            return None
        dx = ex.extmax.x - ex.extmin.x
        dy = ex.extmax.y - ex.extmin.y
        return (float(max(dx, dy)), float(min(dx, dy)))
    except Exception:
        return None


def _resolve_dxf_path_for_codigo(root_path: str, codigo: str, info_codigo: str = "") -> Optional[str]:
    for stem_try in (
        _normalize_chapa_stem(codigo),
        _normalize_chapa_stem(info_codigo),
        codigo,
        info_codigo,
    ):
        if not stem_try:
            continue
        for sub in ("dxf", "BIBLIOTECA_DXF"):
            p = os.path.join(root_path, sub, f"{stem_try}.dxf")
            if os.path.exists(p):
                return p
    return None


_CAD_2D_WALK_EXCLUDE = frozenset({
    "dxf_convertidos", "exportados", "biblioteca_dxf",
    "cad_pendientes", "reportes", "__pycache__", ".git",
    "node_modules", "venv", ".venv", "dist", "build",
    "piezas_a_procesar",
})


def _find_network_2d_paths_for_codigo(network_root: str, codigo_norm: str) -> tuple:
    """Todas las rutas .dxf / .dwg en red cuyo nombre (con o sin 'Chapa desplegada - ') coincide con codigo_norm."""
    cn = (codigo_norm or "").strip().upper()
    if not cn or not network_root or not os.path.isdir(network_root):
        return [], []
    dxfs: List[str] = []
    dwgs: List[str] = []
    for root_dir, dirs, files in os.walk(network_root):
        dirs[:] = [
            d for d in dirs
            if d.lower() not in _CAD_2D_WALK_EXCLUDE
            and not d.startswith(".")
            and "obsoleto" not in d.lower()
        ]
        for f in files:
            if f.startswith("~$") or "obsoleto" in f.lower():
                continue
            low = f.lower()
            if not (low.endswith(".dxf") or low.endswith(".dwg")):
                continue
            stem = os.path.splitext(f)[0]
            if _normalize_chapa_stem(stem).strip().upper() != cn:
                continue
            full = os.path.join(root_dir, f)
            if _cad_path_has_obsoleto(full):
                continue
            if low.endswith(".dxf"):
                dxfs.append(full)
            else:
                dwgs.append(full)
    return dxfs, dwgs


def _pick_newest_path(paths: List[str]) -> Optional[str]:
    if not paths:
        return None
    try:
        return max(paths, key=lambda p: os.path.getmtime(p))
    except OSError:
        return paths[0]


def _convert_dwgs_batch_to_dxf(pairs: List[tuple]) -> None:
    """pairs: list of (ruta_dwg_abs, ruta_dxf_salida_abs). Una sesión AutoCAD."""
    if not pairs:
        return
    try:
        import win32com.client as _wc
    except Exception:
        for _, out in pairs:
            _escribir_log(f"[2D] AutoCAD no disponible; no se convirtió a {out}")
        return
    acad = None
    try:
        acad = _wc.Dispatch("AutoCAD.Application")
        try:
            acad.Visible = False
        except Exception:
            pass
        for dwg_abs, out_dxf in pairs:
            doc = None
            try:
                doc = acad.Documents.Open(dwg_abs)
                doc.SaveAs(out_dxf, 37)
                _escribir_log(f"[2D] DWG→DXF OK: {dwg_abs} → {out_dxf}")
            except Exception as ex:
                _escribir_log(f"[2D] DWG→DXF FALLO: {dwg_abs} → {ex!r}")
            finally:
                try:
                    if doc:
                        doc.Close(False)
                except Exception:
                    pass
    finally:
        try:
            if acad:
                acad.Quit()
        except Exception:
            pass


def _materialize_universal_2d_for_pipeline(
    network_root: str,
    local_work_dir: str,
    dxf_local_dir: str,
    piezas_objetivo: Optional[set],
) -> None:
    """Paso 0/2: por cada .sldprt local, busca en red JA-002 / Chapa desplegada - JA-002 × (.dwg|.dxf)
    y deja siempre dxf/{CODIGO}.dxf (copia DXF o convierte DWG)."""
    if not os.path.isdir(local_work_dir):
        return
    codigos: set = set()
    try:
        for fn in os.listdir(local_work_dir):
            if fn.upper().endswith(".SLDPRT"):
                stem = os.path.splitext(fn)[0]
                codigos.add(_normalize_chapa_stem(stem).strip().upper())
    except OSError:
        return
    os.makedirs(dxf_local_dir, exist_ok=True)
    to_convert: List[tuple] = []
    for c in sorted(codigos):
        if piezas_objetivo is not None and len(piezas_objetivo) > 0 and c not in piezas_objetivo:
            continue
        dxfs, dwgs = _find_network_2d_paths_for_codigo(network_root, c)
        best_dxf = _pick_newest_path(dxfs)
        best_dwg = _pick_newest_path(dwgs)
        out_dxf = os.path.join(dxf_local_dir, f"{c}.dxf")
        if best_dxf:
            try:
                shutil.copy2(best_dxf, out_dxf)
                _escribir_log(f"[2D] {c}: DXF red → {out_dxf} (origen {best_dxf})")
            except Exception as ex:
                _escribir_log(f"[2D] {c}: copia DXF falló {ex!r}")
        elif best_dwg:
            to_convert.append((best_dwg, out_dxf))
        else:
            _escribir_log(f"[2D] {c}: sin .dwg/.dxf en red (variantes nombre normalizadas)")
    _convert_dwgs_batch_to_dxf(to_convert)


def _find_flat_pattern_recursive(feat):
    while feat is not None:
        try:
            t = feat.GetTypeName2() if callable(feat.GetTypeName2) else feat.GetTypeName2
        except Exception:
            t = ""
        if t == "FlatPattern":
            return feat

        sub_feat = None
        try:
            sub_feat = feat.GetFirstSubFeature()
        except Exception:
            pass

        if sub_feat is not None:
            found = _find_flat_pattern_recursive(sub_feat)
            if found is not None:
                return found

        try:
            feat = feat.GetNextFeature()
        except Exception:
            break
    return None

def _find_flat_pattern_feature(sw_model):
    """Búsqueda profunda/recursiva de la primera operación con GetTypeName2 == 'FlatPattern'."""
    try:
        return _find_flat_pattern_recursive(sw_model.FirstFeature())
    except Exception:
        return None


def _sw_clear_selection(sw_model) -> None:
    try:
        sw_model.ClearSelection2(True)
    except Exception:
        try:
            sw_model.ClearSelection()
        except Exception:
            pass


def _feat_select_for_edit(feat) -> bool:
    if feat is None:
        return False
    try:
        feat.Select2(False, 0)
        return True
    except Exception:
        pass
    try:
        feat.Select(False)
    except Exception:
        pass
    try:
        feat.Select2(0, False, -1)
    except Exception:
        pass
    return False


def _sw_edit_unsuppress(sw_model) -> None:
    for fn in (
        getattr(sw_model, "EditUnsuppress2", None),
        getattr(sw_model.Extension, "EditUnsuppress2", None) if sw_model.Extension else None,
    ):
        if callable(fn):
            try:
                fn()
                return
            except Exception:
                continue


def _sw_edit_suppress(sw_model) -> None:
    for fn in (
        getattr(sw_model, "EditSuppress2", None),
        getattr(sw_model.Extension, "EditSuppress2", None) if sw_model.Extension else None,
    ):
        if callable(fn):
            try:
                fn()
                return
            except Exception:
                continue


def _sw_force_rebuild(sw_model) -> None:
    try:
        if callable(getattr(sw_model, "ForceRebuild3", None)):
            sw_model.ForceRebuild3(False)
        elif callable(getattr(sw_model, "ForceRebuild2", None)):
            sw_model.ForceRebuild2(False)
        elif callable(getattr(sw_model, "ForceRebuild", None)):
            sw_model.ForceRebuild()
    except Exception:
        pass


def _apply_dxf_cad_audit_cross(
    observacion: str,
    largo_cad: float,
    ancho_cad: float,
    dxf_largo: Optional[float],
    dxf_ancho: Optional[float],
) -> str:
    if dxf_largo is None or dxf_ancho is None:
        return observacion
    try:
        dl = float(dxf_largo)
        da = float(dxf_ancho)
    except (TypeError, ValueError):
        return observacion
    if largo_cad <= 0 or ancho_cad <= 0:
        return observacion
    if (
        abs(largo_cad - dl) > _DXF_CAD_AUDIT_TOL_MM
        or abs(ancho_cad - da) > _DXF_CAD_AUDIT_TOL_MM
    ):
        return (
            f"⚠️ ALERTA: Medidas CAD ({largo_cad}x{ancho_cad}) no coinciden con DXF ({dl}x{da})"
        )
    return "OK (CAD y DXF coinciden)"


def _sldprt_bounding_box_dims_mm(sw_model) -> Optional[tuple]:
    """GetPartBox(True) → deltas en m (típico API), ×1000 a mm; ordena X/Y/Z de mayor a menor → largo, ancho, espesor."""
    try:
        vbox = sw_model.GetPartBox(True)
        if vbox is None:
            return None
        seq: List[float] = []
        try:
            n = len(vbox)
            for i in range(min(n, 6)):
                seq.append(float(vbox[i]))
        except Exception:
            try:
                for x in vbox:
                    seq.append(float(x))
            except Exception:
                return None
        if len(seq) < 6:
            return None
        xmin, ymin, zmin, xmax, ymax, zmax = seq[0], seq[1], seq[2], seq[3], seq[4], seq[5]
        dx = abs(xmax - xmin) * 1000.0
        dy = abs(ymax - ymin) * 1000.0
        dz = abs(zmax - zmin) * 1000.0
        dims = sorted((dx, dy, dz), reverse=True)
        return (dims[0], dims[1], dims[2])
    except Exception:
        return None


def _sldprt_flat_pattern_physical_dims_mm(sw_model) -> tuple:
    """Despliega físicamente FlatPattern usando SetSuppress2 directo y reconstrucción, luego lo vuelve a doblar."""
    flat = _find_flat_pattern_feature(sw_model)
    if flat is None:
        return None, ""
    dims_out = None
    err_acc = ""
    try:
        try:
            is_supp = flat.IsSuppressed2(2)
            _escribir_log(f"[CAD Telemetría] FlatPattern estado inicial suprimido? {is_supp}")
        except Exception as e:
            _escribir_log(f"[CAD Telemetría] Error leyendo supresión: {e}")

        try:
            flat.SetSuppress2(2, 2, None)
            sw_model.EditRebuild3()
            sw_model.ForceRebuild3(False)
        except Exception as e:
            err_step = f"SetSuppress2(desdoblar) falló: {e}"
            _escribir_log(f"[CAD Telemetría] {err_step}")
            err_acc += f" {err_step}"
            raise e

        try:
            err_code = flat.GetErrorCode2()
            _escribir_log(f"[CAD Telemetría] FlatPattern error code post-desdoblar: {err_code}")
        except Exception as e:
            _escribir_log(f"[CAD Telemetría] Error leyendo error code: {e}")

        dims_out = _sldprt_bounding_box_dims_mm(sw_model)
    except Exception as e:
        import traceback
        _escribir_log(f"[CAD Telemetría] Error en bloque de desdoble:\n{traceback.format_exc()}")
        if not err_acc:
            err_acc += f" Error general: {e}"
        dims_out = None
    finally:
        try:
            flat.SetSuppress2(0, 2, None)
            sw_model.EditRebuild3()
            sw_model.ForceRebuild3(False)
        except Exception as e:
            err_step = f"SetSuppress2(doblar) falló: {e}"
            _escribir_log(f"[CAD Telemetría] {err_step}")
            err_acc += f" {err_step}"

    return dims_out, err_acc


def _sldprt_write_custom_props_and_save(
    sw_model,
    ruta_abs: str,
    largo: float,
    ancho: float,
    espesor: float,
    codigo_pieza: Optional[str] = None,
) -> bool:
    """CustomPropertyManager Add3/Set + Save3 en la ruta local."""
    import pythoncom
    import win32com.client as _wc
    try:
        cm = sw_model.Extension.CustomPropertyManager("")
        pairs = []
        if codigo_pieza and str(codigo_pieza).strip():
            pairs.append(("CODIGO_PIEZA", str(codigo_pieza).strip()))
        pairs.extend(
            [
                ("Largo_CAD", f"{largo:.4f}"),
                ("Ancho_CAD", f"{ancho:.4f}"),
                ("Espesor_Perfil_CAD", f"{espesor:.4f}"),
            ]
        )
        for name, val in pairs:
            try:
                cm.Delete2(name)
            except Exception:
                pass
            try:
                cm.Add3(name, _SW_CUSTOM_INFO_TEXT, val)
            except Exception:
                try:
                    cm.Set2(name, _SW_CUSTOM_INFO_TEXT, val)
                except Exception:
                    try:
                        cm.Set2(name, val)
                    except Exception:
                        try:
                            cm.Set(name, val)
                        except Exception:
                            return False
        n_err = _wc.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
        n_warn = _wc.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
        try:
            sw_model.Save3(1, n_err, n_warn)
            return True
        except Exception:
            try:
                sw_model.SaveAs(ruta_abs)
                return True
            except Exception:
                return False
    except Exception:
        return False


def _sldprt_delete_doc_cad_measure_props(sw_model) -> None:
    """Pizarra en blanco: quita medidas CAD guardadas antes de medir de nuevo."""
    try:
        cm = sw_model.Extension.CustomPropertyManager("")
        for nm in ("Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD"):
            try:
                cm.Delete2(nm)
            except Exception:
                pass
    except Exception:
        pass


@router.post("/api/cad/abort")
def abort_cad():
    global abortar_escaneo_cad, scan_status
    abortar_escaneo_cad = True
    scan_status["status"] = "cancelled"
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    with open(flag_path, "w") as f:
        f.write("abort")
    return {"status": "aborting"}

def _sldprt_extract_one(
    sw_local,
    abspath,
    codigo,
    nombre_archivo,
    ruta_abs,
    resurrect_fn=None,
    inyectar_propiedades: bool = False,
    ruta_original_red: Optional[str] = None,
    dxf_largo_cmp: Optional[float] = None,
    dxf_ancho_cmp: Optional[float] = None,
):
    """Extrae propiedades CAD de un .sldprt. Acción síncrona COM (debe estar en el hilo correcto).

    Args:
        sw_local: instancia SolidWorks (ya inicializada en este hilo).
        resurrect_fn: callable sin args que mata SLDWORKS y retorna una nueva instancia SW
                      (o None para saltarse la resurrección).
        inyectar_propiedades: si True, escribe propiedades, Save3 local y copia a ruta_original_red.
        ruta_original_red: ruta en red del archivo original (solo pipeline maestro).
        dxf_largo_cmp / dxf_ancho_cmp: medidas DXF (mm) para auditoría cruzada ±1 mm.
    """
    import re as _re
    largo_cad = 0.0
    ancho_cad = 0.0
    espesor_cad = 0.0
    largo_dxf_nuevo = None
    ancho_dxf_nuevo = None
    observacion = ""
    codigo = _normalize_chapa_stem(str(codigo))
    if not ruta_abs.upper().endswith(".SLDPRT"):
        return {
            "codigo": _ascii_report_text(codigo),
            "largo_cad": largo_cad,
            "ancho_cad": ancho_cad,
            "espesor_cad": espesor_cad,
            "observacion": _ascii_report_text("Omitido (no es .SLDPRT)"),
            "rpc_continue": False,
        }

    injected_and_saved = False
    swDocPART = 1
    SW_OPEN_SILENT = 1
    SW_OPEN_READONLY = 2
    
    es_posible_chapa = "chapa" in codigo.lower() or "chapa" in nombre_archivo.lower()
    
    if inyectar_propiedades or es_posible_chapa:
        open_options = SW_OPEN_SILENT
    else:
        open_options = SW_OPEN_SILENT | SW_OPEN_READONLY

    arg_errors = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
    arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
    swModel = None
    try:
        swModel = sw_local.OpenDoc6(
            ruta_abs, swDocPART, open_options, "", arg_errors, arg_warnings,
        )
    except Exception as try_open_err:
        err_str = repr(try_open_err)
        err_code = getattr(try_open_err, "hresult", None)
        _RPC_CODES = {-2147023170, -2147023174, -2147417848}
        is_rpc_crash = (
            any(str(c) in err_str for c in _RPC_CODES)
            or (err_code is not None and err_code in _RPC_CODES)
        )
        if is_rpc_crash:
            import logging as _lg
            _lg.error(f"[SW-RPC] Crash en '{ruta_abs}': {err_str}")
            scan_status["warning_message"] = f"⚠️ Saltado por versión: {nombre_archivo}"
            if resurrect_fn:
                resurrect_fn()
            return {
                "rpc_continue": True,
                "codigo": _ascii_report_text(codigo),
                "largo_cad": 0.0, "ancho_cad": 0.0, "espesor_cad": 0.0,
                "observacion": _ascii_report_text(
                    "ERROR RPC: Archivo de version anterior o corrupto. "
                    "Primero actualiza/guarda la pieza manualmente en esta version."
                ),
            }
        observacion = f"Error apertura: {str(try_open_err)[:60]}"
        swModel = None

    if swModel is None:
        if not observacion.startswith("Error apertura"):
            observacion = (
                "ERROR: Archivo de version mas reciente. "
                "Actualiza SolidWorks en esta computadora."
            )
            scan_status["warning_message"] = f"⚠️ Saltado por versión: {nombre_archivo}"
    else:
        scan_status["warning_message"] = ""
        try:
            _sldprt_delete_doc_cad_measure_props(swModel)
            prop_mgr = swModel.Extension.CustomPropertyManager("")

            def safe_get_prop(prop_val):
                if not prop_val:
                    return ""
                if isinstance(prop_val, str):
                    return _clean_com_text(prop_val)
                if isinstance(prop_val, (tuple, list)):
                    if len(prop_val) > 1 and prop_val[1]:
                        return _clean_com_text(str(prop_val[1]))
                    if len(prop_val) > 0 and prop_val[0]:
                        return _clean_com_text(str(prop_val[0]))
                return _clean_com_text(str(prop_val))

            codigo_val = safe_get_prop(prop_mgr.Get("CODIGO_PIEZA")).strip()
            if codigo_val:
                codigo = _normalize_chapa_stem(codigo_val)

            largo_val = safe_get_prop(prop_mgr.Get("Largo_CAD"))
            ancho_val = safe_get_prop(prop_mgr.Get("Ancho_CAD"))
            espesor_val = safe_get_prop(prop_mgr.Get("Espesor_Perfil_CAD"))

            if largo_val and ancho_val:
                try:
                    l_str = _re.sub(r"[^\d.]", "", str(largo_val).lower().replace("mm", "").strip().replace(",", "."))
                    a_str = _re.sub(r"[^\d.]", "", str(ancho_val).lower().replace("mm", "").strip().replace(",", "."))
                    largo = float(l_str) if l_str and l_str != "." else 0.0
                    ancho = float(a_str) if a_str and a_str != "." else 0.0
                    largo_cad = max(largo, ancho)
                    ancho_cad = min(largo, ancho)
                    espesor_cad = 0.0
                    if espesor_val:
                        e_str = _re.sub(r"[^\d.]", "", str(espesor_val).lower().replace("mm", "").strip().replace(",", "."))
                        espesor_cad = float(e_str) if e_str and e_str != "." else 0.0
                    observacion = "OK" if largo_cad > 0 and ancho_cad > 0 else "No detectado (valores incompletos)"
                except ValueError as ve:
                    observacion = f"Error metrico: {ve}"
            else:
                observacion = "No detectado (faltan propiedades)"

            is_chapa = _sldprt_sheet_metal_feature_present(swModel)
            if is_chapa:
                # Plan A — CutListFolder + CM (nativo VBA, sin SetSuppress2)
                cl_dims = _sldprt_cutlist_envelope_dims_mm(swModel, codigo)
                if cl_dims and float(cl_dims[0]) > 0 and float(cl_dims[1]) > 0:
                    largo_cad = float(cl_dims[0])
                    ancho_cad = float(cl_dims[1])
                    if len(cl_dims) > 2 and float(cl_dims[2]) > 0 and espesor_cad <= 0:
                        espesor_cad = float(cl_dims[2])
                    observacion = "OK (CutList Nativa)"
                else:
                    # Plan B — solo lectura doblado (GetPartBox)
                    bb_fold = _sldprt_bounding_box_dims_mm(swModel)
                    if bb_fold and float(bb_fold[0]) > 0 and float(bb_fold[1]) > 0:
                        largo_cad = float(bb_fold[0])
                        ancho_cad = float(bb_fold[1])
                        if len(bb_fold) > 2 and espesor_cad <= 0:
                            espesor_cad = float(bb_fold[2])
                        observacion = "⚠️ ALERTA: Medida de pieza doblada"
                    else:
                        largo_cad = 0.0
                        ancho_cad = 0.0
                        observacion = "ERROR: Chapa sin medidas (CutList ni caja doblada)."
            elif largo_cad == 0 or ancho_cad == 0:
                bb_dims = _sldprt_bounding_box_dims_mm(swModel)
                if bb_dims:
                    largo_cad, ancho_cad, espesor_cad = bb_dims
                    observacion = "OK (Bounding Box)"

            if largo_cad > 0 and ancho_cad > 0 and observacion.startswith("No detectado"):
                observacion = "OK"

            observacion = _apply_dxf_cad_audit_cross(
                observacion, largo_cad, ancho_cad, dxf_largo_cmp, dxf_ancho_cmp
            )

            _escribir_log(f"✅ {codigo}: L={largo_cad} A={ancho_cad} E={espesor_cad}")

            if is_chapa and "ALERTA" in observacion:
                try:
                    dxf_folder = os.path.join(_piezas_a_procesar_desktop_dir(), "dxf")
                    os.makedirs(dxf_folder, exist_ok=True)
                    ruta_dxf_nuevo = os.path.join(
                        dxf_folder, f"{codigo}_SW_CORREGIDO.dxf"
                    )

                    if swModel is not None:
                        try:
                            sw_local.Visible = True
                            swModel.Extension.ExportToDWG2(
                                ruta_dxf_nuevo, ruta_abs, 1, True, None,
                                False, False, 1, None,
                            )
                        except Exception as _ex_dwg:
                            _escribir_log(f"ExportToDWG2 {codigo}: {_ex_dwg!r}")

                    if os.path.exists(ruta_dxf_nuevo):
                        _d = ezdxf.readfile(ruta_dxf_nuevo)
                        _ext_dxf = ezdxf_bbox.extents(_d.modelspace())
                        if _ext_dxf.has_data:
                            _dx = _ext_dxf.extmax.x - _ext_dxf.extmin.x
                            _dy = _ext_dxf.extmax.y - _ext_dxf.extmin.y
                            largo_dxf_nuevo = float(max(_dx, _dy))
                            ancho_dxf_nuevo = float(min(_dx, _dy))
                            observacion += (
                                f" | DXF Auto-Corregido: {largo_dxf_nuevo:.1f}x{ancho_dxf_nuevo:.1f}"
                            )
                except Exception as export_err:
                    _escribir_log(f"Error auto-exportando FlatPattern: {export_err}")

            if (
                inyectar_propiedades
                and ruta_original_red
                and largo_cad > 0
                and ancho_cad > 0
                and os.path.isfile(ruta_original_red)
            ):
                injected_and_saved = _sldprt_write_custom_props_and_save(
                    swModel, ruta_abs, largo_cad, ancho_cad, espesor_cad, codigo_pieza=codigo
                )
        except Exception as math_err:
            observacion = f"Error matematico: {str(math_err)[:50]}"
        finally:
            try:
                doc_title = None
                try:
                    if swModel is not None:
                        doc_title = swModel.GetTitle()
                        if not injected_and_saved:
                            try:
                                swModel.SetSaveFlag(False)
                            except Exception:
                                pass
                except Exception:
                    pass
                if doc_title:
                    try:
                        sw_local.QuitDoc(doc_title)
                    except Exception:
                        sw_local.CloseDoc(doc_title)
                else:
                    try:
                        sw_local.QuitDoc(abspath)
                    except Exception:
                        sw_local.CloseDoc(abspath)
            except Exception:
                pass

    if injected_and_saved and ruta_original_red:
        try:
            shutil.copy2(ruta_abs, ruta_original_red)
        except Exception as copy_err:
            observacion = f"{observacion} | Red: copia fallida ({str(copy_err)[:60]})"

    resultados = {
        "rpc_continue": False,
        "codigo": _ascii_report_text(codigo),
        "largo_cad": largo_cad,
        "ancho_cad": ancho_cad,
        "espesor_cad": espesor_cad,
        "observacion": _ascii_report_text(observacion),
    }
    # Excel: columnas Largo_DXF_Nuevo / Ancho_DXF_Nuevo (desde ExportToDWG2 + ezdxf)
    resultados["largo_dxf_nuevo"] = largo_dxf_nuevo
    resultados["ancho_dxf_nuevo"] = ancho_dxf_nuevo
    return resultados


def bg_scan_cad_task(root_path: str, solo_faltantes: bool = False):
    global scan_status, abortar_escaneo_cad
    import datetime
    data = []
    sw_app = None
    acad_app = None
    try:
        import pythoncom
        import logging
        pythoncom.CoInitialize()
    except Exception:
        pass
    
    scan_status["status"] = "scanning"
    scan_status["progress"] = 0
    scan_status["total"] = 0
    scan_status["excel_path"] = ""
    scan_status["error"] = ""
    scan_status["warning_message"] = ""
    scan_status["current_file"] = ""
    scan_status["current_item"] = 0
    scan_status["total_items"] = 0

    _cad_telemetry_clear()

    # Carpetas del sistema a excluir para evitar duplicados y bucles
    _EXCLUDED_DIRS = {
        "dxf_convertidos", "exportados", "biblioteca_dxf",
        "cad_pendientes", "reportes", "__pycache__", ".git",
        "node_modules", "venv", ".venv", "dist", "build"
    }
    
    # BÃºsqueda de archivos
    cad_files = {} # Key: filename without extension, Value: dict of details
    
    extensions_to_look = {".sldprt"}
    
    try:
        processed_count = 0
        for dirpath, dirs, filenames in os.walk(root_path):
            # ExclusiÃ³n de carpetas del sistema â€” modifica dirs in-place
            # para que os.walk NO descienda a esas subcarpetas.
            dirs[:] = [
                d for d in dirs
                if d.lower() not in _EXCLUDED_DIRS
                and not d.startswith('.')
                and "obsoleto" not in d.lower()
            ]

            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                break
            
            for f in filenames:
                if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                    break
                    
                if f.startswith("~$"):
                    continue
                if "obsoleto" in f.lower():
                    continue
                    
                ext = os.path.splitext(f)[1].lower()
                if ext in extensions_to_look:
                    codigo_pieza = _normalize_chapa_stem(os.path.splitext(f)[0])
                    abspath = os.path.join(dirpath, f)
                    if _cad_path_has_obsoleto(abspath):
                        continue
                    
                    try:
                        mtime = os.path.getmtime(abspath)
                        if codigo_pieza in cad_files:
                            if mtime > cad_files[codigo_pieza]["mtime"]:
                                cad_files[codigo_pieza] = {
                                    "mtime": mtime,
                                    "abspath": abspath,
                                    "ext": ext,
                                    "codigo": codigo_pieza
                                }
                        else:
                            cad_files[codigo_pieza] = {
                                "mtime": mtime,
                                "abspath": abspath,
                                "ext": ext,
                                "codigo": codigo_pieza
                            }
                    except OSError:
                        pass # Ignore restricted or missing files
                
                processed_count += 1
                if processed_count % 50 == 0: # Update progress every 50 files
                    scan_status["progress"] = processed_count
                    
        scan_status["progress"] = processed_count
        
        if scan_status["status"] == "cancelled":
            scan_status["status"] = "idle"
            return
            
        scan_status["status"] = "generating_excel"

        if solo_faltantes:
            try:
                conn = get_db_connection()
                cur = conn.cursor()
                cur.execute(
                    f"""
                    SELECT Codigo_Pieza
                    FROM Tbl_Maestro_Piezas
                    WHERE (
                        Largo_CAD IS NULL
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = ''
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = '-'
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = '0'
                       OR (
                            TRY_CAST(Largo_CAD AS FLOAT) IS NOT NULL
                            AND TRY_CAST(Largo_CAD AS FLOAT) = 0
                          )
                    )
                    {_SQL_EXCLUIR_COMERCIALES}
                    """
                )
                rows = cur.fetchall()
                cur.close()
                conn.close()
                faltantes_norm = set()
                for r in rows:
                    if r and r[0] is not None:
                        faltantes_norm.add(str(r[0]).strip().upper())
                cad_files = {
                    k: v
                    for k, v in cad_files.items()
                    if str(k).strip().upper() in faltantes_norm
                }
                print(
                    f"[CAD] solo_faltantes (sin comerciales): {len(faltantes_norm)} codigos en maestro sin medida, "
                    f"{len(cad_files)} archivos .sldprt coincidentes en carpeta."
                )
            except Exception as ex_sf:
                print(f"[CAD] solo_faltantes: error consultando Tbl_Maestro_Piezas: {ex_sf}")
        
        # Generar Excel y extraer metadata CAD
        import time as _time
        try:
            import ezdxf
            from ezdxf import bbox
        except ImportError:
            pass
            
        try:
            import win32com.client
            import pythoncom
        except ImportError:
            pass

        # â”€â”€ ProtecciÃ³n de Hilos COM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        # FastAPI usa hilos; cada hilo necesita su propio apartamento COM.
        # CoInitialize DEBE llamarse antes de crear cualquier objeto COM.
        try:
            pythoncom.CoInitialize()
        except Exception:
            pass
            
        def _apply_silent_mode(app):
            """SolidWorks visible para ver diálogos de error COM; se mantienen supresiones de avisos vía toggles."""
            try:
                app.Visible = True
            except Exception:
                pass
            try:
                app.UserControl = True
            except Exception:
                pass
            try:
                # swUserPreferenceToggle_e.swSuppressDialogs = 11
                # Suprime todos los mensajes emergentes y confirmaciones
                app.SetUserPreferenceToggle(11, True)
            except Exception:
                pass
            try:
                # swUserPreferenceToggle_e.swSuppressWarnings = 262
                # Suprime advertencias de reconstrucciÃ³n y referencias rotas
                app.SetUserPreferenceToggle(262, True)
            except Exception:
                pass

        def get_sw_app():
            try:
                # DispatchEx fuerza un proceso SLDWORKS.EXE nuevo e independiente,
                # evitando secuestrar la sesiÃ³n manual del usuario.
                app = win32com.client.DispatchEx("SldWorks.Application")
                try:
                    app.Visible = True
                except Exception:
                    pass
                app.UserControl = True
                _apply_silent_mode(app)
                _escribir_log("[SW] Instancia COM (DispatchEx) Visible=True (diagnóstico pop-ups).")
                return app
            except Exception as e:
                _escribir_log(f"ADVERTENCIA: Motor SolidWorks inaccesible: {e}")
                return None
                
        def get_acad_app():
            try:
                app = win32com.client.Dispatch("AutoCAD.Application")
                # app.Visible = False # AutoCAD usually resists being hidden natively sometimes, but we can try if needed
                return app
            except Exception as e:
                print(f"ADVERTENCIA: Motor AutoCAD inaccesible: {e}")
                return None

        def _resurrect_solidworks_com_after_kill():
            """Mata SLDWORKS y reinicia apartamento COM en el hilo actual (mismo patrón que crash RPC)."""
            try:
                os.system("taskkill /F /IM SLDWORKS.exe /T 2>nul")
            except Exception:
                pass
            _time.sleep(3)
            try:
                pythoncom.CoUninitialize()
            except Exception:
                pass
            try:
                pythoncom.CoInitialize()
            except Exception:
                pass
            return get_sw_app()


        has_sldprt = any(info["ext"] == ".sldprt" for info in cad_files.values())
        sw_app = None
        
        has_dwg = any(info["ext"] == ".dwg" for info in cad_files.values())
        acad_app = get_acad_app() if has_dwg else None
                
        lista_archivos = list(cad_files.values())
        total_a_extraer = len(lista_archivos)
        extraidos = 0
        scan_status["total"] = total_a_extraer
        scan_status["total_items"] = total_a_extraer
        scan_status["current_item"] = 0
        
        print(f"=== INICIANDO EXTRACCIÃ“N CAD ({total_a_extraer} archivos Ãºnicos) ===")

        for i, info in enumerate(lista_archivos):
            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                import logging
                logging.info("Escaneo abortado por el usuario.")
                try:
                    os.system("taskkill /F /IM SLDWORKS.exe /T 2>nul")
                except Exception:
                    pass
                if sw_app: 
                    try: sw_app.ExitApp()
                    except: pass
                if acad_app:
                    try: acad_app.Quit()
                    except: pass
                scan_status["status"] = "cancelled"
                break

            nombre_archivo = os.path.basename(info["abspath"])
            _current_file_msg = f"Procesando pieza {i + 1} de {total_a_extraer}: {nombre_archivo}"
            scan_status["current_file"] = _current_file_msg
            scan_status["current_item"] = i + 1

            scan_status["total_items"] = total_a_extraer

            # Reportar a la mini-consola de Flutter

            _ts_scan = datetime.datetime.now().strftime("%H:%M:%S")

            cad_execution_logs.append(f"[{_ts_scan}] {_current_file_msg}")

            print(f"â³ {_current_file_msg}")

            dt = datetime.datetime.fromtimestamp(info["mtime"]).strftime("%Y-%m-%d %H:%M:%S")
            ext = info["ext"]
            abspath = info["abspath"]
            codigo = info["codigo"]
            
            # FIX: Inicializar TODAS las variables antes del try para evitar UnboundLocalError
            largo_cad = 0.0
            ancho_cad = 0.0
            espesor_cad = 0.0
            observacion = ""
            tiene_dxf = "NO"
            largo_dxf = ""
            ancho_dxf = ""
            largo_dxf_nuevo: Optional[float] = None
            ancho_dxf_nuevo: Optional[float] = None

            try:
                if ext == ".dxf":
                    doc = ezdxf.readfile(abspath)
                    msp = doc.modelspace()
                    extents = bbox.extents(msp)
                    if extents.has_data:
                        dx = extents.extmax.x - extents.extmin.x
                        dy = extents.extmax.y - extents.extmin.y
                        largo_cad = max(dx, dy)
                        ancho_cad = min(dx, dy)
                        observacion = "OK"
                        
                elif ext == ".dwg" and acad_app:
                    try:
                        doc = acad_app.Documents.Open(abspath, True) # True for ReadOnly
                        extmin = doc.GetVariable("EXTMIN")
                        extmax = doc.GetVariable("EXTMAX")
                        
                        dx = abs(extmax[0] - extmin[0])
                        dy = abs(extmax[1] - extmin[1])
                        
                        largo_cad = max(dx, dy)
                        ancho_cad = min(dx, dy)
                        observacion = "OK (AutoCAD EXTENTS)"
                    except Exception as acad_err:
                        print(f"Error procesando {codigo} con AutoCAD: {acad_err}")
                        observacion = "No extraido (Error AutoCAD COM)"
                    finally:
                        try:
                            doc.Close(False)
                        except: pass
                        
                elif ext == ".dwg" and not acad_app:
                    observacion = "Requiere AutoCAD Instalado"
                    print(f"âš ï¸ DWG omitido: Sin conexiÃ³n a AutoCAD COM -> {abspath}")

                elif ext == ".sldprt":
                    # COM bloqueante: un hilo dedicado por pieza + join(timeout). No se puede
                    # interrumpir la llamada COM en curso; al vencer el plazo se mata SLDWORKS.exe
                    # y se reaplica resurrección COM (mismo patrón que crash RPC).
                    if not has_sldprt:
                        observacion = "Sin archivos .sldprt en el escaneo."
                    else:
                        ruta_abs = os.path.abspath(abspath)
                        piece_box = {}
                        _dxf_p_audit = _resolve_dxf_path_for_codigo(
                            root_path, codigo, info["codigo"]
                        )
                        _dl_cmp: Optional[float] = None
                        _da_cmp: Optional[float] = None
                        if _dxf_p_audit:
                            _bb_aud = _dxf_bbox_largo_ancho_mm(_dxf_p_audit)
                            if _bb_aud:
                                _dl_cmp, _da_cmp = float(_bb_aud[0]), float(_bb_aud[1])

                        def _sldprt_worker():
                            try:
                                pythoncom.CoInitialize()
                            except Exception:
                                pass
                            try:
                                sw_local = get_sw_app()
                                if not sw_local:
                                    piece_box["out"] = {
                                        "codigo": codigo,
                                        "largo_cad": 0.0,
                                        "ancho_cad": 0.0,
                                        "espesor_cad": 0.0,
                                        "observacion": _ascii_report_text(
                                            "Motor SolidWorks inaccesible"
                                        ),
                                        "rpc_continue": False,
                                        "largo_dxf_nuevo": None,
                                        "ancho_dxf_nuevo": None,
                                    }
                                    return
                                piece_box["out"] = _sldprt_extract_one(
                                    sw_local,
                                    abspath,
                                    codigo,
                                    nombre_archivo,
                                    ruta_abs,
                                    resurrect_fn=_resurrect_solidworks_com_after_kill,
                                    dxf_largo_cmp=_dl_cmp,
                                    dxf_ancho_cmp=_da_cmp,
                                )
                            except Exception as e:
                                piece_box["exc"] = e
                            finally:
                                try:
                                    pythoncom.CoUninitialize()
                                except Exception:
                                    pass

                        th = threading.Thread(target=_sldprt_worker, daemon=True)
                        th.start()
                        th.join(SW_PIECE_TIMEOUT_SEC)
                        if th.is_alive():
                            scan_status["warning_message"] = (
                                "⚠️ Tiempo de espera excedido. Saltando pieza..."
                            )
                            sw_app = _resurrect_solidworks_com_after_kill()
                            largo_cad = 0.0
                            ancho_cad = 0.0
                            espesor_cad = 0.0
                            observacion = (
                                "ERROR TIMEOUT: La pieza tardo demasiado o se atasco en SolidWorks."
                            )
                        else:
                            if piece_box.get("exc"):
                                raise piece_box["exc"]
                            out = piece_box.get("out") or {}
                            if out.get("rpc_continue"):
                                codigo = out.get("codigo", codigo)
                                continue
                            codigo = out.get("codigo", codigo)
                            largo_cad = out.get("largo_cad", 0.0)
                            ancho_cad = out.get("ancho_cad", 0.0)
                            espesor_cad = out.get("espesor_cad", 0.0)
                            observacion = out.get("observacion", "")
                            largo_dxf_nuevo = out.get("largo_dxf_nuevo")
                            ancho_dxf_nuevo = out.get("ancho_dxf_nuevo")

            except Exception as extract_err:
                import traceback
                if not observacion:
                    observacion = f"Error: {str(extract_err)[:50]}"
                print(f"âŒ Error leyendo {abspath}: {str(extract_err)}")
                traceback.print_exc()

            # LÃ³gica de DXF (AuditorÃ­a Cruzada 2D): primero Piezas.../dxf, luego BIBLIOTECA_DXF
            dxf_path = ""
            for stem_try in (
                _normalize_chapa_stem(codigo),
                _normalize_chapa_stem(info["codigo"]),
                codigo,
                info["codigo"],
            ):
                if not stem_try:
                    continue
                for _sub in ("dxf", "BIBLIOTECA_DXF"):
                    _p = os.path.join(root_path, _sub, f"{stem_try}.dxf")
                    if os.path.exists(_p):
                        dxf_path = _p
                        break
                if dxf_path:
                    break

            if dxf_path and os.path.exists(dxf_path):
                tiene_dxf = "SI"
                try:
                    import ezdxf
                    from ezdxf import bbox
                    dxf_doc = ezdxf.readfile(dxf_path)
                    msp = dxf_doc.modelspace()
                    extents = bbox.extents(msp)
                    if extents.has_data:
                        dx = extents.extmax.x - extents.extmin.x
                        dy = extents.extmax.y - extents.extmin.y
                        lx = max(dx, dy)
                        ax = min(dx, dy)
                        largo_dxf = float(lx)
                        ancho_dxf = float(ax)
                except Exception as dxf_err:
                    print(f"Error parseando DXF {dxf_path}: {dxf_err}")

            data.append({
                "Codigo_Pieza": _ascii_report_text(codigo),
                "Extension": _ascii_report_text(ext),
                "Largo_CAD": 0 if (observacion or "").startswith("ERROR") else (float(largo_cad) if largo_cad > 0 else ""),
                "Ancho_CAD": 0 if (observacion or "").startswith("ERROR") else (float(ancho_cad) if ancho_cad > 0 else ""),
                "Espesor_Perfil_CAD": float(espesor_cad) if espesor_cad > 0 else "",
                "Material": "",
                "Observaciones": _ascii_report_text(observacion) if observacion else _ascii_report_text("No detectado"),
                "Tiene_DXF": _sanitize_excel_si_no(tiene_dxf, default="NO"),
                "Largo_DXF": largo_dxf,
                "Ancho_DXF": ancho_dxf,
                "Largo_DXF_Nuevo": largo_dxf_nuevo,
                "Ancho_DXF_Nuevo": ancho_dxf_nuevo,
                "Ruta_Archivo": _ascii_report_text(abspath),
            })
            extraidos += 1
            scan_status["progress"] = extraidos
            # â”€â”€ Throttle COM â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
            # Evita saturar la interfaz COM de SolidWorks entre iteraciones.
            _time.sleep(0.2)
            
        print("=== EXTRACCIÃ“N CAD FINALIZADA ===")
        if len(data) > 0:
            df = pd.DataFrame(data)
            df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Largo_DXF_Nuevo", "Ancho_DXF_Nuevo", "Ruta_Archivo"]]

            reports_dir = os.path.join(os.getcwd(), "reportes")
            os.makedirs(reports_dir, exist_ok=True)
            report_filename = f"Reporte_CAD.xlsx"
            report_path = os.path.join(reports_dir, report_filename)

            _export_reporte_cad(df, report_path)
            scan_status["excel_path"] = report_path

        if scan_status["status"] != "cancelled":
            scan_status["status"] = "completed"
        
    except Exception as e:
        scan_status["status"] = "error"
        scan_status["error"] = str(e)
    finally:
        try:
            if sw_app:
                try:
                    sw_app.ExitApp()
                except Exception:
                    pass
            if acad_app:
                try:
                    acad_app.Quit()
                except Exception:
                    pass
        except Exception:
            pass

        # â”€â”€ Liberar apartamento COM del hilo â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        try:
            import pythoncom
            pythoncom.CoUninitialize()
        except Exception:
            pass

        # Blindaje: exportar SIEMPRE al salir, incluso por cancelaciÃ³n dentro del bucle.
        # Solo crear Excel si hay al menos una pieza procesada.
        if len(data) > 0 and not scan_status.get("excel_path"):
            try:
                df = pd.DataFrame(data)
                df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Largo_DXF_Nuevo", "Ancho_DXF_Nuevo", "Ruta_Archivo"]]
                reports_dir = os.path.join(os.getcwd(), "reportes")
                os.makedirs(reports_dir, exist_ok=True)
                report_filename = "Reporte_CAD.xlsx"
                report_path = os.path.join(reports_dir, report_filename)
                _export_reporte_cad(df, report_path)
                scan_status["excel_path"] = report_path
            except Exception as export_err:
                if scan_status.get("status") != "error":
                    scan_status["status"] = "error"
                    scan_status["error"] = f"Error exportando Excel parcial: {export_err}"


@router.post("/api/cad/scan")
def start_cad_scan(payload: ScanCADPayload, background_tasks: BackgroundTasks):
    global scan_status, abortar_escaneo_cad
    
    abortar_escaneo_cad = False
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    if os.path.exists(flag_path):
        try: os.remove(flag_path)
        except: pass
    
    if payload.root_path == "cancel":
        scan_status["status"] = "cancelled"
        abortar_escaneo_cad = True
        return {"message": "Cancelado"}

    if scan_status["status"] == "scanning":
         return {"message": "Ya hay un escaneo en curso"}
         
    background_tasks.add_task(
        bg_scan_cad_task, payload.root_path, payload.solo_faltantes
    )
    return {"message": "Escaneo iniciado en segundo plano"}


# ═══════════════════════════════════════════════════════════════════════════════
# PIPELINE MAESTRO "TODO EN UNO"  (Paso 0 Recolección + Paso 2 DXF + Paso 3 CAD)
# ═══════════════════════════════════════════════════════════════════════════════

class MaestroCADPayload(BaseModel):
    """Payload para el endpoint /api/cad/maestro."""
    source_folder: str          # Carpeta de red / origen (Paso 0)
    solo_faltantes: bool = False
    inyectar_propiedades: bool = False

try:
    from pydantic import BaseModel
except ImportError:
    pass  # ya importado vía models.*


def bg_maestro_task(
    source_folder: str,
    solo_faltantes: bool = False,
    inyectar_propiedades: bool = False,
) -> None:
    """Pipeline maestro asíncrono:
    Paso 0 – Copia archivos CAD desde la red hacia ~/Desktop/Piezas_A_Procesar/ (local).
    Paso 2 – Convierte DWG → DXF vía convertir_dwg.py.
    Paso 3 – Extrae metadata CAD con SolidWorks y genera Excel.

    Regla de Oro: el bloque finally SIEMPRE exporta el Excel acumulado hasta
    ese momento, incluso ante cancelación manual o crash crítico.
    """
    import datetime as _dt
    import time as _time

    global scan_status, abortar_escaneo_cad, cad_execution_logs, cad_procesar_status

    # ── Estado inicial ────────────────────────────────────────────────────────
    cad_execution_logs.clear()
    _cad_telemetry_clear()
    cad_procesar_status = "processing"
    scan_status["status"] = "scanning"
    scan_status["progress"] = 0
    scan_status["total"] = 0
    scan_status["excel_path"] = ""
    scan_status["error"] = ""
    scan_status["warning_message"] = ""
    scan_status["current_file"] = ""
    scan_status["current_item"] = 0
    scan_status["total_items"] = 0

    def _log(msg: str) -> None:
        ts = _dt.datetime.now().strftime("%H:%M:%S")
        entry = f"[{ts}] {msg}"
        print(entry)
        cad_execution_logs.append(entry)
        scan_status["current_file"] = msg[:120]

    # ── Carpeta local de trabajo (escritorio) + subcarpeta dxf (DXF solo local) ─
    local_work_dir = _piezas_a_procesar_desktop_dir()
    os.makedirs(local_work_dir, exist_ok=True)
    dxf_local_dir = os.path.join(local_work_dir, "dxf")
    os.makedirs(dxf_local_dir, exist_ok=True)
    _log(f"📁 Carpeta de trabajo local: {local_work_dir}")
    _log(f"📁 DXF (Paso 2): {dxf_local_dir}")

    # Variables de datos acumulados (para el finally)
    data_acumulada: list = []

    _EXCLUDED_DIRS_MAESTRO = {
        "dxf_convertidos", "exportados", "biblioteca_dxf",
        "cad_pendientes", "reportes", "__pycache__", ".git",
        "node_modules", "venv", ".venv", "dist", "build",
        "piezas_a_procesar",  # evitar bucle en la carpeta local
    }

    try:
        pythoncom.CoInitialize()
    except Exception:
        pass

    try:
        # ════════════════════════════════════════════════════════════════
        # PASO 0 – Recolección desde red → local
        # ════════════════════════════════════════════════════════════════
        _log("🔎 PASO 0: Consultando BD para obtener lista de piezas a procesar (sin comerciales)...")

        piezas_objetivo: set = set()
        try:
            conn_step0 = get_db_connection()
            cur_step0 = conn_step0.cursor()
            if solo_faltantes:
                cur_step0.execute(f"""
                    SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas
                    WHERE (
                        Largo_CAD IS NULL
                        OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) IN ('', '-', '0')
                        OR (TRY_CAST(Largo_CAD AS FLOAT) IS NOT NULL
                            AND TRY_CAST(Largo_CAD AS FLOAT) = 0)
                    )
                    {_SQL_EXCLUIR_COMERCIALES}
                """)
            else:
                cur_step0.execute(f"""
                    SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas
                    WHERE 1=1
                    {_SQL_EXCLUIR_COMERCIALES}
                """)
            for r in cur_step0.fetchall():
                if r and r[0]:
                    piezas_objetivo.add(str(r[0]).strip().upper())
            cur_step0.close()
            conn_step0.close()
            _log(f"   → {len(piezas_objetivo)} piezas objetivo ({'solo faltantes' if solo_faltantes else 'catálogo completo'}).")
        except Exception as ex_q:
            _log(f"⚠️ Error consultando BD en Paso 0: {ex_q}. Se procesará todo lo encontrado.")

        # Copiar archivos desde la red
        _log(f"📡 Buscando archivos CAD en la red: {source_folder}")
        scan_status["status"] = "collecting"
        scan_status["current_file"] = "Paso 0: Copiando archivos desde la red..."

        copiados = 0
        omitidos = 0
        cad_candidatos: list = []
        network_by_local_basename: Dict[str, str] = {}
        for root_dir, dirs, files in os.walk(source_folder):
            dirs[:] = [
                d for d in dirs
                if d.lower() not in _EXCLUDED_DIRS_MAESTRO
                and not d.startswith('.')
                and "obsoleto" not in d.lower()
            ]
            for f in files:
                if abortar_escaneo_cad:
                    break
                if f.startswith("~$") or "obsoleto" in f.lower():
                    continue
                ext_up = f.rsplit('.', 1)[-1].upper() if '.' in f else ''
                if ext_up in ('SLDPRT', 'DWG', 'DXF'):
                    full = os.path.join(root_dir, f)
                    if not _cad_path_has_obsoleto(full):
                        cad_candidatos.append(full)
            if abortar_escaneo_cad:
                break

        cad_candidatos = _dedupe_paths_by_basename_newest(cad_candidatos)
        total_red = len(cad_candidatos)
        scan_status["total_items"] = total_red
        scan_status["total"] = total_red
        _log(f"   → {total_red} archivos CAD únicos encontrados en la red.")

        for idx, full_path in enumerate(cad_candidatos, start=1):
            if abortar_escaneo_cad:
                _log("🛑 Recolección cancelada por el usuario.")
                break
            base_name_raw = os.path.splitext(os.path.basename(full_path))[0]
            base_norm = _normalize_chapa_stem(base_name_raw).strip().upper()
            scan_status["current_item"] = idx
            scan_status["progress"] = idx

            # Si tenemos lista de objetivos, filtrar
            if piezas_objetivo and base_norm not in piezas_objetivo:
                omitidos += 1
                continue

            dest = os.path.join(local_work_dir, os.path.basename(full_path))
            network_by_local_basename[os.path.basename(full_path).upper()] = full_path
            if not os.path.exists(dest):
                try:
                    shutil.copy2(full_path, dest)
                    copiados += 1
                    if idx % 20 == 0:
                        _log(f"   Copiados {copiados} archivos... ({idx}/{total_red})")
                except OSError as cp_err:
                    _log(f"⚠️ No se pudo copiar {os.path.basename(full_path)}: {cp_err}")
            else:
                copiados += 1  # ya estaba; cuenta como disponible

        _log(f"✅ PASO 0 completado: {copiados} archivos disponibles en carpeta local.")
        if inyectar_propiedades:
            _log("📌 Inyección de propiedades activada: tras medir, se guardará .sldprt local y se copiará a la red.")

        if abortar_escaneo_cad:
            scan_status["status"] = "cancelled"
            _log("🛑 Pipeline cancelado tras Paso 0.")
            return

        _log("📐 Búsqueda universal 2D en red → dxf/{CODIGO}.dxf (DWG/DXF, con/sin 'Chapa desplegada - ')...")
        try:
            _materialize_universal_2d_for_pipeline(
                source_folder, local_work_dir, dxf_local_dir, piezas_objetivo,
            )
        except Exception as ex_2d:
            _log(f"⚠️ Materialización 2D universal: {ex_2d}")

        # ════════════════════════════════════════════════════════════════
        # PASO 2 – Conversión DWG → DXF (usa convertir_dwg.py)
        # ════════════════════════════════════════════════════════════════
        _log("🔄 PASO 2: Convirtiendo archivos DWG a DXF...")
        scan_status["status"] = "scanning"
        scan_status["current_file"] = "Paso 2: Convirtiendo DWG → DXF..."
        cad_procesar_status = "processing"

        script_dwg = os.path.join(_BACKEND_ROOT, "tools", "convertir_dwg.py")
        if not os.path.exists(script_dwg):
            _log(f"⚠️ Script DWG no encontrado en {script_dwg}. Paso 2 omitido.")
        else:
            try:
                cmd_dwg = [sys.executable, script_dwg, local_work_dir]
                if solo_faltantes:
                    cmd_dwg.append("--solo-faltantes")
                proc_dwg = subprocess.Popen(
                    cmd_dwg,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="cp1252", errors="replace",
                )
                for line in iter(proc_dwg.stdout.readline, ''):
                    if abortar_escaneo_cad:
                        proc_dwg.terminate()
                        break
                    stripped = line.strip()
                    if stripped:
                        _log(f"  [DWG] {stripped}")
                proc_dwg.stdout.close()
                proc_dwg.wait()
                _log(f"   → convertir_dwg.py terminó (código {proc_dwg.returncode}).")
            except Exception as dwg_err:
                _log(f"⚠️ Error en conversión DWG: {dwg_err}")

        if abortar_escaneo_cad:
            scan_status["status"] = "cancelled"
            _log("🛑 Pipeline cancelado tras Paso 2.")
            return

        # ════════════════════════════════════════════════════════════════
        # PASO 3 – Extracción CAD (SolidWorks COM) desde carpeta local
        # ════════════════════════════════════════════════════════════════
        _log("🛠 PASO 3: Iniciando extracción CAD desde carpeta local...")
        scan_status["current_file"] = "Paso 3: Extrayendo metadata CAD..."

        # Reutilizamos la función existente apuntando a la carpeta local.
        # Llama a bg_scan_cad_task con la carpeta local; data acumulada queda
        # en scan_status y el finally de bg_scan_cad_task genera el Excel.
        # Para tener control del finally aquí, ejecutamos inlined.

        # ──── Setup COM ────
        def _apply_silent_mode_m(app):
            for pref, val in [(11, True), (262, True)]:
                try: app.SetUserPreferenceToggle(pref, val)
                except Exception: pass
            try:
                app.Visible = True
            except Exception:
                pass
            try:
                app.UserControl = True
            except Exception:
                pass

        def get_sw_app_m():
            try:
                import win32com.client as _wc
                app = _wc.DispatchEx("SldWorks.Application")
                _apply_silent_mode_m(app)
                _log("[SW] Instancia COM (DispatchEx) lista.")
                return app
            except Exception as e:
                _log(f"⚠️ SolidWorks COM no disponible: {e}")
                return None

        def _resurrect_m():
            try: os.system("taskkill /F /IM SLDWORKS.exe /T 2>nul")
            except Exception: pass
            _time.sleep(3)
            try: pythoncom.CoUninitialize()
            except Exception: pass
            try: pythoncom.CoInitialize()
            except Exception: pass
            return get_sw_app_m()

        # Escaneo de archivos en carpeta local
        import ezdxf
        from ezdxf import bbox as _bbox
        import win32com.client as _win32

        cad_files_local: dict = {}
        for _dp, _ds, _fs in os.walk(local_work_dir):
            _ds[:] = [
                d for d in _ds
                if d.lower() not in _EXCLUDED_DIRS_MAESTRO and d.lower() != "dxf"
            ]
            for _f in _fs:
                _ext = os.path.splitext(_f)[1].lower()
                if _ext != ".sldprt":
                    continue
                _ap = os.path.join(_dp, _f)
                _cod_norm = _normalize_chapa_stem(os.path.splitext(_f)[0])
                _key = _cod_norm.lower()
                try:
                    _mt = os.path.getmtime(_ap)
                except OSError:
                    continue
                prev = cad_files_local.get(_key)
                if prev is None or _mt > prev["mtime"]:
                    cad_files_local[_key] = {
                        "mtime": _mt,
                        "abspath": _ap,
                        "ext": _ext,
                        "codigo": _cod_norm,
                    }

        lista_local = list(cad_files_local.values())
        total_local = len(lista_local)
        scan_status["total"] = total_local
        scan_status["total_items"] = total_local
        scan_status["current_item"] = 0
        _log(f"   → {total_local} archivos únicos en carpeta local para procesar.")

        sw_app_m = None
        extraidos_m = 0

        for i_m, info_m in enumerate(lista_local):
            if abortar_escaneo_cad:
                _log("🛑 Extracción CAD cancelada por usuario.")
                break

            nombre_m = os.path.basename(info_m["abspath"])
            msg_m = f"Pieza {i_m + 1}/{total_local}: {nombre_m}"
            scan_status["current_file"] = msg_m
            scan_status["current_item"] = i_m + 1
            scan_status["progress"] = i_m + 1
            _log(f"⚙ {msg_m}")

            ext_m = info_m["ext"]
            abspath_m = info_m["abspath"]
            codigo_m = info_m["codigo"]
            largo_m = 0.0; ancho_m = 0.0; espesor_m = 0.0
            observacion_m = ""
            tiene_dxf_m = "NO"
            largo_dxf_m = ""; ancho_dxf_m = ""
            largo_dxf_nuevo_m = None; ancho_dxf_nuevo_m = None

            try:
                # Paso 3: solo .sldprt entran a esta lista; motor 3D no trata DWG/DXF.
                if ext_m == ".sldprt":
                    ruta_abs_m = os.path.abspath(abspath_m)
                    bn_upper = os.path.basename(abspath_m).upper()
                    ruta_red_m = network_by_local_basename.get(bn_upper)
                    piece_box_m: dict = {}
                    _dxf_pre_m = os.path.join(
                        local_work_dir, "dxf", f"{_normalize_chapa_stem(str(codigo_m))}.dxf"
                    )
                    _dl_m: Optional[float] = None
                    _da_m: Optional[float] = None
                    if os.path.exists(_dxf_pre_m):
                        _bb_m = _dxf_bbox_largo_ancho_mm(_dxf_pre_m)
                        if _bb_m:
                            _dl_m, _da_m = float(_bb_m[0]), float(_bb_m[1])

                    def _worker_m():
                        try: pythoncom.CoInitialize()
                        except Exception: pass
                        try:
                            sw_l = get_sw_app_m()
                            if not sw_l:
                                piece_box_m["out"] = {"rpc_continue": False, "codigo": codigo_m,
                                                      "largo_cad": 0.0, "ancho_cad": 0.0, "espesor_cad": 0.0,
                                                      "observacion": _ascii_report_text("Motor SW inaccesible")}
                                return
                            piece_box_m["out"] = _sldprt_extract_one(
                                sw_l, abspath_m, codigo_m, nombre_m, ruta_abs_m,
                                resurrect_fn=_resurrect_m,
                                inyectar_propiedades=inyectar_propiedades,
                                ruta_original_red=ruta_red_m,
                                dxf_largo_cmp=_dl_m,
                                dxf_ancho_cmp=_da_m,
                            )
                        except Exception as e_w:
                            piece_box_m["exc"] = e_w
                        finally:
                            try: pythoncom.CoUninitialize()
                            except Exception: pass

                    th_m = threading.Thread(target=_worker_m, daemon=True)
                    th_m.start()
                    th_m.join(SW_PIECE_TIMEOUT_SEC)

                    if th_m.is_alive():
                        _log(f"  ⏱ TIMEOUT en {nombre_m}. Matando SLDWORKS.exe...")
                        scan_status["warning_message"] = f"⚠️ Timeout: {nombre_m}"
                        sw_app_m = _resurrect_m()
                        observacion_m = "ERROR TIMEOUT: Pieza bloqueó SolidWorks. Saltada."
                    else:
                        if piece_box_m.get("exc"):
                            raise piece_box_m["exc"]
                        out_m = piece_box_m.get("out") or {}
                        if out_m.get("rpc_continue"):
                            observacion_m = out_m.get("observacion", "ERROR RPC")
                            _log(f"  ⚠️ RPC crash en {nombre_m}: {observacion_m}")
                        else:
                            codigo_m = out_m.get("codigo", codigo_m)
                            largo_m = out_m.get("largo_cad", 0.0)
                            ancho_m = out_m.get("ancho_cad", 0.0)
                            espesor_m = out_m.get("espesor_cad", 0.0)
                            largo_dxf_nuevo_m = out_m.get("largo_dxf_nuevo")
                            ancho_dxf_nuevo_m = out_m.get("ancho_dxf_nuevo")
                            observacion_m = out_m.get("observacion", "")
                            if str(observacion_m).startswith("OK"):
                                _log(f"  ✅ {codigo_m}: L={largo_m:.1f} A={ancho_m:.1f} E={espesor_m:.1f}")

            except Exception as ex_m_piece:
                if not observacion_m:
                    observacion_m = f"Error: {str(ex_m_piece)[:60]}"
                _log(f"  ❌ Error procesando {nombre_m}: {ex_m_piece}")

            # Auditoría DXF cruzada (generados en local_work_dir/dxf/, no en red)
            dxf_check = os.path.join(
                local_work_dir, "dxf", f"{_normalize_chapa_stem(str(codigo_m))}.dxf"
            )
            if os.path.exists(dxf_check):
                tiene_dxf_m = "SI"
                try:
                    _d = ezdxf.readfile(dxf_check)
                    _ext_dxf = _bbox.extents(_d.modelspace())
                    if _ext_dxf.has_data:
                        _dx = _ext_dxf.extmax.x - _ext_dxf.extmin.x
                        _dy = _ext_dxf.extmax.y - _ext_dxf.extmin.y
                        largo_dxf_m = float(max(_dx, _dy))
                        ancho_dxf_m = float(min(_dx, _dy))
                except Exception: pass

            data_acumulada.append({
                "Codigo_Pieza": _ascii_report_text(codigo_m),
                "Extension": _ascii_report_text(ext_m),
                "Largo_CAD": 0 if (observacion_m or "").startswith("ERROR") else (float(largo_m) if largo_m > 0 else ""),
                "Ancho_CAD": 0 if (observacion_m or "").startswith("ERROR") else (float(ancho_m) if ancho_m > 0 else ""),
                "Espesor_Perfil_CAD": float(espesor_m) if espesor_m > 0 else "",
                "Material": "",
                "Observaciones": _ascii_report_text(observacion_m) or "No detectado",
                "Tiene_DXF": _sanitize_excel_si_no(tiene_dxf_m, default="NO"),
                "Largo_DXF": largo_dxf_m,
                "Ancho_DXF": ancho_dxf_m,
                "Largo_DXF_Nuevo": largo_dxf_nuevo_m,
                "Ancho_DXF_Nuevo": ancho_dxf_nuevo_m,
                "Ruta_Archivo": _ascii_report_text(abspath_m),
            })
            extraidos_m += 1
            _time.sleep(0.15)  # throttle COM

        _log(f"✅ PASO 3 completado: {extraidos_m} piezas procesadas.")
        scan_status["status"] = "completed"
        cad_procesar_status = "completed"

    except Exception as pipeline_err:
        _log(f"❌ Error crítico en pipeline maestro: {pipeline_err}")
        scan_status["status"] = "error"
        scan_status["error"] = str(pipeline_err)
        cad_procesar_status = "completed"

    finally:
        # ── REGLA DE ORO: exportar Excel SIN FALTA ─────────────────────────
        _log(f"💾 Exportando Excel parcial/final con {len(data_acumulada)} registros...")
        if len(data_acumulada) > 0:
            try:
                df_m = pd.DataFrame(data_acumulada)
                df_m = df_m[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD",
                              "Espesor_Perfil_CAD", "Material", "Observaciones",
                              "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Largo_DXF_Nuevo", "Ancho_DXF_Nuevo", "Ruta_Archivo"]]
                reports_dir = os.path.join(os.getcwd(), "reportes")
                os.makedirs(reports_dir, exist_ok=True)
                report_path = os.path.join(reports_dir, "Reporte_CAD.xlsx")
                _export_reporte_cad(df_m, report_path)
                scan_status["excel_path"] = report_path
                _log(f"✅ Excel guardado: {report_path}")
            except Exception as ex_export:
                _log(f"❌ Error exportando Excel en finally: {ex_export}")
                scan_status["error"] = f"Error exportando Excel: {ex_export}"
        else:
            _log("⚠️ No hay datos acumulados. Excel no generado.")

        # ── Liberar SW si quedó abierto ───────────────────────────────────
        try:
            os.system("taskkill /F /IM SLDWORKS.exe /T 2>nul")
        except Exception:
            pass
        try:
            pythoncom.CoUninitialize()
        except Exception:
            pass


@router.post("/api/cad/maestro")
def start_maestro_cad(payload: MaestroCADPayload, background_tasks: BackgroundTasks):
    """Arranca el pipeline Todo en Uno (Recolección + DWG→DXF + Extracción CAD)."""
    global scan_status, abortar_escaneo_cad, cad_execution_logs, cad_procesar_status

    busy_states = {"scanning", "collecting", "generating_excel"}
    if scan_status["status"] in busy_states or cad_procesar_status == "processing":
        return {"message": "Ya hay un proceso en curso. Cancélalo primero."}

    abortar_escaneo_cad = False
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    if os.path.exists(flag_path):
        try: os.remove(flag_path)
        except: pass

    cad_execution_logs.clear()
    cad_procesar_status = "idle"

    background_tasks.add_task(
        bg_maestro_task,
        payload.source_folder,
        payload.solo_faltantes,
        payload.inyectar_propiedades,
    )
    return {"message": "Pipeline Maestro iniciado en segundo plano"}

import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

cad_execution_logs = []
cad_procesar_status = "idle"

def bg_procesar_cad_task(ruta_raiz: str, solo_faltantes: bool = False):
    global cad_execution_logs, cad_procesar_status
    cad_execution_logs.clear()
    cad_procesar_status = "processing"
    
    def log_and_append(msg: str):
        logging.info(msg)
        cad_execution_logs.append(msg)
        
    log_and_append(f"Iniciando procesamiento CAD masivo en: {ruta_raiz}")
    base_dir = _BACKEND_ROOT
    script_dwg = os.path.join(base_dir, "tools", "convertir_dwg.py")
    script_sw = os.path.join(base_dir, "tools", "preparar_solidworks.py")
    
    if not os.path.exists(script_dwg):
        log_and_append(f"Error: No se encontrÃ³ el script DWG en la ruta absoluta: {script_dwg}")
    else:
        try:
            log_and_append("Ejecutando convertir_dwg.py...")
            cmd_dwg = [sys.executable, script_dwg, ruta_raiz]
            if solo_faltantes:
                cmd_dwg.append("--solo-faltantes")
            process = subprocess.Popen(
                cmd_dwg,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='cp1252',
                errors='replace'
            )
            for line in iter(process.stdout.readline, ''):
                if line:
                    log_and_append(line.strip())
            process.stdout.close()
            process.wait()
            log_and_append(f"convertir_dwg.py terminÃ³ (cÃ³digo {process.returncode})")
        except Exception as e:
            log_and_append(f"Error al ejecutar convertir_dwg.py: {e}")
            
    if not os.path.exists(script_sw):
        log_and_append(f"Error: No se encontrÃ³ el script SolidWorks en la ruta absoluta: {script_sw}")
    else:
        try:
            log_and_append("Ejecutando preparar_solidworks.py...")
            process = subprocess.Popen(
                [sys.executable, script_sw, ruta_raiz],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='cp1252',
                errors='replace'
            )
            for line in iter(process.stdout.readline, ''):
                if line:
                    log_and_append(line.strip())
            process.stdout.close()
            process.wait()
            log_and_append(f"preparar_solidworks.py terminÃ³ (cÃ³digo {process.returncode})")
        except Exception as e:
            log_and_append(f"Error al ejecutar preparar_solidworks.py: {e}")
            
    log_and_append("Procesamiento CAD completado")
    cad_procesar_status = "completed"

@router.post("/api/cad/procesar-directorio")
def procesar_directorio_cad(payload: ScanCADPayload, background_tasks: BackgroundTasks):
    global abortar_escaneo_cad
    abortar_escaneo_cad = False
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    if os.path.exists(flag_path):
        try: os.remove(flag_path)
        except: pass
    
    background_tasks.add_task(bg_procesar_cad_task, payload.root_path, payload.solo_faltantes)
    return {
        "success": True, 
        "message": f"Procesamiento CAD iniciado en segundo plano para: {payload.root_path}"
    }


@router.get("/api/cad/status")
def get_cad_status():
    global scan_status, cad_procesar_status, cad_execution_logs
    status_response = scan_status.copy() if scan_status else {}
    status_response["procesar_status"] = cad_procesar_status
    status_response["logs"] = cad_execution_logs
    # current_file ya viaja dentro de scan_status.copy() como campo nativo
    return status_response

@router.get("/api/cad/open-folder")
def open_cad_folder():
    try:
        carpeta = _piezas_a_procesar_desktop_dir()
        os.makedirs(carpeta, exist_ok=True)
        os.makedirs(os.path.join(carpeta, "dxf"), exist_ok=True)
        if sys.platform != "win32":
            raise OSError("Abrir carpeta solo está soportado en Windows.")
        os.startfile(carpeta)
        return {"status": "ok", "message": "Carpeta abierta"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/api/cad/download")
def download_cad_report():
    global scan_status
    excel_path = scan_status.get("excel_path", "")
    if not excel_path or not os.path.exists(excel_path):
        raise HTTPException(status_code=404, detail="Archivo Excel no encontrado.")
    return FileResponse(excel_path, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", filename="Reporte_CAD.xlsx")

@router.post("/api/cad/upload")
async def upload_cad_modifications(
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    if not file.filename.endswith('.xlsx'):
         raise HTTPException(status_code=400, detail="Formato no admitido. Debe ser un archivo .xlsx")
         
    # â”€â”€ Helper de casteo seguro â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    def _safe_float(val) -> Optional[float]:
        """Celda Excel/Pandas → float nativo de Python o None (sin numpy.float64 para pyodbc).

        NaN / pd.NA / nulos → None. No redondea (precisión MRPII).
        """
        if val is None:
            return None
        try:
            import pandas as pd
            if pd.isna(val):
                return None
        except Exception:
            pass
        try:
            from decimal import Decimal
            if isinstance(val, Decimal):
                return float(val)
        except Exception:
            pass
        try:
            import numpy as np
            if isinstance(val, (np.floating, np.integer)):
                x = float(val.item()) if hasattr(val, "item") else float(val)
                if math.isnan(x):
                    return None
                return float(x)
        except Exception:
            pass
        try:
            if isinstance(val, float) and math.isnan(val):
                return None
        except (TypeError, ValueError):
            pass
        s = str(val).strip().lower()
        if s in ('', 'nan', 'none', '-', 'n/a', '<na>'):
            return None
        s = str(val).strip().replace(',', '.')
        import re as _re
        s = _re.sub(r'[^\d.\-]', '', s)
        if not s or s == '.':
            return None
        try:
            return float(s)
        except ValueError:
            return None

    def _sql_param_float(v: Optional[float]) -> Optional[float]:
        """pyodbc + SQL Server: asegura float nativo (evita numpy.float64 en parámetros)."""
        if v is None:
            return None
        return float(v)

    try:
        contents = await file.read()
        df = pd.read_excel(io.BytesIO(contents))

        # â”€â”€ Limpieza global del DataFrame â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        # Normalizar nombres de columnas (quitar espacios accidentales)
        df.columns = [str(c).strip() for c in df.columns]

        # Columnas solo informativas en Excel (no existen en BD / no deben romper UPDATE)
        for _col_ignore in ("Largo_DXF", "Ancho_DXF"):
            if _col_ignore in df.columns:
                df = df.drop(columns=[_col_ignore])

        # Validar que tenga las columnas requeridas
        required_cols = ["Codigo_Pieza", "Largo_CAD", "Ancho_CAD"]
        for col in required_cols:
            if col not in df.columns:
                print(f"ERROR: Falta columna {col}")
                raise HTTPException(status_code=400, detail=f"Falta la columna requerida: {col}")
                
        actualizadas = 0
        ignoradas = 0
        no_encontradas = 0
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        print(f"=== INICIANDO LECTURA DE {len(df)} FILAS DEL EXCEL ===")
        
        try:
            for index, row in df.iterrows():
                # â”€â”€ CÃ³digo de pieza â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                raw_codigo = row.get("Codigo_Pieza", "")
                codigo = str(raw_codigo).strip() if raw_codigo not in (None, '') else ''
                if not codigo or codigo.lower() in ('nan', 'none'):
                    ignoradas += 1
                    continue

                # â”€â”€ Dimensiones CAD â€” casteo seguro a float|None â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                # CRÃTICO: str(NaN) â†’ 'nan' â†’ float('nan') pasa como valor
                # invÃ¡lido al SQL. _safe_float convierte eso a None explÃ­cito.
                largo_float   = _sql_param_float(_safe_float(row.get("Largo_CAD")))
                ancho_float   = _sql_param_float(_safe_float(row.get("Ancho_CAD")))
                espesor_float = _sql_param_float(_safe_float(row.get("Espesor_Perfil_CAD")))

                # â”€â”€ Material â€” garantizar nunca vacÃ­o en BD â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                # El reporte CAD genera Material='' porque SW no tiene ese campo.
                # Aplicamos la misma regla que en excel.py: "" â†’ "POR DEFINIR".
                raw_mat = row.get("Material", "")
                mat_clean = str(raw_mat).strip() if raw_mat not in (None, '') else ''
                if mat_clean.lower() in ('', 'nan', 'none', 'n/a'):
                    mat_clean = ''  # Dejar que la BD conserve lo que ya tiene
                    material_str: Optional[str] = None  # No sobreescribir
                else:
                    material_str = mat_clean

                # â”€â”€ Campos auxiliares â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                ruta_str       = str(row.get("Ruta_Archivo", "") or "").strip()
                tiene_dxf      = _sanitize_excel_si_no(row.get("Tiene_DXF"), default="NO")
                observaciones_str = str(row.get("Observaciones", "") or "").strip()

                print(
                    f"[upload_cad] {codigo} | "
                    f"L={largo_float} A={ancho_float} E={espesor_float} "
                    f"Mat={material_str!r} | Obs={observaciones_str!r}"
                )

                # Observaciones: solo log (columna no existe en Tbl_Maestro_Piezas / no va al SQL).
                # Si el Excel no trae Material válido NO sobreescribimos la BD,
                # para no borrar el dato que ya existe correctamente.
                if material_str is not None:
                    cursor.execute("""
                        UPDATE Tbl_Maestro_Piezas
                        SET Largo_CAD         = ?,
                            Ancho_CAD         = ?,
                            Espesor_Perfil_CAD = ?,
                            Material          = ?,
                            Ruta_Archivo      = ?,
                            Tiene_DXF         = ?
                        WHERE Codigo_Pieza = ?
                    """, (
                        largo_float, ancho_float, espesor_float,
                        material_str, ruta_str,
                        tiene_dxf,
                        codigo,
                    ))
                else:
                    # Material vacío en Excel → no tocar columna Material en BD
                    cursor.execute("""
                        UPDATE Tbl_Maestro_Piezas
                        SET Largo_CAD          = ?,
                            Ancho_CAD          = ?,
                            Espesor_Perfil_CAD  = ?,
                            Ruta_Archivo       = ?,
                            Tiene_DXF          = ?
                        WHERE Codigo_Pieza = ?
                    """, (
                        largo_float, ancho_float, espesor_float,
                        ruta_str, tiene_dxf,
                        codigo,
                    ))

                if cursor.rowcount > 0:
                    print(f"ACTUALIZADA: {codigo} (L:{largo_float}, A:{ancho_float})")
                    actualizadas += 1
                    actor = resolve_actor_user(authorization, x_usuario)
                    usr_log = (
                        actor
                        if actor != "Sistema"
                        else ((x_usuario or "").strip() or "SISTEMA_CAD")
                    )
                    registrar_log_global(
                        cursor,
                        codigo,
                        "UPDATE_MEDIDAS_CAD",
                        "",
                        f"L:{largo_float}, A:{ancho_float}",
                        usr_log,
                    )
                else:
                    print(f"NO ENCONTRADA: {codigo} - No existe la llave en DB")
                    no_encontradas += 1
                    
            conn.commit()
            print("=== ESCRITURA FINALIZADA CON EXITO ===")
            
        except Exception as inner_e:
            conn.rollback()
            raise inner_e
        finally:
            conn.close()
            
        return {
            "status": "success",
            "actualizadas": actualizadas,
            "ignoradas": ignoradas,
            "no_encontradas": no_encontradas
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/api/cad/collect-missing")
def collect_missing_cad(request: CollectRequest):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        if request.solo_faltantes:
            cursor.execute(
                f"""
                SELECT Codigo_Pieza
                FROM Tbl_Maestro_Piezas
                WHERE (
                    Ruta_Archivo IS NULL
                   OR LTRIM(RTRIM(CAST(Ruta_Archivo AS NVARCHAR(400)))) = ''
                   OR LTRIM(RTRIM(CAST(Ruta_Archivo AS NVARCHAR(400)))) = '-'
                )
                {_SQL_EXCLUIR_COMERCIALES}
                """
            )
            rows_sin_ruta = cursor.fetchall()
            piezas_sin_ruta = set()
            for row in rows_sin_ruta:
                if row[0]:
                    piezas_sin_ruta.add(str(row[0]).strip().upper())

            cursor.execute(f"""
                SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas
                WHERE 1=1 {_SQL_EXCLUIR_COMERCIALES}
            """)
            rows_cat = cursor.fetchall()
            catalogo_codigos = set()
            for row in rows_cat:
                if row[0]:
                    catalogo_codigos.add(str(row[0]).strip().upper())

            piezas_faltantes: set = set()
        else:
            query = f"""
                SELECT Codigo_Pieza 
                FROM Tbl_Maestro_Piezas 
                WHERE (
                    Largo_CAD IS NULL 
                   OR CAST(Largo_CAD AS VARCHAR) = '' 
                   OR CAST(Largo_CAD AS VARCHAR) = '-'
                   OR CAST(Largo_CAD AS VARCHAR) = '0'
                )
                {_SQL_EXCLUIR_COMERCIALES}
            """
            cursor.execute(query)
            rows = cursor.fetchall()
            piezas_faltantes = set()
            for row in rows:
                if row[0]:
                    piezas_faltantes.add(str(row[0]).strip().upper())
            piezas_sin_ruta = set()
            catalogo_codigos = set()

        cursor.close()
        conn.close()

        def _should_copy_collect(base_name: str) -> bool:
            if request.solo_faltantes:
                return base_name in piezas_sin_ruta or base_name not in catalogo_codigos
            return base_name in piezas_faltantes

        # 2. Preparar carpeta en el Escritorio
        desktop = os.path.join(os.environ['USERPROFILE'], 'Desktop')
        target_folder = os.path.join(desktop, 'CAD_PENDIENTES')
        if not os.path.exists(target_folder):
            os.makedirs(target_folder)

        # Carpetas generadas por el sistema â€” excluir para no copiar duplicados
        _EXCLUDED_DIRS = {
            "dxf_convertidos", "exportados", "biblioteca_dxf",
            "cad_pendientes", "reportes", "__pycache__", ".git",
            "node_modules", "venv", ".venv"
        }

        # Pre-escaneo: rutas candidatas (sin OBSOLETO), luego dedupe por nombre base = mÃ¡s reciente
        todos_los_cad: List[str] = []
        for root_dir, dirs, files in os.walk(request.source_folder):
            dirs[:] = [
                d for d in dirs
                if d.lower() not in _EXCLUDED_DIRS
                and not d.startswith('.')
                and "obsoleto" not in d.lower()
            ]
            for file in files:
                if file.startswith("~$") or "obsoleto" in file.lower():
                    continue
                ext = file.split('.')[-1].upper()
                if ext in ['SLDPRT', 'DWG', 'DXF']:
                    full = os.path.join(root_dir, file)
                    if _cad_path_has_obsoleto(full):
                        continue
                    todos_los_cad.append(full)

        todos_los_cad = _dedupe_paths_by_basename_newest(todos_los_cad)

        total_red = len(todos_los_cad)

        # Inicializar estado de progreso del colector
        scan_status["status"] = "collecting"
        scan_status["current_file"] = "Iniciando recolector..."
        scan_status["current_item"] = 0
        scan_status["total_items"] = total_red
        scan_status["progress"] = 0
        scan_status["total"] = total_red

        # 3. Recorrer la red y copiar
        archivos_copiados = 0
        for idx, full_path in enumerate(todos_los_cad, start=1):
            file = os.path.basename(full_path)
            ext = file.split('.')[-1].upper()
            base_name = _normalize_chapa_stem(file[: -(len(ext) + 1)].strip()).upper()

            # Actualizar progreso en tiempo real
            scan_status["current_file"] = f"Copiando {idx} de {total_red}: {file}"
            scan_status["current_item"] = idx
            scan_status["progress"] = idx

            if _should_copy_collect(base_name):
                target_path = os.path.join(target_folder, file)
                if not os.path.exists(target_path):
                    shutil.copy2(full_path, target_path)
                    archivos_copiados += 1

        scan_status["status"] = "idle"
        scan_status["current_file"] = ""

        piezas_reporte = len(piezas_sin_ruta) if request.solo_faltantes else len(piezas_faltantes)
        return {
            "piezas_faltantes_en_db": piezas_reporte,
            "archivos_encontrados": archivos_copiados,
            "destino": target_folder
        }

    except Exception as e:
        scan_status["status"] = "idle"
        raise HTTPException(status_code=500, detail=f"Error durante la recolección: {str(e)}")
