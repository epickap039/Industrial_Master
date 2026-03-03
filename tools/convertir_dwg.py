import os
import sys
import win32com.client # Librería para controlar AutoCAD

def limpiar_nombre(nombre_archivo):
    # Elimina el prefijo y extensiones
    nombre = nombre_archivo.replace("Chapa desplegada -", "").strip()
    return os.path.splitext(nombre)[0]

def procesar_biblioteca_dwg(ruta_raiz):
    # Conectar con la instancia de AutoCAD
    try:
        acad = win32com.client.Dispatch("AutoCAD.Application")
        acad.Visible = False # Mantener oculto para no estorbar
    except Exception as e:
        print(f"Error: No se pudo abrir AutoCAD. {e}")
        return

    for raiz, dirs, archivos in os.walk(ruta_raiz):
        for archivo in archivos:
            if archivo.lower().endswith(".dwg"):
                ruta_completa = os.path.join(raiz, archivo)
                nombre_limpio = limpiar_nombre(archivo)
                destino_dxf = os.path.join(raiz, f"{nombre_limpio}.dxf")

                try:
                    # Abrir, Guardar como DXF y Cerrar
                    doc = acad.Documents.Open(ruta_completa)
                    doc.SaveAs(destino_dxf, 37) # 37 es el código para DXF R2018
                    doc.Close(False)
                    print(f"✅ Procesado: {nombre_limpio}")
                except Exception as e:
                    print(f"❌ Error procesando {archivo}: {e}")

    try:
        acad.Quit()
    except: pass
    print("🚀 Conversión masiva terminada.")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        ruta = sys.argv[1]
    else:
        ruta = input("Ingresa la ruta absoluta de la carpeta de DWGs: ").strip()
        
    if ruta.startswith('"') and ruta.endswith('"'):
        ruta = ruta[1:-1]
        
    if os.path.isdir(ruta):
        procesar_biblioteca_dwg(ruta)
    else:
        print(f"Error: La ruta '{ruta}' no es válida.")
