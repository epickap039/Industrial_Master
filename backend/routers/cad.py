"""API router: escáner CAD."""
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
import traceback
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

# Raíz `backend/` (equivalente a cuando server.py monolítico vivía ahí; flags y tools/ siguen igual)
_BACKEND_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# === MÓDULO: ESCÁNER CAD (Fase 1) ===

try:
    import ezdxf
    import win32com.client
    import pythoncom
    print("Módulos CAD asíncronos (ezdxf, win32com, pythoncom) importados exitosamente.")
except ImportError as e:
    raise RuntimeError(f"LIBRERÍA FALTANTE: Asegúrate de correr 'pip install ezdxf pywin32'. Error: {e}")

scan_status = {
    "progress": 0,
    "total": 0,
    "status": "idle",
    "excel_path": "",
    "error": ""
}
abortar_escaneo_cad = False

@router.post("/api/cad/abort")
def abort_cad():
    global abortar_escaneo_cad, scan_status
    abortar_escaneo_cad = True
    scan_status["status"] = "cancelled"
    flag_path = os.path.join(_BACKEND_ROOT, "abortar_cad.flag")
    with open(flag_path, "w") as f:
        f.write("abort")
    return {"status": "aborting"}

def bg_scan_cad_task(root_path: str):
    global scan_status, abortar_escaneo_cad
    import datetime
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
    
    # Búsqueda de archivos
    cad_files = {} # Key: filename without extension, Value: dict of details
    
    extensions_to_look = {".sldprt"}
    
    try:
        processed_count = 0
        for dirpath, _, filenames in os.walk(root_path):
            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                break
            
            for f in filenames:
                if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                    break
                    
                if f.startswith("~$"):
                    continue
                    
                ext = os.path.splitext(f)[1].lower()
                if ext in extensions_to_look:
                    codigo_pieza = os.path.splitext(f)[0]
                    abspath = os.path.join(dirpath, f)
                    
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
        
        # Generar Excel y extraer metadata CAD
        data = []
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
            
        def _apply_silent_mode(app):
            """Fuerza el modo silencioso completo en la instancia SW para evitar
            que el proceso intente renderizar diálogos UI en segundo plano."""
            try:
                app.Visible = False
            except Exception:
                pass
            try:
                # Desconecta la instancia del control de usuario (evita diálogos interactivos)
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
                # Suprime advertencias de reconstrucción y referencias rotas
                app.SetUserPreferenceToggle(262, True)
            except Exception:
                pass

        def get_sw_app():
            try:
                app = win32com.client.Dispatch("SldWorks.Application")
                _apply_silent_mode(app)
                print("[SW] Instancia COM inicializada en modo silencioso.")
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

        has_sldprt = any(info["ext"] == ".sldprt" for info in cad_files.values())
        sw_app = get_sw_app() if has_sldprt else None
        
        has_dwg = any(info["ext"] == ".dwg" for info in cad_files.values())
        acad_app = get_acad_app() if has_dwg else None
                
        total_a_extraer = len(cad_files)
        extraidos = 0
        scan_status["total"] = total_a_extraer
        
        print(f"=== INICIANDO EXTRACCIÓN CAD ({total_a_extraer} archivos únicos) ===")

        for info in cad_files.values():
            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                import logging
                logging.info("Escaneo abortado por el usuario.")
                if sw_app: 
                    try: sw_app.ExitApp()
                    except: pass
                if acad_app:
                    try: acad_app.Quit()
                    except: pass
                scan_status["status"] = "cancelled"
                break

            dt = datetime.datetime.fromtimestamp(info["mtime"]).strftime("%Y-%m-%d %H:%M:%S")
            ext = info["ext"]
            abspath = info["abspath"]
            codigo = info["codigo"]
            
            # FIX: Inicializar TODAS las variables antes del try para evitar UnboundLocalError
            largo_cad = 0.0
            ancho_cad = 0.0
            espesor_cad = 0.0
            observacion = ""
            tiene_dxf = "No"
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
                        observacion = "No extraído (Error AutoCAD COM)"
                    finally:
                        try:
                            doc.Close(False)
                        except: pass
                        
                elif ext == ".dwg" and not acad_app:
                    observacion = "Requiere AutoCAD Instalado"
                    print(f"⚠️ DWG omitido: Sin conexión a AutoCAD COM -> {abspath}")

                elif ext == ".sldprt" and sw_app:
                    # FIX: Inicializar flags COM fuera de ramas para evitar NameError
                    _rpc_crash = False
                    swModel = None
                    # FIX: Filtro estricto — solo procesar archivos .SLDPRT reales
                    ruta_abs = os.path.abspath(abspath)
                    if not ruta_abs.upper().endswith(".SLDPRT"):
                        observacion = "Omitido (no es .SLDPRT)"
                        print(f"[SW] Omitido por filtro: {ruta_abs}")
                    else:
                        # ---- Apertura Silenciosa y Segura con OpenDoc6 ----
                        # Flags de la API de SolidWorks:
                        #   swDocPART               = 1  (tipo de documento: Part)
                        #   swOpenDocOptions_Silent  = 1  (sin diálogos)
                        #   swOpenDocOptions_ReadOnly= 2  (solo lectura)
                        #   silentMode = 1 | 2 = 3
                        swDocPART = 1
                        swSilentReadOnly = 1 | 2

                        # FIX TYPE MISMATCH: Usar VARIANTs tipados (VT_BYREF|VT_I4)
                        # para evitar com_error(-2147352571, 'Los tipos no coinciden').
                        # pywin32 requiere que los parámetros ByRef sean Variant explícitos.
                        arg_errors   = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
                        arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)

                        _rpc_crash = False
                        swModel = None
                        try:
                            # OpenDoc6(FileName, Type, Options, Configuration, Errors, Warnings)
                            swModel = sw_app.OpenDoc6(
                                ruta_abs,
                                swDocPART,
                                swSilentReadOnly,  # Options: Silent + ReadOnly
                                "",               # Configuration (vacío = default)
                                arg_errors,        # Errors  (ByRef VARIANT I4)
                                arg_warnings       # Warnings (ByRef VARIANT I4)
                            )
                        except Exception as try_open_err:
                            err_str = repr(try_open_err)
                            err_code = getattr(try_open_err, 'hresult', None)

                            # ---- Auto-Resurrección COM (RPC Crash -2147023170) ----
                            is_rpc_crash = (
                                "-2147023170" in err_str
                                or (err_code is not None and err_code == -2147023170)
                            )

                            if is_rpc_crash:
                                print(f"[SW-RPC] ⚡ Crash RPC detectado en '{codigo}'. Iniciando resurrección COM...")
                                import logging as _logging
                                _logging.error(f"[SW-RPC] Crash en '{ruta_abs}': {err_str}")

                                # 1. Asesinar el proceso SW muerto
                                try:
                                    os.system("taskkill /F /IM SLDWORKS.exe 2>nul")
                                except Exception:
                                    pass

                                # 2. Liberar referencia COM muerta
                                sw_app = None

                                # 3. Pequeña pausa para que el SO libere el puerto RPC
                                import time as _time
                                _time.sleep(3)

                                # 4. Re-inicializar COM y reconectar a SolidWorks
                                try:
                                    pythoncom.CoUninitialize()
                                except Exception:
                                    pass
                                try:
                                    pythoncom.CoInitialize()
                                except Exception:
                                    pass
                                sw_app = get_sw_app()  # get_sw_app ya aplica _apply_silent_mode

                                if sw_app:
                                    print("[SW-RPC] ✅ Resurrección COM exitosa. Continuando con el siguiente archivo.")
                                else:
                                    print("[SW-RPC] ❌ No se pudo reconectar a SolidWorks. El escáner continuará sin motor SW.")

                                observacion = "Error/Saltado (RPC Crash - COM Reiniciado)"
                                _rpc_crash = True
                            else:
                                # Error de apertura no-RPC (archivo corrupto, falta de permiso, etc.)
                                print(f"[SW] Error abriendo '{codigo}': {err_str}")
                                observacion = f"Error apertura: {str(try_open_err)[:60]}"
                                swModel = None

                    if not _rpc_crash:
                        # Solo procesamos si NO hubo crash RPC
                        if swModel is None:
                            observacion = "No se pudo abrir el archivo"
                            # No lanzamos excepción para que permita llenar el DataFrame en blanco
                        else:
                            try:
                                prop_mgr = swModel.Extension.CustomPropertyManager("")
                                
                                def safe_get_prop(prop_val):
                                    if not prop_val: return ""
                                    if isinstance(prop_val, str): return prop_val
                                    if isinstance(prop_val, (tuple, list)):
                                        if len(prop_val) > 1 and prop_val[1]: return str(prop_val[1])
                                        if len(prop_val) > 0 and prop_val[0]: return str(prop_val[0])
                                    return str(prop_val)

                                # Intentar sobrescribir codigo pieza si está en custom properties
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
                                    import re
                                    try:
                                        l_clean = str(largo_val).lower().replace("mm", "").strip().replace(',', '.')
                                        a_clean = str(ancho_val).lower().replace("mm", "").strip().replace(',', '.')
                                        l_str = re.sub(r'[^\d.]', '', l_clean)
                                        a_str = re.sub(r'[^\d.]', '', a_clean)
                                        
                                        largo = float(l_str) if l_str and l_str != '.' else 0.0
                                        ancho = float(a_str) if a_str and a_str != '.' else 0.0
                                        
                                        largo_cad = max(largo, ancho)
                                        ancho_cad = min(largo, ancho)
                                        
                                        espesor_cad = 0.0
                                        if espesor_val:
                                            e_clean = str(espesor_val).lower().replace("mm", "").strip().replace(',', '.')
                                            e_str = re.sub(r'[^\d.]', '', e_clean)
                                            espesor_cad = float(e_str) if e_str and e_str != '.' else 0.0
                                        
                                        if largo_cad > 0 and ancho_cad > 0:
                                            observacion = "OK"
                                        else:
                                            observacion = "No detectado (valores incompletos)"
                                    except ValueError as ve:
                                        observacion = f"Error métrico: {ve}"
                                else:
                                    observacion = "No detectado (faltan propiedades)"
                                    
                            except Exception as math_err:
                                observacion = f"Error matemático: {str(math_err)[:50]}"
                                print(f"Error matemático extrayendo {codigo}: {math_err}")
                            finally:
                                try:
                                    sw_app.CloseDoc(abspath)
                                except: pass
                        
            except Exception as extract_err:
                import traceback
                if not observacion:
                    observacion = f"Error: {str(extract_err)[:50]}"
                print(f"❌ Error leyendo {abspath}: {str(extract_err)}")
                traceback.print_exc()

            # Lógica de DXF (Auditoría Cruzada 2D)
            dxf_path = os.path.join(root_path, "BIBLIOTECA_DXF", f'{info["codigo"]}.dxf')
            if not os.path.exists(dxf_path) and codigo != info["codigo"]:
                dxf_path_alt = os.path.join(root_path, "BIBLIOTECA_DXF", f'{codigo}.dxf')
                if os.path.exists(dxf_path_alt):
                    dxf_path = dxf_path_alt

            if os.path.exists(dxf_path):
                tiene_dxf = "Sí"
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
                        largo_dxf = round(lx, 2)
                        ancho_dxf = round(ax, 2)
                except Exception as dxf_err:
                    print(f"Error parseando DXF {dxf_path}: {dxf_err}")

            data.append({
                "Codigo_Pieza": codigo,
                "Extension": ext,
                "Largo_CAD": round(largo_cad, 2) if largo_cad > 0 else "",
                "Ancho_CAD": round(ancho_cad, 2) if ancho_cad > 0 else "",
                "Espesor_Perfil_CAD": round(espesor_cad, 2) if espesor_cad > 0 else "",
                "Material": "",
                "Observaciones": observacion if observacion else "No detectado",
                "Tiene_DXF": tiene_dxf,
                "Largo_DXF": largo_dxf,
                "Ancho_DXF": ancho_dxf,
                "Ruta_Archivo": abspath
            })
            extraidos += 1
            scan_status["progress"] = extraidos
            
        print("=== EXTRACCIÓN CAD FINALIZADA ===")
        if sw_app:
            try: sw_app.ExitApp()
            except: pass
        if acad_app:
            try: acad_app.Quit()
            except: pass
            
        df = pd.DataFrame(data)
        if df.empty:
            df = pd.DataFrame(columns=["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"])
        else:
             df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"]]
            
        reports_dir = os.path.join(os.getcwd(), "reportes")
        os.makedirs(reports_dir, exist_ok=True)
        report_filename = f"Reporte_CAD.xlsx"
        report_path = os.path.join(reports_dir, report_filename)
        
        df.to_excel(report_path, index=False)
        
        scan_status["status"] = "completed"
        scan_status["excel_path"] = report_path
        
    except Exception as e:
        scan_status["status"] = "error"
        scan_status["error"] = str(e)


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
         
    background_tasks.add_task(bg_scan_cad_task, payload.root_path)
    return {"message": "Escaneo iniciado en segundo plano"}

import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

cad_execution_logs = []
cad_procesar_status = "idle"

def bg_procesar_cad_task(ruta_raiz: str):
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
        log_and_append(f"Error: No se encontró el script DWG en la ruta absoluta: {script_dwg}")
    else:
        try:
            log_and_append("Ejecutando convertir_dwg.py...")
            process = subprocess.Popen(
                [sys.executable, script_dwg, ruta_raiz],
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
            log_and_append(f"convertir_dwg.py terminó (código {process.returncode})")
        except Exception as e:
            log_and_append(f"Error al ejecutar convertir_dwg.py: {e}")
            
    if not os.path.exists(script_sw):
        log_and_append(f"Error: No se encontró el script SolidWorks en la ruta absoluta: {script_sw}")
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
            log_and_append(f"preparar_solidworks.py terminó (código {process.returncode})")
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
    
    background_tasks.add_task(bg_procesar_cad_task, payload.root_path)
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
         
    # ── Helper de casteo seguro ───────────────────────────────────────────────
    def _safe_float(val) -> Optional[float]:
        """Convierte cualquier valor de celda Pandas a float o None.

        Casos cubiertos:
          - NaN (pandas.NA, float('nan'), 'nan', 'NaN') → None
          - cadena vacía '' / solo espacios             → None
          - cadena numérica '125.5'                     → 125.5
          - entero/float directo                         → float(val)
          - cualquier otro error de conversión           → None
        """
        if val is None:
            return None
        try:
            if isinstance(val, float) and math.isnan(val):
                return None
        except Exception:
            pass
        s = str(val).strip().lower()
        if s in ('', 'nan', 'none', '-', 'n/a'):
            return None
        # Limpiar comas como separador decimal (e.g. '1.234,56' → no aplica aquí)
        s = s.replace(',', '.')
        # Eliminar caracteres no numéricos salvo punto y signo
        import re as _re
        s = _re.sub(r'[^\d.\-]', '', s)
        if not s or s == '.':
            return None
        try:
            return float(s)
        except ValueError:
            return None

    try:
        contents = await file.read()
        df = pd.read_excel(io.BytesIO(contents))

        # ── Limpieza global del DataFrame ─────────────────────────────────────
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
                # ── Código de pieza ──────────────────────────────────────────
                raw_codigo = row.get("Codigo_Pieza", "")
                codigo = str(raw_codigo).strip() if raw_codigo not in (None, '') else ''
                if not codigo or codigo.lower() in ('nan', 'none'):
                    ignoradas += 1
                    continue

                # ── Dimensiones CAD — casteo seguro a float|None ─────────────
                # CRÍTICO: str(NaN) → 'nan' → float('nan') pasa como valor
                # inválido al SQL. _safe_float convierte eso a None explícito.
                largo_float   = _safe_float(row.get("Largo_CAD"))
                ancho_float   = _safe_float(row.get("Ancho_CAD"))
                espesor_float = _safe_float(row.get("Espesor_Perfil_CAD"))

                # ── Material — garantizar nunca vacío en BD ───────────────────
                # El reporte CAD genera Material='' porque SW no tiene ese campo.
                # Aplicamos la misma regla que en excel.py: "" → "POR DEFINIR".
                raw_mat = row.get("Material", "")
                mat_clean = str(raw_mat).strip() if raw_mat not in (None, '') else ''
                if mat_clean.lower() in ('', 'nan', 'none', 'n/a'):
                    mat_clean = ''  # Dejar que la BD conserve lo que ya tiene
                    material_str: Optional[str] = None  # No sobreescribir
                else:
                    material_str = mat_clean

                # ── Campos auxiliares ─────────────────────────────────────────
                ruta_str       = str(row.get("Ruta_Archivo", "") or "").strip()
                tiene_dxf      = str(row.get("Tiene_DXF", "No") or "No").strip()
                largo_dxf_f    = _safe_float(row.get("Largo_DXF"))
                ancho_dxf_f    = _safe_float(row.get("Ancho_DXF"))

                print(
                    f"[upload_cad] {codigo} | "
                    f"L={largo_float} A={ancho_float} E={espesor_float} "
                    f"Mat={material_str!r}"
                )

                # ── UPDATE con Material condicional ───────────────────────────
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
                    # Material vacío en Excel → no tocar columna Material en BD
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
            print("=== ESCRITURA FINALIZADA CON ÉXITO ===")
            
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

        
class CollectRequest(BaseModel):
    source_folder: str

@router.post("/api/cad/collect-missing")
def collect_missing_cad(request: CollectRequest):
    try:
        # 1. Consulta SQL Blindada (Todo convertido a texto para evitar Crash 8114)
        query = """
            SELECT Codigo_Pieza 
            FROM Tbl_Maestro_Piezas 
            WHERE Largo_CAD IS NULL 
               OR CAST(Largo_CAD AS VARCHAR) = '' 
               OR CAST(Largo_CAD AS VARCHAR) = '-'
               OR CAST(Largo_CAD AS VARCHAR) = '0'
        """
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute(query)
        rows = cursor.fetchall()
        
        piezas_faltantes = set()
        for row in rows:
            if row[0]:
                piezas_faltantes.add(str(row[0]).strip().upper())
        
        cursor.close()
        conn.close()

        # 2. Preparar carpeta en el Escritorio
        desktop = os.path.join(os.environ['USERPROFILE'], 'Desktop')
        target_folder = os.path.join(desktop, 'CAD_PENDIENTES')
        if not os.path.exists(target_folder):
            os.makedirs(target_folder)

        # 3. Recorrer la red y copiar
        archivos_copiados = 0
        for root_dir, dirs, files in os.walk(request.source_folder):
            for file in files:
                ext = file.split('.')[-1].upper()
                if ext in ['SLDPRT', 'DWG', 'DXF']:
                    # Extraer el nombre base (sin extensión)
                    base_name = file[:-(len(ext)+1)].strip().upper()
                    # Limpiar prefijo de chapa por si acaso
                    base_name = base_name.replace("CHAPA DESPLEGADA - ", "").strip()
                    
                    if base_name in piezas_faltantes:
                        source_path = os.path.join(root_dir, file)
                        target_path = os.path.join(target_folder, file)
                        
                        # Copiar solo si no existe ya en el destino
                        if not os.path.exists(target_path):
                            shutil.copy2(source_path, target_path)
                            archivos_copiados += 1

        return {
            "piezas_faltantes_en_db": len(piezas_faltantes),
            "archivos_encontrados": archivos_copiados,
            "destino": target_folder
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error durante la recolección: {str(e)}")

