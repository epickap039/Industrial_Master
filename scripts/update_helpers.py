
import re

def update_file():
    with open('scripts/data_bridge.py', 'r', encoding='utf-16') as f:
        content = f.read()

    new_func = """def update_master(code, payload, force_resolve=False):
    log_update(f"Attempting UPDATE for {code}. Force: {force_resolve}")
    engine = get_engine()
    
    # Determine Status
    status_resolution = 'IGNORADO'
    if force_resolve:
         # If payload has content (Accept Change), status is CORREGIDO
         if payload and payload.get('Descripcion'):
             status_resolution = 'CORREGIDO'
         # If payload is empty (Ignore Change), status is IGNORADO (Already set)

    history_logged = False
    
    try:
        with engine.begin() as conn:
            # 1. UPDATE Maestro (Only if payload exists)
            if payload:
                q = text(\"\"\"
                    UPDATE Tbl_Maestro_Piezas
                    SET Descripcion=:d, Material=:m, Medida=:md,
                        Proceso_Primario=:p0, Proceso_1=:p1, Proceso_2=:p2, Proceso_3=:p3,
                        Ultima_Actualizacion=GETDATE()
                    WHERE Codigo_Pieza=:c
                \"\"\")
                conn.execute(q, {
                    'c': code,
                    'd': payload.get('Descripcion'),
                    'm': payload.get('Material'),
                    'md': payload.get('Medida'),
                    'p0': payload.get('Proceso_Primario'),
                    'p1': payload.get('Proceso_1'),
                    'p2': payload.get('Proceso_2'),
                    'p3': payload.get('Proceso_3')
                })

            # 2. UPDATE Estado en Historial Proyectos (Mark as Solved)
            conn.execute(text("UPDATE Tbl_Historial_Proyectos SET Requiere_Correccion = 0, Estado_Resolucion = :s WHERE Codigo_Pieza = :c"), {'c': code, 's': status_resolution})

            # 3. INSERT en Historial Resoluciones (Audit)
            if force_resolve:
                qh = text(\"\"\"
                    INSERT INTO Tbl_Historial_Resoluciones 
                    (Codigo_Pieza, Descripcion_Final, Estado_Resolucion, Fecha_Resolucion, Usuario)
                    VALUES (:c, :d, :st, GETDATE(), 'SISTEMA')
                \"\"\")
                
                desc_final = payload.get('Descripcion') if payload else 'VALOR ORIGINAL CONSERVADO'
                
                conn.execute(qh, {
                    'c': code,
                    'd': desc_final,
                    'st': status_resolution
                })
                history_logged = True

        return {"status": "success", "history_logged": history_logged}
    except Exception as e:
        log_update(f"Error in update_master: {e}")
        return {"status": "error", "message": str(e), "history_logged": False}
"""

    # Replace the old function using regex to find the block
    # Pattern: def update_master(...) ... until next def or end of file
    
    # We need to capture the indentation correctly, but assuming top-level function
    pattern = r"def update_master\(.*?\):(\s+.*?(?=\ndef |\Z))"
    
    # Regex is tricky with multiline indent. Let's find start index and matching end.
    start_idx = content.find("def update_master(")
    if start_idx == -1:
        print("Function not found")
        return

    # Find the next function definition start
    next_def_idx = content.find("\ndef ", start_idx + 1)
    
    if next_def_idx == -1:
        old_block = content[start_idx:]
    else:
        old_block = content[start_idx:next_def_idx]

    new_content = content.replace(old_block, new_func)
    
    with open('scripts/data_bridge.py', 'w', encoding='utf-8') as f:
        f.write(new_content)
    print("Successfully updated data_bridge.py")

if __name__ == "__main__":
    update_file()
