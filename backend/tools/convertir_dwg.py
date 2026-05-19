import os
import re
import sys
import time
from typing import Optional

import win32com.client

_EXCLUDED_DIRS = {
    "dxf_convertidos",
    "exportados",
    "biblioteca_dxf",
    "dxf",
    "cad_pendientes",
    "reportes",
    "__pycache__",
    ".git",
    "node_modules",
    "venv",
    ".venv",
    "dist",
    "build",
}


def _path_has_obsoleto(path: str) -> bool:
    return "obsoleto" in path.replace("\\", "/").lower()


def limpiar_nombre(nombre_archivo):
    base = os.path.splitext(nombre_archivo)[0]
    return re.sub(r"(?i)chapa desplegada - ", "", base).strip()


# Misma regla que bg_preparar_task / bg_scan_cad_task en routers/cad.py
_SQL_EXCLUIR_COMERCIALES = """
    AND (LOWER(CAST(Material AS NVARCHAR(200))) NOT LIKE '%comercial%'
         OR Material IS NULL)
    AND (UPPER(LTRIM(RTRIM(ISNULL(CAST(Medida AS NVARCHAR(200)), '')))) <> 'COMERCIAL'
         OR Medida IS NULL)
"""


def _fetch_codigos_solo_faltantes_medidas():
    """Piezas del maestro sin medida CAD (Largo_CAD vacío/cero), no por Tiene_DXF."""
    _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _root not in sys.path:
        sys.path.insert(0, _root)
    from database import get_db_connection

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        f"""
        SELECT Codigo_Pieza
        FROM Tbl_Maestro_Piezas
        WHERE (
            Largo_CAD IS NULL
            OR LTRIM(RTRIM(CAST(Largo_CAD AS NVARCHAR(200)))) IN ('', '-', '0')
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
    out = set()
    for r in rows:
        if r and r[0] is not None:
            out.add(str(r[0]).strip().upper())
    return out


def _load_codigos_from_file(path: str):
    out = set()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            c = line.strip().upper()
            if c:
                out.add(c)
    return out


def _collect_dwg_rutas_mas_recientes(ruta_raiz):
    """Lista de rutas .dwg: excluye OBSOLETO; por clave limpiar_nombre (sin ext.) queda la de mayor getmtime."""
    candidatos = []
    for raiz, dirs, archivos in os.walk(ruta_raiz):
        dirs[:] = [
            d
            for d in dirs
            if d.lower() not in _EXCLUDED_DIRS
            and not d.startswith(".")
            and "obsoleto" not in d.lower()
        ]
        for archivo in archivos:
            if archivo.startswith("~$") or "obsoleto" in archivo.lower():
                continue
            if not archivo.lower().endswith(".dwg"):
                continue
            ruta_completa = os.path.join(raiz, archivo)
            if _path_has_obsoleto(ruta_completa):
                continue
            candidatos.append(ruta_completa)

    best = {}
    for ruta_completa in candidatos:
        archivo = os.path.basename(ruta_completa)
        clave = limpiar_nombre(archivo).strip().upper()
        try:
            mt = os.path.getmtime(ruta_completa)
        except OSError:
            continue
        prev = best.get(clave)
        if prev is None or mt > prev[0]:
            best[clave] = (mt, ruta_completa)
    return [t[1] for t in best.values()]


def _restart_autocad_com():
    """Mata acad.exe y crea una instancia COM nueva (recuperación tras colapso Open)."""
    os.system("taskkill /F /IM acad.exe /T 2>nul")
    time.sleep(2)
    acad = win32com.client.Dispatch("AutoCAD.Application")
    try:
        acad.Visible = False
    except Exception:
        pass
    try:
        acad.Preferences.System.DisplayOLEScale = False
    except Exception:
        pass
    return acad


def documents_open_with_retry(acad, dwg_path: str):
    """Abre un DWG; si Documents.Open falla (COM colapsado), reinicia AutoCAD y reintenta una vez.

    Returns:
        (document_or_None, acad_actualizado)
    """
    try:
        return acad.Documents.Open(dwg_path), acad
    except Exception as e:
        print(f" AutoCAD Open falló ({e!r}); taskkill + nueva instancia COM y reintento...")
        try:
            acad.Quit()
        except Exception:
            pass
        acad = _restart_autocad_com()
    try:
        return acad.Documents.Open(dwg_path), acad
    except Exception as e2:
        print(f" Open falló tras reinicio: {e2!r}")
        return None, acad


def procesar_biblioteca_dwg(
    ruta_raiz,
    solo_faltantes: bool = False,
    codigos_file: Optional[str] = None,
):
    ruta_raiz = ruta_raiz.strip('"').strip("'")
    ruta_destino = os.path.join(ruta_raiz, "dxf")

    allowed = None
    if codigos_file and os.path.isfile(codigos_file):
        try:
            allowed = _load_codigos_from_file(codigos_file)
            print(
                f"Modo solo faltantes: {len(allowed)} codigos "
                "(lista Fase 1, sin medidas en BD)."
            )
        except Exception as e:
            print(f"Aviso: no se pudo leer lista de codigos ({codigos_file}): {e}")
            allowed = None
    elif solo_faltantes:
        try:
            allowed = _fetch_codigos_solo_faltantes_medidas()
            print(
                f"Modo solo faltantes: {len(allowed)} codigos "
                "sin medidas (Largo_CAD) en BD."
            )
        except Exception as e:
            print(f"Aviso: no se pudo filtrar por BD (solo faltantes): {e}")
            allowed = None

    print("Limpiando procesos AutoCAD huérfanos...")
    os.system("taskkill /F /IM acad.exe /T 2>nul")

    try:
        acad = win32com.client.Dispatch("AutoCAD.Application")
        acad.Visible = False
        try:
            acad.Preferences.System.DisplayOLEScale = False
        except Exception:
            pass
    except Exception as e:
        print(f"Error: No se pudo abrir AutoCAD. {e}")
        return

    try:
        if not os.path.exists(ruta_destino):
            os.makedirs(ruta_destino)

        rutas_dwg = _collect_dwg_rutas_mas_recientes(ruta_raiz)
        for ruta_completa in rutas_dwg:
            archivo = os.path.basename(ruta_completa)
            nombre_limpio = limpiar_nombre(archivo)
            if allowed is not None and nombre_limpio.strip().upper() not in allowed:
                continue

            flag_path = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "abortar_cad.flag",
            )
            if os.path.exists(flag_path):
                print("Escaneo abortado por el usuario en AutoCAD.")
                return

            destino_dxf = os.path.join(ruta_destino, f"{nombre_limpio}.dxf")

            doc = None
            try:
                doc, acad = documents_open_with_retry(acad, ruta_completa)
                if doc is None:
                    print(f" Error al abrir (tras reintento): {archivo}")
                    continue
                doc.SaveAs(destino_dxf, 37)
                print(f" Procesado: {nombre_limpio}")
            except Exception as loop_e:
                print(f" Error al procesar el archivo {archivo}: {loop_e}")
            finally:
                try:
                    if doc:
                        doc.Close(False)
                except Exception:
                    pass

    finally:
        try:
            acad.Quit()
        except Exception:
            pass
        print(" Conversión DWG terminada.")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        carpeta_objetivo = sys.argv[1]
        extra = sys.argv[2:]
        solo = "--solo-faltantes" in extra
        codigos_file = None
        for i, arg in enumerate(extra):
            if arg == "--codigos-file" and i + 1 < len(extra):
                codigos_file = extra[i + 1]
                break
        procesar_biblioteca_dwg(
            carpeta_objetivo,
            solo_faltantes=solo,
            codigos_file=codigos_file,
        )
    else:
        print("Error: No se proporcionó ninguna ruta.")
