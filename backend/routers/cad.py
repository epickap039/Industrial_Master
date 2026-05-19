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
    AND (UPPER(LTRIM(RTRIM(ISNULL(CAST(Medida AS NVARCHAR(200)), '')))) <> 'COMERCIAL'
         OR Medida IS NULL)
"""

# SolidWorks swCustomInfoText — propiedades personalizadas de tipo texto
_SW_CUSTOM_INFO_TEXT = 30
# Add3(..., configOrDocumentOption): 1 = crear en documento (alineado a macro VBA típica)
_SW_CUSTOM_PROP_ADD_OPTION = 1

# Carpeta local del pipeline maestro (escritorio) y subcarpeta DXF (solo local, no red)
def _piezas_a_procesar_desktop_dir() -> str:
    return os.path.join(os.path.expanduser("~"), "Desktop", "Piezas_A_Procesar")


def _cad_network_map_path() -> str:
    """Compat: mapa en carpeta por defecto del escritorio."""
    return _cad_network_map_path_for(_piezas_a_procesar_desktop_dir())


# Origen de red por defecto para POST /api/cad/preparar (Fase 1). Opcionalmente se sobrescribe vía payload.
_CAD_RED_IMPORT_SOURCE_DEFAULT = (
    r"Z:\INGENIERIA\Alejandro de Jesus Gonzalez Hdez\BASE DE DATOS INGENIERIA\EXPERIMENTO"
)


def _resolve_local_folder_cad(local_folder: Optional[str]) -> str:
    """Carpeta de trabajo absoluta; vacío → ~/Desktop/Piezas_A_Procesar."""
    s = (local_folder or "").strip()
    if not s:
        return _piezas_a_procesar_desktop_dir()
    return os.path.abspath(os.path.expanduser(s))


def _cad_network_map_path_for(work_dir: str) -> str:
    """Mapa basename→ruta red dentro de la carpeta de trabajo elegida."""
    return os.path.join(os.path.abspath(work_dir), ".cad_network_map.json")


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


def _read_2d_file_bbox_largo_ancho_mm(path_2d: str) -> Optional[tuple]:
    """Intenta medir Largo/Ancho (mm) desde .dxf o .dwg con ezdxf (DWG binario puede fallar)."""
    low = path_2d.lower()
    if not low.endswith((".dxf", ".dwg")):
        return None
    return _dxf_bbox_largo_ancho_mm(path_2d)


def _resolve_2d_path_in_directory(folder: str, codigo: str) -> Optional[str]:
    """Una carpeta: JA-002.DXF / Chapa desplegada - JA-002.DXF / .dwg / .DWG y listado *.dxf/*.dwg."""
    folder = os.path.abspath(folder)
    if not os.path.isdir(folder):
        return None
    stem_norm = _normalize_chapa_stem(str(codigo))
    if not stem_norm:
        return None
    pref = f"Chapa desplegada - {stem_norm}"
    for fn in (
        f"{stem_norm}.dxf",
        f"{stem_norm}.DXF",
        f"{pref}.dxf",
        f"{pref}.DXF",
        f"{stem_norm}.dwg",
        f"{stem_norm}.DWG",
        f"{pref}.dwg",
        f"{pref}.DWG",
    ):
        p = os.path.join(folder, fn)
        if os.path.isfile(p):
            return p
    key = stem_norm.lower()
    try:
        for fn in os.listdir(folder):
            low = fn.lower()
            if not (low.endswith(".dxf") or low.endswith(".dwg")):
                continue
            base = os.path.splitext(fn)[0]
            if _normalize_chapa_stem(base).lower() == key:
                return os.path.join(folder, fn)
    except OSError:
        pass
    return None


def _resolve_dxf_path_for_codigo(dxf_folder: str, codigo: str) -> Optional[str]:
    """Compat: solo ``dxf_folder`` (Fase 2). Preferir ``_resolve_2d_reference_for_codigo`` con carpeta local."""
    return _resolve_2d_path_in_directory(dxf_folder, codigo)


def _resolve_2d_reference_for_codigo(
    dxf_folder: str, local_folder: str, codigo: str
) -> Optional[str]:
    """Referencia 2D para cruce: primero ``local_folder/dxf``, luego raíz ``local_folder``."""
    for d in (os.path.abspath(dxf_folder), os.path.abspath(local_folder)):
        hit = _resolve_2d_path_in_directory(d, codigo)
        if hit:
            return hit
    return None


def _find_sw_exported_corregido_dxf(dxf_export_dir: str, codigo: str) -> Optional[str]:
    """SolidWorks a veces varía mayúsculas o nombre; localiza ``{codigo}_SW_CORREGIDO*.dxf``."""
    dxf_export_dir = os.path.abspath(dxf_export_dir)
    stem = f"{_normalize_chapa_stem(str(codigo))}_SW_CORREGIDO"
    p = os.path.join(dxf_export_dir, f"{stem}.dxf")
    if os.path.isfile(p):
        return p
    try:
        for fn in os.listdir(dxf_export_dir):
            low = fn.lower()
            if not low.endswith(".dxf"):
                continue
            base, _ = os.path.splitext(fn)
            if base.upper().startswith(stem.upper()):
                return os.path.join(dxf_export_dir, fn)
    except OSError:
        pass
    return None


# #region agent log
def _debug_sw_export_log(hypothesis_id: str, message: str, data: dict) -> None:
    try:
        import time

        root = Path(__file__).resolve().parents[2]
        log_path = root / "debug-e58d72.log"
        payload = {
            "sessionId": "e58d72",
            "timestamp": int(time.time() * 1000),
            "hypothesisId": hypothesis_id,
            "location": "cad.py:_sw_part_try_export_to_dwg2",
            "message": message,
            "data": data,
        }
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")
    except Exception:
        pass


# #endregion


def _sw_part_try_export_to_dwg2(sw_model, out_path: str, part_path: str, codigo: str) -> bool:
    """IModelDoc2.ExportToDWG2: args 5/8/9 son VARIANT; ``None``/``[]`` provocan DISP_E_TYPEMISMATCH (índ. 8)."""
    import pythoncom
    from win32com.client import VARIANT as COMVARIANT

    out_s, in_s = str(out_path), str(part_path)

    def _run(hid: str, fn) -> bool:
        try:
            fn()
            _debug_sw_export_log(hid, "export_ok", {"codigo": codigo})
            return True
        except Exception as e:
            _debug_sw_export_log(
                hid, "export_fail", {"codigo": codigo, "error": str(e)[:220]}
            )
            return False

    if _run(
        "H1_VT_EMPTY",
        lambda: sw_model.ExportToDWG2(
            out_s,
            in_s,
            1,
            True,
            COMVARIANT(pythoncom.VT_EMPTY, None),
            False,
            True,
            COMVARIANT(pythoncom.VT_EMPTY, None),
            COMVARIANT(pythoncom.VT_EMPTY, None),
        ),
    ):
        return True

    if _run(
        "H2_Missing",
        lambda: sw_model.ExportToDWG2(
            out_s,
            in_s,
            1,
            True,
            pythoncom.Missing,
            False,
            True,
            pythoncom.Missing,
            pythoncom.Missing,
        ),
    ):
        return True

    if _run(
        "H3_align0_empty89",
        lambda: sw_model.ExportToDWG2(
            out_s,
            in_s,
            1,
            True,
            0.0,
            False,
            True,
            COMVARIANT(pythoncom.VT_EMPTY, None),
            COMVARIANT(pythoncom.VT_EMPTY, None),
        ),
    ):
        return True

    if _run(
        "H4_Extension_VT_EMPTY",
        lambda: sw_model.Extension.ExportToDWG2(
            out_s,
            in_s,
            1,
            True,
            COMVARIANT(pythoncom.VT_EMPTY, None),
            False,
            True,
            COMVARIANT(pythoncom.VT_EMPTY, None),
            COMVARIANT(pythoncom.VT_EMPTY, None),
        ),
    ):
        return True

    return False


def _resolve_dxf_path_in_project_subdirs(
    root_path: str, codigo: str, info_codigo: str = ""
) -> Optional[str]:
    """Busca ``.dxf`` bajo ``root_path/dxf`` o ``root_path/BIBLIOTECA_DXF`` (escaneo red / proyecto)."""
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
    """pairs: list of (ruta_dwg_abs, ruta_dxf_salida_abs). Una sesión AutoCAD + reintento si Open colapsa."""
    if not pairs:
        return
    import time as _time
    try:
        import win32com.client as _wc
    except Exception:
        for _, out in pairs:
            _escribir_log(f"[2D] AutoCAD no disponible; no se convirtió a {out}")
        return

    def _acad_restart():
        os.system("taskkill /F /IM acad.exe /T 2>nul")
        _time.sleep(2)
        a = _wc.Dispatch("AutoCAD.Application")
        try:
            a.Visible = False
        except Exception:
            pass
        return a

    def _open_dwg_retry(a, p: str):
        try:
            return a.Documents.Open(p), a
        except Exception:
            _escribir_log(f"[2D] Open DWG falló; reiniciando ACAD y reintentando: {p}")
            try:
                a.Quit()
            except Exception:
                pass
            a = _acad_restart()
        try:
            return a.Documents.Open(p), a
        except Exception:
            return None, a

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
                doc, acad = _open_dwg_retry(acad, dwg_abs)
                if doc is None:
                    _escribir_log(f"[2D] DWG→DXF FALLO (sin doc): {dwg_abs}")
                    continue
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


def _sw_model_has_sheet_metal(sw_model) -> bool:
    """True si el documento tiene chapa (SheetMetal / FlatPattern) en el árbol de features."""
    try:
        feat = sw_model.FirstFeature()
        while feat is not None:
            try:
                t = feat.GetTypeName2()
            except Exception:
                t = ""
            if t in ("SheetMetal", "FlatPattern"):
                return True
            try:
                feat = feat.GetNextFeature()
            except Exception:
                break
    except Exception as ex:
        _escribir_log(f"[SW] detección chapa (sheet metal): {ex!r}")
    return False


def _sw_doc_count(sw_app) -> int:
    try:
        return int(sw_app.GetDocumentCount())
    except Exception:
        return -1


def _sw_close_doc_by_name(sw_app, name: str) -> bool:
    """CloseDoc exige el título exacto del documento en SolidWorks."""
    if not name or not str(name).strip():
        return False
    name = str(name).strip()
    for candidate in (name, name.upper(), name.lower()):
        try:
            sw_app.CloseDoc(candidate)
            return True
        except Exception:
            pass
    return False


def _sw_close_all_open_documents(sw_app, log_prefix: str = "") -> int:
    """Cierra todos los documentos abiertos (bucle GetFirstDocument). Devuelve los que quedan."""
    closed = 0
    for _ in range(600):
        doc = None
        try:
            doc = sw_app.GetFirstDocument()
        except Exception:
            pass
        if doc is None:
            try:
                doc = sw_app.ActiveDoc
            except Exception:
                doc = None
        if doc is None:
            break
        title = ""
        path = ""
        try:
            title = str(doc.GetTitle() or "").strip()
        except Exception:
            pass
        try:
            path = str(doc.GetPathName() or "").strip()
        except Exception:
            pass
        ok = False
        for candidate in (title, os.path.basename(path), path):
            if candidate and _sw_close_doc_by_name(sw_app, candidate):
                ok = True
                closed += 1
                break
        if not ok:
            try:
                doc.Close()
                closed += 1
            except Exception:
                if log_prefix:
                    _escribir_log(
                        f"{log_prefix}No se pudo cerrar documento SW: "
                        f"{title or path or '?'!r}"
                    )
                break
    remaining = _sw_doc_count(sw_app)
    if log_prefix and closed > 0:
        _escribir_log(f"{log_prefix}Cerrados {closed} doc(s); abiertos: {remaining}")
    return remaining


def _sw_force_close_part_document(
    sw_app,
    sw_model,
    part_path: str = "",
    codigo: str = "",
) -> int:
    """
    Cierra la pieza abierta y cualquier documento con la misma ruta.
    Devuelve GetDocumentCount() tras el cierre (0 = éxito).
    """
    part_norm = ""
    if part_path:
        try:
            part_norm = os.path.normcase(os.path.abspath(part_path))
        except Exception:
            part_norm = os.path.normcase(part_path)

    if sw_model is not None:
        try:
            sw_model.SetSaveFlag(False)
        except Exception:
            pass
        for meth in ("Close", "CloseDoc"):
            try:
                fn = getattr(sw_model, meth, None)
                if callable(fn):
                    fn()
            except Exception:
                pass
        title = ""
        path_name = ""
        try:
            title = str(sw_model.GetTitle() or "").strip()
        except Exception:
            pass
        try:
            path_name = str(sw_model.GetPathName() or "").strip()
        except Exception:
            pass
        for candidate in (
            title,
            os.path.basename(path_name),
            path_name,
            os.path.basename(part_path) if part_path else "",
            part_path,
        ):
            if candidate:
                _sw_close_doc_by_name(sw_app, candidate)

    if part_norm:
        for _ in range(20):
            try:
                doc = sw_app.GetOpenDocumentByName(part_path)
            except Exception:
                doc = None
            if doc is None:
                break
            t = ""
            try:
                t = str(doc.GetTitle() or "").strip()
            except Exception:
                pass
            if not t:
                try:
                    t = os.path.basename(str(doc.GetPathName() or ""))
                except Exception:
                    pass
            if not _sw_close_doc_by_name(sw_app, t):
                try:
                    doc.Close()
                except Exception:
                    break

    remaining = _sw_doc_count(sw_app)
    if remaining > 0:
        prefix = f"[SW][{codigo}] " if codigo else "[SW] "
        remaining = _sw_close_all_open_documents(sw_app, log_prefix=prefix)

    if remaining > 0 and codigo:
        _escribir_log(
            f"[SW] ADVERTENCIA: tras cierre de {codigo} quedan {remaining} "
            "documento(s) abiertos en SolidWorks."
        )
    return remaining


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
    """Réplica macro VBA: Add3(..., 'mm') + Set + Save3 obligatorio en el .sldprt local."""
    import pythoncom
    import win32com.client as _wc

    def _fmt_mm(x: float) -> str:
        return f"{float(x):.4f} mm"

    try:
        cm = sw_model.Extension.CustomPropertyManager("")
        pairs: List[tuple] = []
        if codigo_pieza and str(codigo_pieza).strip():
            pairs.append(("CODIGO_PIEZA", str(codigo_pieza).strip()))
        pairs.extend(
            [
                ("Largo_CAD", _fmt_mm(largo)),
                ("Ancho_CAD", _fmt_mm(ancho)),
                ("Espesor_Perfil_CAD", _fmt_mm(espesor)),
            ]
        )

        for name, val in pairs:
            try:
                cm.Delete2(name)
            except Exception:
                pass
            try:
                cm.Add3(name, _SW_CUSTOM_INFO_TEXT, val, _SW_CUSTOM_PROP_ADD_OPTION)
            except TypeError:
                try:
                    cm.Add3(name, _SW_CUSTOM_INFO_TEXT, val)
                except Exception:
                    try:
                        cm.Set2(name, _SW_CUSTOM_INFO_TEXT, val)
                    except Exception:
                        try:
                            cm.Set(name, val)
                        except Exception:
                            return False
            except Exception:
                try:
                    cm.Add3(name, _SW_CUSTOM_INFO_TEXT, val)
                except Exception:
                    try:
                        cm.Set2(name, _SW_CUSTOM_INFO_TEXT, val)
                    except Exception:
                        try:
                            cm.Set(name, val)
                        except Exception:
                            return False
            try:
                cm.Set(name, val)
            except Exception:
                try:
                    cm.Set2(name, _SW_CUSTOM_INFO_TEXT, val)
                except Exception:
                    pass

        try:
            sw_model.Save3(1, None, None)
            return True
        except Exception:
            pass
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


def _sldprt_force_cutlist_after_open(sw_model) -> None:
    """Tras abrir la pieza: fuerza lista de cortes / chapa en memoria (propiedades envolvente)."""
    try:
        ext = sw_model.Extension
        if ext is not None:
            for _upd in ("UpdateCutList", "UpdateSheetMetalCutList"):
                fn = getattr(ext, _upd, None)
                if callable(fn):
                    try:
                        fn()
                        break
                    except Exception:
                        continue
    except Exception:
        pass
    try:
        if callable(getattr(sw_model, "ForceRebuild3", None)):
            sw_model.ForceRebuild3(False)
        elif callable(getattr(sw_model, "ForceRebuild2", None)):
            sw_model.ForceRebuild2(False)
        elif callable(getattr(sw_model, "ForceRebuild", None)):
            sw_model.ForceRebuild()
    except Exception:
        pass


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


def _sldprt_maestro_read_post_macro(
    sw_local,
    abspath,
    codigo,
    nombre_archivo,
    ruta_abs,
    resurrect_fn=None,
    dxf_largo_cmp: Optional[float] = None,
    dxf_ancho_cmp: Optional[float] = None,
    inyectar_propiedades: bool = False,
    ruta_original_red: Optional[str] = None,
    dxf_export_dir: Optional[str] = None,
):
    """
    Tras ejecutar la macro VBA: abre el .sldprt en solo lectura y lee únicamente
    Largo_CAD, Ancho_CAD y Espesor_Perfil_CAD del CustomPropertyManager del documento.
    Cruza con DXF previo; si difiere, exporta DXF nuevo y lo mide con ezdxf.
    """
    import re as _re

    import pythoncom
    import win32com.client

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
            "largo_cad": 0.0,
            "ancho_cad": 0.0,
            "espesor_cad": 0.0,
            "observacion": _ascii_report_text("Omitido (no es .SLDPRT)"),
            "rpc_continue": False,
            "largo_dxf_nuevo": None,
            "ancho_dxf_nuevo": None,
        }

    injected_copy_ok = False
    swDocPART = 1
    SW_OPEN_SILENT = 1
    SW_OPEN_READONLY = 2
    # ExportToDWG2 suele fallar con documento abierto solo lectura; auditar pasa dxf_export_dir.
    if dxf_export_dir:
        open_options = SW_OPEN_SILENT
    else:
        open_options = SW_OPEN_SILENT | SW_OPEN_READONLY

    arg_errors = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
    arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
    swModel = None
    _sw_force_close_part_document(sw_local, None, ruta_abs, codigo)
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
        if is_rpc_crash and resurrect_fn:
            resurrect_fn()
            return {
                "rpc_continue": True,
                "codigo": _ascii_report_text(codigo),
                "largo_cad": 0.0,
                "ancho_cad": 0.0,
                "espesor_cad": 0.0,
                "observacion": _ascii_report_text("ERROR RPC al abrir (solo lectura)."),
                "largo_dxf_nuevo": None,
                "ancho_dxf_nuevo": None,
            }
        _escribir_log(f"Maestro apertura SLDPRT detalle ({codigo}): {try_open_err!r}")
        return {
            "rpc_continue": False,
            "codigo": _ascii_report_text(codigo),
            "largo_cad": 0.0,
            "ancho_cad": 0.0,
            "espesor_cad": 0.0,
            "observacion": _ascii_report_text(
                "ERROR: No se pudo abrir la pieza en SolidWorks."
            ),
            "largo_dxf_nuevo": None,
            "ancho_dxf_nuevo": None,
        }

    if swModel is None:
        return {
            "rpc_continue": False,
            "codigo": _ascii_report_text(codigo),
            "largo_cad": 0.0,
            "ancho_cad": 0.0,
            "espesor_cad": 0.0,
            "observacion": _ascii_report_text("No se pudo abrir el documento."),
            "largo_dxf_nuevo": None,
            "ancho_dxf_nuevo": None,
        }

    try:
        prop_mgr = swModel.Extension.CustomPropertyManager("")

        def _parse_dim(prop_name: str) -> float:
            raw = _icm_get_property_raw(prop_mgr, prop_name)
            if raw is None:
                return 0.0
            s = str(raw).strip()
            if not s or s in ("-", "0"):
                return 0.0
            try:
                num = _re.sub(r"[^\d.\-]", "", s.lower().replace("mm", "").replace(",", "."))
                return float(num) if num and num != "." else 0.0
            except (ValueError, TypeError):
                return 0.0

        largo_cad = _parse_dim("Largo_CAD")
        ancho_cad = _parse_dim("Ancho_CAD")
        espesor_cad = _parse_dim("Espesor_Perfil_CAD")

        if largo_cad > 0 and ancho_cad > 0:
            largo_cad, ancho_cad = max(largo_cad, ancho_cad), min(largo_cad, ancho_cad)

        observacion = "OK (Propiedades macro VBA)"
        if largo_cad == 0 or ancho_cad == 0:
            observacion = "ERROR: Largo_CAD/Ancho_CAD vacíos tras macro"

        observacion = _apply_dxf_cad_audit_cross(
            observacion, largo_cad, ancho_cad, dxf_largo_cmp, dxf_ancho_cmp
        )

        is_sheet_metal = _sw_model_has_sheet_metal(swModel)
        has_old_dxf = dxf_largo_cmp is not None and dxf_ancho_cmp is not None
        delta_largo = abs(float(largo_cad) - float(dxf_largo_cmp or 0.0))
        delta_ancho = abs(float(ancho_cad) - float(dxf_ancho_cmp or 0.0))
        needs_cad_vs_dxf_fix = has_old_dxf and (
            delta_largo > _DXF_CAD_AUDIT_TOL_MM
            or delta_ancho > _DXF_CAD_AUDIT_TOL_MM
        )
        # Export DXF nuevo solo: chapa que necesita corrección/ref. 2D, o sólido/perfil que
        # ya tenía DXF y difiere (no exportar desplegado para sólido sin DXF previo).
        sheet_metal_needs_export = (
            is_sheet_metal
            and largo_cad > 0
            and ancho_cad > 0
            and (
                not has_old_dxf
                or delta_largo > _DXF_CAD_AUDIT_TOL_MM
                or delta_ancho > _DXF_CAD_AUDIT_TOL_MM
            )
        )
        need_export = largo_cad > 0 and ancho_cad > 0 and (
            needs_cad_vs_dxf_fix or sheet_metal_needs_export
        )

        if (
            not is_sheet_metal
            and not has_old_dxf
            and largo_cad > 0
            and ancho_cad > 0
            and not str(observacion).upper().startswith("ERROR")
        ):
            observacion = "OK (Sólido/Perfil - Bounding Box)"

        # Auto-corrección DXF (columnas K/L): solo si need_export
        if need_export and dxf_export_dir:
            os.makedirs(dxf_export_dir, exist_ok=True)
            ruta_dxf_nuevo = os.path.join(dxf_export_dir, f"{codigo}_SW_CORREGIDO.dxf")
            try:
                try:
                    sw_local.Visible = True
                except Exception:
                    pass
                _export_ok = _sw_part_try_export_to_dwg2(
                    swModel, ruta_dxf_nuevo, ruta_abs, codigo
                )
                if not _export_ok:
                    _escribir_log(
                        f"Fallo crítico ExportToDWG2 (todas las variantes COM) para {codigo}"
                    )
                if _export_ok:
                    ruta_medir = _find_sw_exported_corregido_dxf(dxf_export_dir, codigo)
                    if not ruta_medir and os.path.isfile(ruta_dxf_nuevo):
                        ruta_medir = ruta_dxf_nuevo
                    if ruta_medir and os.path.isfile(ruta_medir):
                        bbox_nuevo = _dxf_bbox_largo_ancho_mm(ruta_medir)
                        if bbox_nuevo:
                            largo_dxf_nuevo = float(bbox_nuevo[0])
                            ancho_dxf_nuevo = float(bbox_nuevo[1])
                            observacion = f"{observacion} | DXF exportado y medido"
                        else:
                            _escribir_log(
                                f"DXF nuevo creado pero sin bbox ezdxf: {ruta_medir!r} ({codigo})"
                            )
                    else:
                        _escribir_log(
                            f"ExportToDWG2 no dejó archivo esperado para {codigo}: "
                            f"probado {ruta_dxf_nuevo!r}"
                        )
            except Exception as ex_dwg:
                _escribir_log(f"Error exportando DXF nuevo para {codigo}: {ex_dwg}")

        if (
            inyectar_propiedades
            and ruta_original_red
            and os.path.isfile(ruta_original_red)
            and largo_cad > 0
            and ancho_cad > 0
        ):
            try:
                shutil.copy2(ruta_abs, ruta_original_red)
                injected_copy_ok = True
            except Exception as copy_err:
                _escribir_log(f"Red copia fallida ({codigo}): {copy_err!r}")
                observacion = f"{observacion} | Red: copia fallida"
    finally:
        _sw_force_close_part_document(sw_local, swModel, ruta_abs, codigo)
        swModel = None
        import gc as _gc
        _gc.collect()

    return {
        "rpc_continue": False,
        "codigo": _ascii_report_text(codigo),
        "largo_cad": largo_cad,
        "ancho_cad": ancho_cad,
        "espesor_cad": espesor_cad,
        "observacion": _ascii_report_text(observacion),
        "largo_dxf_nuevo": largo_dxf_nuevo,
        "ancho_dxf_nuevo": ancho_dxf_nuevo,
        "injected_copy_ok": injected_copy_ok,
    }


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
    
    # Siempre editable: tras medir se inyectan propiedades y Save3 (réplica VBA).
    open_options = SW_OPEN_SILENT

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
        _escribir_log(f"Extract apertura detalle ({codigo}): {try_open_err!r}")
        observacion = "ERROR: No se pudo abrir la pieza en SolidWorks."
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
            # PASO 1: DXF/DWG antiguo (ya buscado fuera). Registrar medidas de referencia.
            _escribir_log(
                f"Paso 1 completado: DXF previo={dxf_largo_cmp}x{dxf_ancho_cmp}"
            )

            # PASO 2: SolidWorks ya abrió en escritura (OpenDoc6 con options=1).
            _escribir_log("Paso 2 completado: pieza abierta en modo escritura.")

            # PASO 3: Réplica VBA a prueba de fallos (CM global; sin CutListFolder recursivo).
            largo_cad, ancho_cad, espesor_cad = 0.0, 0.0, 0.0
            is_sheet_metal = False
            observacion = ""

            def _parse_mm_prop(val) -> Optional[float]:
                if val is None:
                    return None
                s = str(val).strip()
                if not s or s == "0":
                    return None
                try:
                    return float(s.replace(",", ".").split()[0])
                except (ValueError, IndexError):
                    return None

            def _global_prop_get(prop_mgr, name: str):
                """VBA Get(n); en Python COM usar lectura segura si Get falla."""
                try:
                    v = prop_mgr.Get(name)
                    if v is not None and str(v).strip() not in ("", "0"):
                        return v
                except Exception:
                    pass
                return _icm_get_property_raw(prop_mgr, name)

            try:
                # 1. Determinar si es chapa (recorrido rápido)
                feat = swModel.FirstFeature()
                while feat is not None:
                    try:
                        if feat.GetTypeName2() in ("SheetMetal", "FlatPattern"):
                            is_sheet_metal = True
                            break
                    except Exception:
                        pass
                    try:
                        feat = feat.GetNextFeature()
                    except Exception:
                        break

                # 2. Propiedades GLOBALES del documento (CutList propagada en SW reciente)
                try:
                    prop_mgr = swModel.Extension.CustomPropertyManager("")
                    nombres_largo = ["Largo del envolvente", "Bounding Box Length"]
                    nombres_ancho = ["Ancho del envolvente", "Bounding Box Width"]

                    for n in nombres_largo:
                        val = _global_prop_get(prop_mgr, n)
                        if val is not None and str(val).strip() not in ("", "0"):
                            parsed = _parse_mm_prop(val)
                            if parsed is not None and parsed > 0:
                                largo_cad = float(parsed)
                                break
                    for n in nombres_ancho:
                        val = _global_prop_get(prop_mgr, n)
                        if val is not None and str(val).strip() not in ("", "0"):
                            parsed = _parse_mm_prop(val)
                            if parsed is not None and parsed > 0:
                                ancho_cad = float(parsed)
                                break
                except Exception as e:
                    _escribir_log(f"Error leyendo propMgr global: {e}")

                # 3. Fallback a GetPartBox
                observacion = "OK (Propiedades Nativas)"
                if largo_cad == 0 or ancho_cad == 0:
                    try:
                        box = swModel.GetPartBox(True)
                        if box and len(box) >= 6:
                            dx = abs(box[3] - box[0]) * 1000
                            dy = abs(box[4] - box[1]) * 1000
                            dz = abs(box[5] - box[2]) * 1000
                            dims = sorted([dx, dy, dz], reverse=True)
                            largo_cad = float(dims[0])
                            ancho_cad = float(dims[1])
                            espesor_cad = float(dims[2])
                            observacion = "⚠️ ALERTA: Medida de pieza doblada"
                    except Exception as e_box:
                        _escribir_log(f"Error GetPartBox fallback: {e_box}")
                        if not observacion:
                            observacion = "ERROR: sin medidas (propiedades ni caja)"

                _escribir_log(
                    f"Paso 3 completado: CAD midió {largo_cad}x{ancho_cad} (sheet_metal={is_sheet_metal})"
                )
            except Exception as main_err:
                _escribir_log(f"Error critico en Paso 3: {main_err}")
                if not observacion:
                    _escribir_log(f"Paso 3 excepción ({codigo}): {main_err!r}")
                    observacion = "ERROR: Paso 3 (lectura de medidas) sin completar."

            # PASO 4: Inyectar propiedades CAD en documento.
            try:
                cm_doc = swModel.Extension.CustomPropertyManager("")
                cm_doc.Set("Largo_CAD", f"{float(largo_cad):.4f} mm")
                cm_doc.Set("Ancho_CAD", f"{float(ancho_cad):.4f} mm")
                cm_doc.Set("Espesor_Perfil_CAD", f"{float(espesor_cad):.4f} mm")
                _escribir_log("Paso 4 completado: propiedades CAD inyectadas.")
            except Exception as _inj_err:
                _escribir_log(f"Paso 4 advertencia: inyeccion parcial ({_inj_err})")

            # PASO 5: Comparacion vs DXF antiguo y exportacion de DXF nuevo si aplica.
            _sin_dxf_prev = dxf_largo_cmp is None or dxf_ancho_cmp is None
            _delta_largo = abs(float(largo_cad or 0.0) - float(dxf_largo_cmp or 0.0))
            if (_sin_dxf_prev or _delta_largo > 1.0) and largo_cad > 0 and ancho_cad > 0:
                try:
                    dxf_folder = os.path.join(_piezas_a_procesar_desktop_dir(), "dxf")
                    os.makedirs(dxf_folder, exist_ok=True)
                    ruta_dxf_nuevo = os.path.join(dxf_folder, f"{codigo}_SW_CORREGIDO.dxf")
                    _export_ok_p5 = _sw_part_try_export_to_dwg2(
                        swModel, ruta_dxf_nuevo, ruta_abs, codigo
                    )
                    if not _export_ok_p5:
                        _escribir_log(
                            f"Fallo crítico ExportToDWG2 extract PASO 5 (todas variantes) para {codigo}"
                        )
                    if _export_ok_p5 and os.path.exists(ruta_dxf_nuevo):
                        _d = ezdxf.readfile(ruta_dxf_nuevo)
                        _ext_dxf = ezdxf_bbox.extents(_d.modelspace())
                        if _ext_dxf.has_data:
                            _dx = _ext_dxf.extmax.x - _ext_dxf.extmin.x
                            _dy = _ext_dxf.extmax.y - _ext_dxf.extmin.y
                            largo_dxf_nuevo = float(max(_dx, _dy))
                            ancho_dxf_nuevo = float(min(_dx, _dy))
                            print(f"DXF Nuevo medido: {largo_dxf_nuevo}x{ancho_dxf_nuevo}")
                except Exception as export_err:
                    _escribir_log(f"Paso 5 advertencia: export/medicion DXF nuevo fallo ({export_err})")
            _escribir_log("Paso 5 completado: DXF nuevo generado y medido.")

            # PASO 6: Guardar fisicamente y cerrar (cierre en finally).
            try:
                swModel.Save2(True)
                injected_and_saved = True
                _escribir_log("Paso 6 completado: pieza guardada fisicamente.")
            except Exception as save_err:
                _escribir_log(f"Paso 6 advertencia: Save2 fallo ({save_err})")

            observacion = _apply_dxf_cad_audit_cross(
                observacion, largo_cad, ancho_cad, dxf_largo_cmp, dxf_ancho_cmp
            )
        except Exception as math_err:
            _escribir_log(f"Error matemático extracción ({codigo}): {math_err!r}")
            observacion = "ERROR: Procesamiento interrumpido."
        finally:
            _sw_force_close_part_document(sw_local, swModel, ruta_abs, codigo)
            swModel = None
            import gc as _gc
            _gc.collect()

    if (
        injected_and_saved
        and inyectar_propiedades
        and ruta_original_red
        and os.path.isfile(ruta_original_red)
    ):
        try:
            shutil.copy2(ruta_abs, ruta_original_red)
        except Exception as copy_err:
            _escribir_log(f"Red copia fallida extract ({codigo}): {copy_err!r}")
            observacion = f"{observacion} | Red: copia fallida"

    resultados = {
        "rpc_continue": False,
        "codigo": _ascii_report_text(codigo),
        "largo_cad": largo_cad,
        "ancho_cad": ancho_cad,
        "espesor_cad": espesor_cad,
        "observacion": _ascii_report_text(observacion),
        "largo_dxf_nuevo": largo_dxf_nuevo,
        "ancho_dxf_nuevo": ancho_dxf_nuevo,
    }
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
                        _dxf_p_audit = _resolve_dxf_path_in_project_subdirs(
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
                    _escribir_log(f"Extract pieza excepción ({codigo}): {extract_err!r}")
                    observacion = "ERROR: Fallo al extraer datos CAD."
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
# PIPELINE HÍBRIDO: /api/cad/preparar (Fase 1) + macro manual + /api/cad/auditar (Fase 2)
# ═══════════════════════════════════════════════════════════════════════════════

def bg_preparar_task(
    source_folder: str,
    local_folder: str,
    solo_faltantes: bool = False,
) -> None:
    """Fase 1 (híbrido): BD + copia red→local, mapa JSON, convertir_dwg.py. Sin RunMacro2."""
    import datetime as _dt

    global scan_status, abortar_escaneo_cad, cad_execution_logs, cad_procesar_status

    cad_execution_logs.clear()
    _cad_telemetry_clear()
    cad_procesar_status = "processing"
    scan_status["status"] = "collecting"
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

    source_folder = os.path.abspath(os.path.expanduser(source_folder.strip()))
    local_folder = os.path.abspath(os.path.expanduser(local_folder.strip()))
    os.makedirs(local_folder, exist_ok=True)
    _log(f"📁 local_folder (destino): {local_folder}")
    _log(f"📡 source_folder (origen red): {source_folder}")

    _EXCLUDED_DIRS_MAESTRO = {
        "dxf_convertidos", "exportados", "biblioteca_dxf",
        "cad_pendientes", "reportes", "__pycache__", ".git",
        "node_modules", "venv", ".venv", "dist", "build",
        "piezas_a_procesar",
    }

    network_by_local_basename: Dict[str, str] = {}

    try:
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

        _log(f"📡 Buscando archivos CAD en la red: {source_folder}")
        scan_status["current_file"] = "Paso 0: Copiando archivos desde la red..."

        copiados = 0
        cad_candidatos: list = []
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

            if piezas_objetivo and base_norm not in piezas_objetivo:
                continue

            dest = os.path.join(local_folder, os.path.basename(full_path))
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
                copiados += 1

        _log(f"✅ Copia desde red: {copiados} archivos disponibles en carpeta local.")

        if abortar_escaneo_cad:
            try:
                _mp = _cad_network_map_path_for(local_folder)
                with open(_mp, "w", encoding="utf-8") as f:
                    json.dump(network_by_local_basename, f, ensure_ascii=False, indent=0)
                _log(f"💾 Mapa parcial guardado: {_mp}")
            except Exception as ex_w:
                _log(f"⚠️ No se pudo guardar mapa: {ex_w}")
            scan_status["status"] = "cancelled"
            cad_procesar_status = "completed"
            _log("🛑 Preparar cancelado.")
        else:
            try:
                _mp = _cad_network_map_path_for(local_folder)
                with open(_mp, "w", encoding="utf-8") as f:
                    json.dump(network_by_local_basename, f, ensure_ascii=False, indent=0)
                _log(f"💾 Mapa red→local: {_mp}")
            except Exception as ex_w:
                _log(f"⚠️ No se pudo guardar mapa: {ex_w}")

            _log("🔄 convertir_dwg.py (DWG → DXF) en carpeta local...")
            scan_status["current_file"] = "convertir_dwg.py..."
            script_dwg = os.path.join(_BACKEND_ROOT, "tools", "convertir_dwg.py")
            if not os.path.exists(script_dwg):
                _log(f"⚠️ Script DWG no encontrado: {script_dwg}")
            else:
                try:
                    cmd_dwg = [sys.executable, script_dwg, local_folder]
                    if solo_faltantes:
                        cmd_dwg.append("--solo-faltantes")
                        # Misma lista que Paso 0 (sin medidas en BD), no Tiene_DXF.
                        if piezas_objetivo:
                            _codigos_faltantes_path = os.path.join(
                                local_folder, ".cad_faltantes_codigos.txt"
                            )
                            try:
                                with open(
                                    _codigos_faltantes_path,
                                    "w",
                                    encoding="utf-8",
                                ) as _cf:
                                    for _c in sorted(piezas_objetivo):
                                        _cf.write(f"{_c}\n")
                                cmd_dwg.extend(
                                    ["--codigos-file", _codigos_faltantes_path]
                                )
                                _log(
                                    f"   → DWG: filtro {len(piezas_objetivo)} codigos "
                                    "(sin medidas en BD, misma lista Paso 0)."
                                )
                            except OSError as _ex_cf:
                                _log(
                                    f"⚠️ No se pudo escribir lista faltantes: {_ex_cf}"
                                )
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

            scan_status["status"] = "completed"
            cad_procesar_status = "completed"
            _log("✅ Fase 1 (preparar) completada. Ejecute la macro VBA manualmente en SolidWorks y luego Fase 2.")

    except Exception as pipeline_err:
        _log(f"❌ Error en preparar: {pipeline_err}")
        scan_status["status"] = "error"
        scan_status["error"] = str(pipeline_err)
        cad_procesar_status = "completed"


def bg_auditar_task(
    local_folder: str,
    solo_faltantes: bool = False,
    inyectar_propiedades: bool = False,
    actor_user: str = "Sistema",
) -> None:
    """Fase 2 (híbrido): sin RunMacro2 ni convertir_dwg aquí; SW lectura + DXF + Excel + SQL.

    Tras Fase 1 (preparar) el usuario ejecuta la macro VBA manualmente, luego este endpoint.

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

    # ── Carpeta local de trabajo (desde payload) + subcarpeta dxf ─
    local_folder = os.path.abspath(os.path.expanduser(local_folder.strip()))
    os.makedirs(local_folder, exist_ok=True)
    dxf_folder = os.path.join(local_folder, "dxf")
    os.makedirs(dxf_folder, exist_ok=True)
    _log(f"📁 local_folder: {local_folder}")
    _log(f"📁 dxf_folder (DXF antiguo y export): {dxf_folder}")

    # Variables de datos acumulados (para el finally)
    data_acumulada: list = []

    _EXCLUDED_DIRS_MAESTRO = {
        "dxf_convertidos", "exportados", "biblioteca_dxf",
        "cad_pendientes", "reportes", "__pycache__", ".git",
        "node_modules", "venv", ".venv", "dist", "build",
        "piezas_a_procesar",  # evitar bucle en la carpeta local
    }

    try:
        pythoncom.CoInitializeEx(pythoncom.COINIT_APARTMENTTHREADED)
    except Exception:
        try:
            pythoncom.CoInitialize()
        except Exception:
            pass

    try:
        # ════════════════════════════════════════════════════════════════
        # PASO 1 (maestro): solo disco local — sin BD, sin os.walk en red
        # ════════════════════════════════════════════════════════════════
        _log(
            "🚀 bg_auditar_task: carpeta local (sin BD/red); "
            f"trabajo en: {local_folder}"
        )

        network_by_local_basename: Dict[str, str] = {}
        _map_path = _cad_network_map_path_for(local_folder)
        if os.path.isfile(_map_path):
            try:
                with open(_map_path, "r", encoding="utf-8") as f:
                    network_by_local_basename = json.load(f)
                _log(
                    f"📋 Mapa red→local cargado ({len(network_by_local_basename)} entradas) "
                    "para inyección opcional al archivo en red."
                )
            except Exception as ex_map:
                _log(f"⚠️ No se pudo cargar .cad_network_map.json: {ex_map}")
        else:
            _log(
                "ℹ️ Sin .cad_network_map.json (ejecutar Fase 1 preparar antes si inyectas a red)."
            )

        if inyectar_propiedades:
            _log(
                "📌 Inyección activada: tras medir, se guardará .sldprt local y se copiará a la ruta de red del mapa."
            )

        scan_status["status"] = "scanning"
        _log(f"   Parámetro solo_faltantes={solo_faltantes} (reservado; el filtro de catálogo aplica en Fase 1).")

        _n_sldprt = 0
        _n_2d = 0
        for _dp, _ds, _fs in os.walk(local_folder):
            _ds[:] = [
                d for d in _ds
                if d.lower() not in _EXCLUDED_DIRS_MAESTRO and d.lower() != "dxf"
            ]
            for _fn in _fs:
                _ex = os.path.splitext(_fn)[1].lower()
                if _ex == ".sldprt":
                    _n_sldprt += 1
                elif _ex in (".dwg", ".dxf"):
                    _n_2d += 1
        _log(
            f"📂 Inventario en {local_folder}: {_n_sldprt} .sldprt, "
            f"{_n_2d} archivos 2D (.dwg/.dxf) presentes en disco."
        )

        # ════════════════════════════════════════════════════════════════
        # Auditoría SW (sin RunMacro2: la macro se ejecutó manualmente entre fases)
        # ════════════════════════════════════════════════════════════════
        _log("🛠 Auditoría: lectura Largo_CAD / Ancho_CAD vía CustomPropertyManager (macro manual previa)...")
        scan_status["current_file"] = "Auditoría: leyendo propiedades CAD vs DXF..."

        # ──── Setup COM (reutiliza instancia en ejecución si existe) ────
        def _apply_silent_mode_m(app):
            for pref, val in [(11, True), (262, True)]:
                try:
                    app.SetUserPreferenceToggle(pref, val)
                except Exception:
                    pass
            # Modo batch: sin ventanas por pieza (evita acumular UI en RAM).
            try:
                app.Visible = False
            except Exception:
                pass
            try:
                app.UserControl = False
            except Exception:
                pass

        def get_sw_app_m(*, log_ready: bool = True):
            try:
                import win32com.client as _wc
                try:
                    app = _wc.GetObject("SldWorks.Application")
                except Exception:
                    app = _wc.DispatchEx("SldWorks.Application")
                _apply_silent_mode_m(app)
                if log_ready:
                    _log("[SW] COM listo (GetObject o DispatchEx).")
                return app
            except Exception as e:
                _log(f"⚠️ SolidWorks COM no disponible: {e}")
                return None

        def _resurrect_m():
            try:
                sw_tmp = get_sw_app_m(log_ready=False)
                if sw_tmp:
                    _sw_close_all_open_documents(sw_tmp)
            except Exception:
                pass
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
                pythoncom.CoInitializeEx(pythoncom.COINIT_APARTMENTTHREADED)
            except Exception:
                try:
                    pythoncom.CoInitialize()
                except Exception:
                    pass
            return get_sw_app_m(log_ready=True)

        import pythoncom

        cad_files_local: dict = {}
        for _dp, _ds, _fs in os.walk(local_folder):
            _ds[:] = [
                d for d in _ds
                if d.lower() not in _EXCLUDED_DIRS_MAESTRO and d.lower() != "dxf"
            ]
            for _f in _fs:
                if _f.startswith("~$"):
                    continue
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

        # ── Parámetros de gestión de memoria SolidWorks ─────────────────────
        # Cada _SW_RESTART_BATCH piezas se mata y reinicia SLDWORKS.EXE para
        # liberar la RAM acumulada. Con 2000+ piezas sin reinicio el proceso
        # supera fácilmente los 4 GB. Un valor entre 60-100 es razonable.
        _SW_RESTART_BATCH = 80

        sw_app_m = get_sw_app_m()
        if not sw_app_m:
            _log("⚠️ No se pudo iniciar SolidWorks COM; abortando auditoría.")
            scan_status["status"] = "error"
            scan_status["error"] = "SolidWorks COM no disponible"
            cad_procesar_status = "completed"
            return

        extraidos_m = 0

        for i_m, info_m in enumerate(lista_local):
            if abortar_escaneo_cad:
                _log("🛑 Extracción CAD cancelada por usuario.")
                break

            # ── Reinicio periódico de SolidWorks para liberar RAM ────────────
            if i_m > 0 and i_m % _SW_RESTART_BATCH == 0:
                _log(
                    f"♻️  Reinicio preventivo de SolidWorks tras {i_m} piezas "
                    f"(batch cada {_SW_RESTART_BATCH}) para liberar RAM..."
                )
                sw_app_m = _resurrect_m()
                import gc as _gc
                _gc.collect()
                _log("✅ SolidWorks reiniciado. Continuando.")

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

            # Referencia 2D ANTES de SW: dxf/ + raíz local; DXF y DWG (Chapa desplegada - o no)
            ruta_dxf_antiguo = _resolve_2d_reference_for_codigo(
                dxf_folder, local_folder, info_m["codigo"]
            )
            if not ruta_dxf_antiguo:
                ruta_dxf_antiguo = _resolve_2d_reference_for_codigo(
                    dxf_folder,
                    local_folder,
                    _normalize_chapa_stem(os.path.splitext(nombre_m)[0]),
                )
            _dl_m: Optional[float] = None
            _da_m: Optional[float] = None
            if ruta_dxf_antiguo:
                _bb_m = _read_2d_file_bbox_largo_ancho_mm(ruta_dxf_antiguo)
                if _bb_m:
                    _dl_m, _da_m = float(_bb_m[0]), float(_bb_m[1])

            try:
                # Paso 3: solo .sldprt entran a esta lista; motor 3D no trata DWG/DXF.
                if ext_m == ".sldprt":
                    ruta_abs_m = os.path.abspath(abspath_m)
                    bn_upper = os.path.basename(abspath_m).upper()
                    ruta_red_m = network_by_local_basename.get(bn_upper)

                    if sw_app_m is None:
                        sw_app_m = get_sw_app_m(log_ready=False)

                    if not sw_app_m:
                        observacion_m = "Motor SW inaccesible"
                    else:
                        out_m = _sldprt_maestro_read_post_macro(
                            sw_app_m,
                            abspath_m,
                            codigo_m,
                            nombre_m,
                            ruta_abs_m,
                            resurrect_fn=_resurrect_m,
                            dxf_largo_cmp=_dl_m,
                            dxf_ancho_cmp=_da_m,
                            inyectar_propiedades=inyectar_propiedades,
                            ruta_original_red=ruta_red_m,
                            dxf_export_dir=dxf_folder,
                        )
                        if out_m.get("rpc_continue"):
                            _log(f"  ⚠️ RPC en {nombre_m}; reiniciando SolidWorks...")
                            sw_app_m = _resurrect_m()
                            if sw_app_m:
                                out_m = _sldprt_maestro_read_post_macro(
                                    sw_app_m,
                                    abspath_m,
                                    codigo_m,
                                    nombre_m,
                                    ruta_abs_m,
                                    resurrect_fn=_resurrect_m,
                                    dxf_largo_cmp=_dl_m,
                                    dxf_ancho_cmp=_da_m,
                                    inyectar_propiedades=inyectar_propiedades,
                                    ruta_original_red=ruta_red_m,
                                    dxf_export_dir=dxf_folder,
                                )
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
                                _log(
                                    f"  ✅ {codigo_m}: L={largo_m:.1f} "
                                    f"A={ancho_m:.1f} E={espesor_m:.1f}"
                                )

                        n_open = _sw_doc_count(sw_app_m)
                        if n_open > 0:
                            _log(
                                f"  ⚠️ Tras {nombre_m} quedan {n_open} doc(s) "
                                "abiertos; limpieza forzada."
                            )
                            _sw_close_all_open_documents(sw_app_m)

            except Exception as ex_m_piece:
                if not observacion_m:
                    observacion_m = "ERROR: Fallo al procesar la pieza."
                _log(f"  ❌ Error procesando {nombre_m}: {ex_m_piece!r}")

            # Fila Excel: mismo DXF que pre-SW (info_m["codigo"]); medidas con _dxf_bbox_largo_ancho_mm
            tiene_dxf_m = "SI" if ruta_dxf_antiguo else "NO"
            largo_dxf_m = "" if _dl_m is None else _dl_m
            ancho_dxf_m = "" if _da_m is None else _da_m

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

        _log(f"✅ Auditoría completada: {extraidos_m} piezas procesadas.")
        scan_status["status"] = "completed"
        cad_procesar_status = "completed"

    except Exception as pipeline_err:
        _log(f"❌ Error crítico en auditoría CAD: {pipeline_err}")
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
                try:
                    st = _cad_sync_dataframe_to_maestro(
                        df_m, _log, actor_user=actor_user
                    )
                    _log(
                        f"📤 SQL Tbl_Maestro_Piezas: actualizadas={st['actualizadas']}, "
                        f"ignoradas={st['ignoradas']}, no_encontradas={st['no_encontradas']}"
                    )
                except Exception as ex_sync:
                    _log(f"⚠️ Error sincronizando BD: {ex_sync}")
                    scan_status["error"] = str(ex_sync)
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


class PrepararPayload(BaseModel):
    """Payload para POST /api/cad/preparar (Paso 0): origen red y destino local obligatorios."""
    source_folder: str
    local_folder: str
    solo_faltantes: bool = False


class AuditarPayload(BaseModel):
    """Payload para POST /api/cad/auditar (Paso 1): carpeta de trabajo local."""
    local_folder: str
    solo_faltantes: bool = False
    inyectar_propiedades: bool = False


@router.post("/api/cad/preparar")
def start_preparar_cad(payload: PrepararPayload, background_tasks: BackgroundTasks):
    """Fase 1 híbrida: catálogo, copia red→local, DWG→DXF."""
    global scan_status, abortar_escaneo_cad, cad_execution_logs, cad_procesar_status

    if not (payload.source_folder or "").strip() or not (payload.local_folder or "").strip():
        raise HTTPException(
            status_code=400,
            detail="source_folder y local_folder son obligatorios y no pueden estar vacíos.",
        )

    busy_states = {"scanning", "collecting", "generating_excel"}
    if scan_status["status"] in busy_states or cad_procesar_status == "processing":
        return {"message": "Ya hay un proceso en curso. Cancélalo primero."}

    abortar_escaneo_cad = False
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    if os.path.exists(flag_path):
        try:
            os.remove(flag_path)
        except Exception:
            pass

    cad_execution_logs.clear()
    cad_procesar_status = "idle"

    background_tasks.add_task(
        bg_preparar_task,
        payload.source_folder,
        payload.local_folder,
        payload.solo_faltantes,
    )
    return {"message": "Fase 1 (preparar) iniciada en segundo plano"}


@router.post("/api/cad/auditar")
def start_auditar_cad(
    payload: AuditarPayload,
    background_tasks: BackgroundTasks,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """Fase 2 híbrida: lectura SW, DXF, Excel y SQL (macro manual previa; sin RunMacro2)."""
    global scan_status, abortar_escaneo_cad, cad_execution_logs, cad_procesar_status

    if not (payload.local_folder or "").strip():
        raise HTTPException(
            status_code=400,
            detail="local_folder es obligatorio y no puede estar vacío.",
        )

    busy_states = {"scanning", "collecting", "generating_excel"}
    if scan_status["status"] in busy_states or cad_procesar_status == "processing":
        return {"message": "Ya hay un proceso en curso. Cancélalo primero."}

    abortar_escaneo_cad = False
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    if os.path.exists(flag_path):
        try:
            os.remove(flag_path)
        except Exception:
            pass

    cad_execution_logs.clear()
    cad_procesar_status = "idle"

    actor_user = resolve_actor_user(authorization, x_usuario)
    background_tasks.add_task(
        bg_auditar_task,
        payload.local_folder,
        payload.solo_faltantes,
        payload.inyectar_propiedades,
        actor_user,
    )
    return {"message": "Fase 2 (auditar) iniciada en segundo plano"}

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


def _cad_sync_dataframe_to_maestro(
    df: pd.DataFrame,
    log_fn,
    actor_user: Optional[str] = None,
) -> Dict[str, int]:
    """Misma lógica que POST /api/cad/upload: escribe medidas en Tbl_Maestro_Piezas."""

    def _safe_float(val) -> Optional[float]:
        if val is None:
            return None
        try:
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
        s = re.sub(r'[^\d.\-]', '', s)
        if not s or s == '.':
            return None
        try:
            return float(s)
        except ValueError:
            return None

    def _sql_param_float(v: Optional[float]) -> Optional[float]:
        if v is None:
            return None
        return float(v)

    df = df.copy()
    df.columns = [str(c).strip() for c in df.columns]
    for _col_ignore in ("Largo_DXF", "Ancho_DXF"):
        if _col_ignore in df.columns:
            df = df.drop(columns=[_col_ignore])
    required_cols = ["Codigo_Pieza", "Largo_CAD", "Ancho_CAD"]
    for col in required_cols:
        if col not in df.columns:
            raise ValueError(f"Falta la columna requerida: {col}")

    actualizadas = 0
    ignoradas = 0
    no_encontradas = 0
    conn = get_db_connection()
    cursor = conn.cursor()
    usr_log = (actor_user or "").strip() or "Sistema"
    try:
        for index, row in df.iterrows():
            raw_codigo = row.get("Codigo_Pieza", "")
            codigo = str(raw_codigo).strip() if raw_codigo not in (None, '') else ''
            if not codigo or codigo.lower() in ('nan', 'none'):
                ignoradas += 1
                continue

            largo_float = _sql_param_float(_safe_float(row.get("Largo_CAD")))
            ancho_float = _sql_param_float(_safe_float(row.get("Ancho_CAD")))
            espesor_float = _sql_param_float(_safe_float(row.get("Espesor_Perfil_CAD")))

            raw_mat = row.get("Material", "")
            mat_clean = str(raw_mat).strip() if raw_mat not in (None, '') else ''
            if mat_clean.lower() in ('', 'nan', 'none', 'n/a'):
                material_str: Optional[str] = None
            else:
                material_str = mat_clean

            ruta_str = str(row.get("Ruta_Archivo", "") or "").strip()
            tiene_dxf = _sanitize_excel_si_no(row.get("Tiene_DXF"), default="NO")

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
                actualizadas += 1
                registrar_log_global(
                    cursor,
                    codigo,
                    "UPDATE_MEDIDAS_CAD",
                    "",
                    f"L:{largo_float}, A:{ancho_float}",
                    usr_log,
                )
            else:
                no_encontradas += 1
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    return {
        "actualizadas": actualizadas,
        "ignoradas": ignoradas,
        "no_encontradas": no_encontradas,
    }


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
                    usr_log = resolve_actor_user(authorization, x_usuario)
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
