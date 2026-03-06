import sys

if __name__ == "__main__":
    if len(sys.argv) > 1:
        ruta_raiz = sys.argv[1]
        print(f"Aviso: La ruta {ruta_raiz} fue recibida.")
        print("Para extraer medidas de SolidWorks, recuerda ejecutar la Macro Híbrida en SW.")
    else:
        print("Error: No se proporcionó ninguna ruta.")