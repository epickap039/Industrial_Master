import os
import sys
import win32com.client

_EXCLUDED_DIRS = {
    "dxf_convertidos",
    "exportados",
    "biblioteca_dxf",
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
    nombre = nombre_archivo.replace("Chapa desplegada -", "").strip()
    return os.path.splitext(nombre)[0]


def _fetch_codigos_solo_faltantes_dxf():
    _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if _root not in sys.path:
        sys.path.insert(0, _root)
    from database import get_db_connection

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT Codigo_Pieza
        FROM Tbl_Maestro_Piezas
        WHERE Tiene_DXF IS NULL
           OR LTRIM(RTRIM(UPPER(CAST(Tiene_DXF AS NVARCHAR(50))))) IN ('', 'NO', 'N')
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


def procesar_biblioteca_dwg(ruta_raiz, solo_faltantes: bool = False):
    ruta_raiz = ruta_raiz.strip('"').strip("'")
    ruta_destino = os.path.join(ruta_raiz, "BIBLIOTECA_DXF")

    allowed = None
    if solo_faltantes:
        try:
            allowed = _fetch_codigos_solo_faltantes_dxf()
            print(f"Modo solo faltantes: {len(allowed)} codigos sin DXF en BD.")
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
                doc = acad.Documents.Open(ruta_completa)
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
        solo = "--solo-faltantes" in sys.argv[2:]
        procesar_biblioteca_dwg(carpeta_objetivo, solo_faltantes=solo)
    else:
        print("Error: No se proporcionó ninguna ruta.")
