import os
import sys

def main():
    print("=========================================================")
    print("   UTILERÍA DE PREPARACIÓN DE BOUNDING BOX (SolidWorks)  ")
    print("=========================================================")
    
    folder_path = input("Ingresa la ruta absoluta de la carpeta de prueba: ").strip()
    
    # Limpiar comillas si el usuario arrastra y suelta la carpeta en la consola
    if folder_path.startswith('"') and folder_path.endswith('"'):
        folder_path = folder_path[1:-1]
        
    if not os.path.isdir(folder_path):
        print(f"\n[X] Error: La ruta '{folder_path}' no existe o no es un directorio.")
        return
        
    print(f"\nEscaneando '{folder_path}' en busca de piezas .SLDPRT...")
    
    sldprt_files = []
    for root, dirs, files in os.walk(folder_path):
        for file in files:
            if file.lower().endswith('.sldprt') and not file.startswith('~$'):
                sldprt_files.append(os.path.join(root, file))
                
    if not sldprt_files:
        print("\n[!] No se encontraron piezas .SLDPRT en la carpeta proporcionada.")
        return
        
    print(f"\nSe encontraron [{len(sldprt_files)}] piezas para inyectar Bounding Box.")
    
    confirm = input("¿Deseas modificar estos archivos y guardarlos? (Y/N): ").strip().upper()
    
    if confirm != 'Y':
        print("\nOperación cancelada por el usuario.")
        return
        
    print("\nIniciando motor de SolidWorks en segundo plano (Auto-sanación)...")
    try:
        import win32com.client
        import pythoncom
    except ImportError:
        print("\n[X] Error: Faltan dependencias. Primero ejecuta: pip install pywin32")
        return
        
    try:
        swApp = win32com.client.dynamic.Dispatch("SldWorks.Application")
        swApp.Visible = False
    except Exception as e:
        print(f"\n[X] Error fatal: No se pudo conectar a SolidWorks COM. ¿Está instalado? Detalle: {e}")
        return
        
    exitos = 0
    errores = 0
    
    print("\n--- INICIANDO PROCESAMIENTO ---")
    
    for abspath in sldprt_files:
        filename = os.path.basename(abspath)
        try:
            arg_errors = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
            arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
            
            # Abrir archivo silenciosamente EN MODO EDICIÓN (No podemos usar ReadOnly que es 2)
            # 1 = swDocPART, 1 = swOpenDocOptions_Silent
            swModel = swApp.OpenDoc6(abspath, 1, 1, "", arg_errors, arg_warnings)
            
            if swModel is None:
                print(f"[ERROR] {filename}: No se pudo abrir el archivo (posible corrupción o versión ajena).")
                errores += 1
                continue
                
            try:
                # 1. Validar que sea una pieza (swDocPART = 1)
                if swModel.GetType() != 1:
                    print(f"[OMITIDO] {filename}: No es una pieza 3D.")
                    swApp.CloseDoc(abspath)
                    continue

                # A. Intentar por Lista de Cortes (Especial para Chapa Metálica)
                found_in_cut_list = False
                feat = swModel.FirstFeature()
                while feat:
                    if feat.GetTypeName2() == "CutListFolder":
                        cust_prop_mgr = feat.CustomPropertyManager
                        # Buscar nombres comunes en español e inglés
                        for prop in ["Largo de la chapa desplegada", "Ancho de la chapa desplegada", "Bounding Box Length", "Bounding Box Width"]:
                            res = cust_prop_mgr.Get6(prop, False, "", "", False)
                            if res[1]: # Si encontró valor
                                # Guardar medida y marcar como éxito
                                found_in_cut_list = True
                    feat = feat.GetNextFeature()

                # B. Si no es chapa o no tiene lista de cortes, INYECTAR Bounding Box Global
                if not found_in_cut_list:
                    try:
                        # Usamos 'Invoke' implicitamente vía Dispatch dinámico sobre la propiedad/método
                        # swFeatureManager.InsertGlobalBoundingBox (0=Best Fit, False, False, status)
                        status = 0
                        swModel.FeatureManager.InsertGlobalBoundingBox(0, False, False, status)
                    except Exception as e:
                        raise Exception(f"No se pudo inyectar Bounding Box ni leer Chapa Metálica: {str(e)}")

                
                # 4. Reconstruir para que las Custom Properties se generen (Ctrl+Q en SW)
                swModel.ForceRebuild3(False)
                
                # 5. Guardar silenciosamente y cerrar (swSaveAsOptions_Silent = 1)
                swModel.Save3(1, 0, 0)
                swApp.CloseDoc(abspath)
                
                print(f"[OK] {filename}")
                exitos += 1
                
            except Exception as feat_err:
                print(f"[ERROR] {filename}: Falló inyección Bounding Box - Motivo API: {feat_err}")
                errores += 1
                try: swApp.CloseDoc(abspath)
                except: pass
                
        except Exception as file_err:
            print(f"[ERROR] {filename}: Excepción general de acceso - {file_err}")
            errores += 1

    print("\n--- RESUMEN ---")
    print(f"Piezas exitosas: {exitos}")
    print(f"Errores detectados: {errores}")
    print("Proceso por lotes finalizado.\n")
    
    try:
        swApp.ExitApp()
    except:
        pass

if __name__ == "__main__":
    main()
