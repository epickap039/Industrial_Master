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
from fastapi.responses import StreamingResponse
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
    """Por nombre base sin extensión (mismo código en distintas carpetas), conserva la ruta con mayor getmtime."""
    best: Dict[str, tuple[float, str]] = {}
    for p in paths:
        try:
            stem = os.path.splitext(os.path.basename(p))[0]
            key = stem.lower()
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


def _export_reporte_cad(df: pd.DataFrame, report_path: str) -> None:
    """Exporta xlsx (UTF-16 interno en XML vía openpyxl) y CSV con BOM para Excel en Windows."""
    df.to_excel(report_path, index=False, engine="openpyxl")
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

@router.post("/api/cad/abort")
def abort_cad():
    global abortar_escaneo_cad, scan_status
    abortar_escaneo_cad = True
    scan_status["status"] = "cancelled"
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    with open(flag_path, "w") as f:
        f.write("abort")
    return {"status": "aborting"}

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
                    codigo_pieza = os.path.splitext(f)[0]
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
                    """
                    SELECT Codigo_Pieza
                    FROM Tbl_Maestro_Piezas
                    WHERE Largo_CAD IS NULL
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = ''
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = '-'
                       OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) = '0'
                       OR (
                            TRY_CAST(Largo_CAD AS FLOAT) IS NOT NULL
                            AND TRY_CAST(Largo_CAD AS FLOAT) = 0
                          )
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
                    f"[CAD] solo_faltantes: {len(faltantes_norm)} codigos en maestro sin medida, "
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
            """Fuerza el modo silencioso completo en la instancia SW para evitar
            que el proceso intente renderizar diÃ¡logos UI en segundo plano."""
            try:
                app.Visible = False
            except Exception:
                pass
            try:
                # Desconecta la instancia del control de usuario (evita diÃ¡logos interactivos)
                app.UserControl = False
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
                # Background extremo: evitar UI y pop-ups.
                try:
                    app.Visible = False
                except Exception:
                    pass
                # Modo silencioso: desconecta UI para evitar pop-ups al cerrar documentos.
                app.UserControl = False
                _apply_silent_mode(app)
                print("[SW] Instancia COM aislada (DispatchEx) inicializada en modo silencioso.")
                return app
            except Exception as e:
                print(f"ADVERTENCIA: Motor SolidWorks inaccesible: {e}")
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

        def _sldprt_extract_one(sw_local, abspath, codigo, nombre_archivo, ruta_abs):
            """Procesa una pieza SolidWorks en el MISMO hilo que creó sw_local (reglas COM)."""
            largo_cad = 0.0
            ancho_cad = 0.0
            espesor_cad = 0.0
            observacion = ""
            if not ruta_abs.upper().endswith(".SLDPRT"):
                print(f"[SW] Omitido por filtro: {ruta_abs}")
                return {
                    "codigo": _ascii_report_text(codigo),
                    "largo_cad": largo_cad,
                    "ancho_cad": ancho_cad,
                    "espesor_cad": espesor_cad,
                    "observacion": _ascii_report_text("Omitido (no es .SLDPRT)"),
                    "rpc_continue": False,
                }

            swDocPART = 1
            SW_OPEN_SILENT = 1
            arg_errors = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
            arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
            swModel = None
            try:
                swModel = sw_local.OpenDoc6(
                    ruta_abs,
                    swDocPART,
                    SW_OPEN_SILENT,
                    "",
                    arg_errors,
                    arg_warnings,
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
                    print(f"[SW-RPC] Crash RPC detectado en '{codigo}' (hresult={err_code}). Iniciando resurrección COM...")
                    import logging as _logging
                    _logging.error(f"[SW-RPC] Crash en '{ruta_abs}': {err_str}")
                    scan_status["warning_message"] = f"⚠️ Saltado por versión: {nombre_archivo}"
                    _resurrect_solidworks_com_after_kill()
                    return {
                        "rpc_continue": True,
                        "codigo": _ascii_report_text(codigo),
                        "largo_cad": 0.0,
                        "ancho_cad": 0.0,
                        "espesor_cad": 0.0,
                        "observacion": _ascii_report_text(
                            "ERROR RPC: Archivo de version anterior o corrupto. "
                            "Primero actualiza/guarda la pieza manualmente en esta version."
                        ),
                    }
                print(f"[SW] Error abriendo '{codigo}': {err_str}")
                observacion = f"Error apertura: {str(try_open_err)[:60]}"
                swModel = None

            if swModel is None:
                if not observacion.startswith("Error apertura"):
                    largo_cad = 0.0
                    ancho_cad = 0.0
                    observacion = (
                        "ERROR: Archivo de version mas reciente. "
                        "Actualiza SolidWorks en esta computadora."
                    )
                    scan_status["warning_message"] = f"⚠️ Saltado por versión: {nombre_archivo}"
            else:
                scan_status["warning_message"] = ""
                try:
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

                    get_codigo = prop_mgr.Get("CODIGO_PIEZA")
                    codigo_val = safe_get_prop(get_codigo).strip()
                    if codigo_val:
                        codigo = codigo_val

                    get_largo = prop_mgr.Get("Largo_CAD")
                    get_ancho = prop_mgr.Get("Ancho_CAD")
                    get_espesor = prop_mgr.Get("Espesor_Perfil_CAD")

                    largo_val = safe_get_prop(get_largo)
                    ancho_val = safe_get_prop(get_ancho)
                    espesor_val = safe_get_prop(get_espesor)

                    if largo_val and ancho_val:
                        try:
                            l_clean = str(largo_val).lower().replace("mm", "").strip().replace(",", ".")
                            a_clean = str(ancho_val).lower().replace("mm", "").strip().replace(",", ".")
                            l_str = re.sub(r"[^\d.]", "", l_clean)
                            a_str = re.sub(r"[^\d.]", "", a_clean)

                            largo = float(l_str) if l_str and l_str != "." else 0.0
                            ancho = float(a_str) if a_str and a_str != "." else 0.0

                            largo_cad = max(largo, ancho)
                            ancho_cad = min(largo, ancho)

                            espesor_cad = 0.0
                            if espesor_val:
                                e_clean = str(espesor_val).lower().replace("mm", "").strip().replace(",", ".")
                                e_str = re.sub(r"[^\d.]", "", e_clean)
                                espesor_cad = float(e_str) if e_str and e_str != "." else 0.0

                            if largo_cad > 0 and ancho_cad > 0:
                                observacion = "OK"
                            else:
                                observacion = "No detectado (valores incompletos)"
                        except ValueError as ve:
                            observacion = f"Error metrico: {ve}"
                    else:
                        observacion = "No detectado (faltan propiedades)"

                except Exception as math_err:
                    observacion = f"Error matematico: {str(math_err)[:50]}"
                    print(f"Error matematico extrayendo {codigo}: {math_err}")
                finally:
                    try:
                        doc_title = None
                        try:
                            if swModel is not None:
                                doc_title = swModel.GetTitle()
                                try:
                                    swModel.SetSaveFlag(False)
                                except Exception:
                                    pass
                        except Exception:
                            doc_title = None

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

            return {
                "rpc_continue": False,
                "codigo": _ascii_report_text(codigo),
                "largo_cad": largo_cad,
                "ancho_cad": ancho_cad,
                "espesor_cad": espesor_cad,
                "observacion": _ascii_report_text(observacion),
            }

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
                                    }
                                    return
                                piece_box["out"] = _sldprt_extract_one(
                                    sw_local, abspath, codigo, nombre_archivo, ruta_abs
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
                        
            except Exception as extract_err:
                import traceback
                if not observacion:
                    observacion = f"Error: {str(extract_err)[:50]}"
                print(f"âŒ Error leyendo {abspath}: {str(extract_err)}")
                traceback.print_exc()

            # LÃ³gica de DXF (AuditorÃ­a Cruzada 2D)
            dxf_path = os.path.join(root_path, "BIBLIOTECA_DXF", f'{info["codigo"]}.dxf')
            if not os.path.exists(dxf_path) and codigo != info["codigo"]:
                dxf_path_alt = os.path.join(root_path, "BIBLIOTECA_DXF", f'{codigo}.dxf')
                if os.path.exists(dxf_path_alt):
                    dxf_path = dxf_path_alt

            if os.path.exists(dxf_path):
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
            df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"]]

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
                df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"]]
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

from fastapi.responses import FileResponse
import math

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
                largo_dxf_f    = _sql_param_float(_safe_float(row.get("Largo_DXF")))
                ancho_dxf_f    = _sql_param_float(_safe_float(row.get("Ancho_DXF")))

                print(
                    f"[upload_cad] {codigo} | "
                    f"L={largo_float} A={ancho_float} E={espesor_float} "
                    f"Mat={material_str!r}"
                )

                # â”€â”€ UPDATE con Material condicional â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                # Si el Excel no trae Material vÃ¡lido NO sobreescribimos la BD,
                # para no borrar el dato que ya existe correctamente.
                if material_str is not None:
                    cursor.execute("""
                        UPDATE Tbl_Maestro_Piezas
                        SET Largo_CAD         = ?,
                            Ancho_CAD         = ?,
                            Espesor_Perfil_CAD = ?,
                            Material          = ?,
                            Ruta_Archivo      = ?,
                            Tiene_DXF         = ?,
                            Largo_DXF         = ?,
                            Ancho_DXF         = ?
                        WHERE Codigo_Pieza = ?
                    """, (
                        largo_float, ancho_float, espesor_float,
                        material_str, ruta_str,
                        tiene_dxf, largo_dxf_f, ancho_dxf_f,
                        codigo,
                    ))
                else:
                    # Material vacÃ­o en Excel â†’ no tocar columna Material en BD
                    cursor.execute("""
                        UPDATE Tbl_Maestro_Piezas
                        SET Largo_CAD          = ?,
                            Ancho_CAD          = ?,
                            Espesor_Perfil_CAD  = ?,
                            Ruta_Archivo       = ?,
                            Tiene_DXF          = ?,
                            Largo_DXF          = ?,
                            Ancho_DXF          = ?
                        WHERE Codigo_Pieza = ?
                    """, (
                        largo_float, ancho_float, espesor_float,
                        ruta_str, tiene_dxf, largo_dxf_f, ancho_dxf_f,
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
                """
                SELECT Codigo_Pieza
                FROM Tbl_Maestro_Piezas
                WHERE Ruta_Archivo IS NULL
                   OR LTRIM(RTRIM(CAST(Ruta_Archivo AS NVARCHAR(400)))) = ''
                   OR LTRIM(RTRIM(CAST(Ruta_Archivo AS NVARCHAR(400)))) = '-'
                """
            )
            rows_sin_ruta = cursor.fetchall()
            piezas_sin_ruta = set()
            for row in rows_sin_ruta:
                if row[0]:
                    piezas_sin_ruta.add(str(row[0]).strip().upper())

            cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas")
            rows_cat = cursor.fetchall()
            catalogo_codigos = set()
            for row in rows_cat:
                if row[0]:
                    catalogo_codigos.add(str(row[0]).strip().upper())

            piezas_faltantes: set = set()
        else:
            query = """
                SELECT Codigo_Pieza 
                FROM Tbl_Maestro_Piezas 
                WHERE Largo_CAD IS NULL 
                   OR CAST(Largo_CAD AS VARCHAR) = '' 
                   OR CAST(Largo_CAD AS VARCHAR) = '-'
                   OR CAST(Largo_CAD AS VARCHAR) = '0'
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
            base_name = file[:-(len(ext)+1)].strip().upper()
            base_name = base_name.replace("CHAPA DESPLEGADA - ", "").strip()

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
