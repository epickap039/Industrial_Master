import os
import sys
import win32com.client

def limpiar_nombre(nombre_archivo):
    nombre = nombre_archivo.replace("Chapa desplegada -", "").strip()
    return os.path.splitext(nombre)[0]

def procesar_biblioteca_dwg(ruta_raiz):
    # Limpiamos comillas extra que pueda mandar la terminal
    ruta_raiz = ruta_raiz.strip('"').strip("'")
    ruta_destino = os.path.join(ruta_raiz, "BIBLIOTECA_DXF")

    # Limpieza de procesos huérfanos de AutoCAD para evitar errores de COM fantasma
    print("Limpiando procesos AutoCAD huérfanos...")
    os.system("taskkill /F /IM acad.exe /T 2>nul")

    try:
        acad = win32com.client.Dispatch("AutoCAD.Application")
        acad.Visible = False
        try:
            acad.Preferences.System.DisplayOLEScale = False
        except:
            pass
    except Exception as e:
        print(f"Error: No se pudo abrir AutoCAD. {e}")
        return

    try:
        if not os.path.exists(ruta_destino):
            os.makedirs(ruta_destino)

        for raiz, dirs, archivos in os.walk(ruta_raiz):
            for archivo in archivos:
                if archivo.lower().endswith(".dwg"):
                    ruta_completa = os.path.join(raiz, archivo)
                    nombre_limpio = limpiar_nombre(archivo)
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
                        except:
                            pass
                        
    finally:
        # Siempre intentamos cerrar AutoCAD, pase lo que pase con los DWG
        try:
            acad.Quit()
        except:
            pass
        print(" Conversión DWG terminada.")

if __name__ == "__main__":
    # Atrapa la ruta que envía FastAPI
    if len(sys.argv) > 1:
        carpeta_objetivo = sys.argv[1]
        procesar_biblioteca_dwg(carpeta_objetivo)
    else:
        print("Error: No se proporcionó ninguna ruta.")