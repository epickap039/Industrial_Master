import sys
import io
import json
import os
import pyodbc
import pandas as pd
from sqlalchemy import create_engine, text
import urllib.parse
import datetime
import platform
import base64

# FORZAR SALIDA UTF-8 (Vital para comunicación con Flutter)
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# --- CONFIGURACIÓN ---
def load_config():
    config_path = "config.json"
    if hasattr(sys, '_MEIPASS'):
        config_path = os.path.join(os.path.dirname(sys.executable), "config.json")
    
    if os.path.exists(config_path):
        with open(config_path, 'r') as f:
            return json.load(f)
    return {}

def get_base_path():
    if hasattr(sys, '_MEIPASS'):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))

def get_connection_string():
    config = load_config()
    server = config.get('server', '192.168.1.73,1433')
    database = config.get('database', 'DB_Materiales_Industrial')
    is_windows_auth = config.get('is_windows_auth', True)
    
    # Force ODBC Driver 18
    driver = 'ODBC Driver 18 for SQL Server'
    
    if is_windows_auth:
        params = urllib.parse.quote_plus(
            f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};Trusted_Connection=yes;TrustServerCertificate=yes;'
        )
    else:
        user = config.get('user', '')
        password = config.get('password', '')
        params = urllib.parse.quote_plus(
            f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={user};PWD={password};TrustServerCertificate=yes;'
        )
    
    return f'mssql+pyodbc:///?odbc_connect={params}'

def get_engine():
    return create_engine(get_connection_string())

def sanitize(df):
    # 1. Reemplazar NaN/None con cadena VACÍA "" (Para que Flutter muestre celda vacía, no "null")
    df = df.fillna("")
    
    # 2. Limpieza de Strings (Evitar crash de JSON por caracteres de Excel)
    # Convertir columnas de texto a string y limpiar saltos de línea/tabs que rompen JSON
    for col in df.select_dtypes(include=['object']):
        df[col] = df[col].astype(str).str.replace(r'[\r\n\t]+', ' ', regex=True)
        
    # 3. Fechas a string
    for col in df.select_dtypes(include=['datetime', 'datetimetz']).columns:
        df[col] = df[col].astype(str).replace('NaT', "")
        
    return df

# --- RUTAS DE API ---

def test_connection():
    try:
        engine = get_engine()
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return {"status": "success", "message": "Conexión Exitosa con ODBC Driver 18"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def get_master_catalog():
    engine = get_engine()
    query = "SELECT * FROM Tbl_Maestro_Piezas ORDER BY Codigo_Pieza"
    with engine.connect() as conn:
        df = pd.read_sql(query, conn)
    return sanitize(df).to_dict(orient='records')

def get_conflicts():
    engine = get_engine()
    query = "SELECT * FROM V_Auditoria_Conflictos"
    with engine.connect() as conn:
        df = pd.read_sql(query, conn)
    
    # Aliases for frontend compatibility
    if not df.empty:
        df['id'] = df['Id'] if 'Id' in df.columns else ''
        df['codigo'] = df['Codigo_Pieza']
        df['descripcion'] = df['Descripcion_Final'] if 'Descripcion_Final' in df.columns else df['Desc_Master']
        df['archivo'] = df['Nombre_Archivo'] if 'Nombre_Archivo' in df.columns else ''
        df['hoja'] = df['Nombre_Hoja'] if 'Nombre_Hoja' in df.columns else ''
        df['fila'] = df['Numero_Fila_Excel'] if 'Numero_Fila_Excel' in df.columns else ''
        df['desc_excel'] = df['Desc_Excel'] if 'Desc_Excel' in df.columns else ''

    return sanitize(df).to_dict(orient='records')

def get_history(code):
    engine = get_engine()
    q = text("""
        SELECT TOP 50
            Codigo_Pieza as codigo, 
            Descripcion_Final as descripcion, 
            Estado_Resolucion as estado, 
            Fecha_Resolucion as fecha,
            Usuario as usuario
        FROM Tbl_Historial_Resoluciones 
        WHERE Codigo_Pieza = :c 
        ORDER BY Fecha_Resolucion DESC
    """)
    with engine.connect() as conn:
        df = pd.read_sql(q, conn, params={"c": code})
    return sanitize(df).to_dict(orient='records')

def get_resolved_tasks():
    engine = get_engine()
    query = """
    SELECT TOP 50
        Codigo_Pieza as codigo, 
        Descripcion_Final as descripcion, 
        Estado_Resolucion as estado, 
        Fecha_Resolucion as fecha,
        FORMAT(Fecha_Resolucion, 'dd/MM/yyyy HH:mm') as fecha_fmt,
        Usuario as usuario
    FROM Tbl_Historial_Resoluciones 
    ORDER BY Fecha_Resolucion DESC
    """
    with engine.connect() as conn:
        df = pd.read_sql(query, conn)
    return sanitize(df).to_dict(orient='records')

def log_update(message):
    try:
        base_dir = get_base_path()
        log_path = os.path.join(base_dir, "debug_sql_log.txt")
        with open(log_path, "a", encoding="utf-8") as f:
            timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            f.write(f"[{timestamp}] {message}\n")
    except:
        pass

def update_master(code, payload, force_resolve=False, resolution_status=None):
    log_update(f"Attempting UPDATE for {code}. Force: {force_resolve}, Status: {resolution_status}")
    engine = get_engine()
    
    status_resolution = 'IGNORADO'
    if resolution_status:
        status_resolution = resolution_status
    elif force_resolve:
         if payload and payload.get('Descripcion'):
             status_resolution = 'CORREGIDO'

    history_logged = False
    
    try:
        with engine.begin() as conn:
            if payload:
                q = text("""
                    UPDATE Tbl_Maestro_Piezas
                    SET Descripcion=:d, Material=:m, Medida=:md,
                        Proceso_Primario=:p0, Proceso_1=:p1, Proceso_2=:p2, Proceso_3=:p3,
                        Ultima_Actualizacion=GETDATE()
                    WHERE Codigo_Pieza=:c
                """)
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

            conn.execute(text("UPDATE Tbl_Historial_Proyectos SET Requiere_Correccion = 0, Estado_Resolucion = :s WHERE Codigo_Pieza = :c"), {'c': code, 's': status_resolution})

            if force_resolve:
                qh = text("""
                    INSERT INTO Tbl_Historial_Resoluciones 
                    (Codigo_Pieza, Descripcion_Final, Estado_Resolucion, Fecha_Resolucion, Usuario)
                    VALUES (:c, :d, :st, GETDATE(), 'SISTEMA')
                """)
                
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

def insert_master(payload):
    engine = get_engine()
    q = text("""
        INSERT INTO Tbl_Maestro_Piezas (Codigo_Pieza, Descripcion, Material, Medida, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3)
        VALUES (:c, :d, :m, :md, :p0, :p1, :p2, :p3)
    """)
    with engine.begin() as conn:
        conn.execute(q, {
            'c': payload.get('Codigo_Pieza'), 
            'd': payload.get('Descripcion'), 
            'm': payload.get('Material'), 
            'md': payload.get('Medida'),
            'p0': payload.get('Proceso_Primario'),
            'p1': payload.get('Proceso_1'), 
            'p2': payload.get('Proceso_2'), 
            'p3': payload.get('Proceso_3')
        })
def delete_master(code):
    engine = get_engine()
    q = text("DELETE FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = :c")
    with engine.begin() as conn:
        conn.execute(q, {'c': code})
    return {"status": "success"}

def fetch_part(code):
    engine = get_engine()
    q = text("""
        SELECT TOP 1 
            Codigo_Pieza, Descripcion, 
            ISNULL(Material, '') as Material, 
            ISNULL(Medida, '') as Medida,
            ISNULL(Proceso_Primario, '') as Proceso_Primario,
            ISNULL(Proceso_1, '') as Proceso_1,
            ISNULL(Proceso_2, '') as Proceso_2,
            ISNULL(Proceso_3, '') as Proceso_3
        FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = :code
    """)
    with engine.connect() as conn:
        df = pd.read_sql(q, conn, params={"code": code})
    return sanitize(df).to_dict(orient='records')

def get_homologation(code):
    engine = get_engine()
    query = text("SELECT * FROM V_Auditoria_Conflictos WHERE Codigo_Pieza = :c")
    with engine.connect() as conn:
        df = pd.read_sql(query, conn, params={"c": code})
    return sanitize(df).to_dict(orient='records')


def get_pending_tasks():
    engine = get_engine()
    # Usar VISTA DE CONFLICTOS como fuente principal (684 registros detectados)
    query = "SELECT * FROM V_Auditoria_Conflictos"
    with engine.connect() as conn:
        df = pd.read_sql(query, conn)
    
    # SOLUCIÓN MAESTRA v10.7: DATA TRANSLATOR logic
    
    # 1. Normalizar nombres de columnas (Todo a minúsculas para evitar case-sensitivity)
    df.columns = [c.lower() for c in df.columns]

    # 2. Renombrar columnas específicas (SQL -> Flutter Key)
    rename_map = {
        'id': 'id', # Asegurar ID si existe
        'archivo_origen': 'archivo',
        'nombre_archivo': 'archivo',
        'file': 'archivo',
        'nombre_hoja': 'hoja',
        'sheet': 'hoja',
        'fila_excel': 'fila',
        'numero_fila_excel': 'fila', # Added for safety
        'row': 'fila',
        'codigo_pieza': 'codigo',
        'parte': 'codigo',
        'desc_excel': 'desc_excel',
        'descripcion_excel': 'desc_excel'
    }
    
    # Búsqueda de Candidatos para Descripción (Detectivazo)
    candidatos_desc = ['descripcion_base', 'desc_master', 'descripcion', 'desc_oficial', 'descripcion_final', 'desc']
    col_encontrada = next((c for c in candidatos_desc if c in df.columns), None)
    
    if col_encontrada:
        rename_map[col_encontrada] = 'descripcion'
    
    df = df.rename(columns=rename_map)
    
    # Si de verdad no existe, llenar con un texto de aviso técnico
    if 'descripcion' not in df.columns:
        df['descripcion'] = 'Columna Descripción No Encontrada en SQL'

    # 3. Sanitizar Nulos (Blindaje)
    if not df.empty:
        # Usar .get para evitar KeyErrors si la columna no existe tras el rename
        if 'archivo' not in df.columns: df['archivo'] = 'Desconocido.xlsx'
        else: df['archivo'] = df['archivo'].fillna('Desconocido.xlsx')

        if 'fila' not in df.columns: df['fila'] = 0
        else: df['fila'] = df['fila'].fillna(0)
        
        if 'hoja' not in df.columns: df['hoja'] = 'Sheet1'
        else: df['hoja'] = df['hoja'].fillna('Sheet1')

    return sanitize(df).to_dict(orient='records')

def export_master():
    try:
        engine = get_engine()
        desktop = os.path.join(os.path.join(os.environ['USERPROFILE']), 'Desktop')
        filename = f"Maestro_Materiales_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
        output_path = os.path.join(desktop, filename)
        
        query = "SELECT * FROM Tbl_Maestro_Piezas ORDER BY Codigo_Pieza"
        with engine.connect() as conn:
            df = pd.read_sql(query, conn)
            df.to_excel(output_path, index=False)
            
        return {"status": "success", "path": output_path}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def mark_task_solved(id):
    engine = get_engine()
    q = text("UPDATE Tbl_Historial_Proyectos SET Requiere_Correccion = 0 WHERE Id = :id")
    with engine.begin() as conn:
        conn.execute(q, {"id": id})
    return {"status": "success"}

def find_blueprint(code):
    try:
        cfg = load_config()
        bp_path = cfg.get('blueprints_path', '')
        generics_path = cfg.get('generics_path', r"Z:\5. PIEZAS GENERICAS\JA'S PDF")
        
        code_clean = code.strip().upper()
        
        if code_clean.startswith('JA'):
            direct_path = os.path.join(generics_path, f"{code_clean}.pdf")
            if os.path.exists(direct_path):
                return {"status": "success", "path": direct_path, "level": "static_ja"}
        
        if '-' in code_clean:
            prefix = code_clean.split('-')[0]
            direct_guess = os.path.join(bp_path, prefix, f"{code_clean}.pdf")
            if os.path.exists(direct_guess):
                return {"status": "success", "path": direct_guess, "level": "direct_optimization"}
            
        if not bp_path or not os.path.exists(bp_path):
            return {"status": "error", "message": "Ruta de planos no configurada"}
            
        matches = []
        SKIP_DIRS = ['OBSOLETO', 'RESPALDO', 'BACKUP', 'OLD', 'BAK']
        
        search_root = bp_path
        if '-' in code_clean:
            prefix = code_clean.split('-')[0]
            try:
                potential_dirs = [d for d in os.listdir(bp_path) if os.path.isdir(os.path.join(bp_path, d))]
                for d in potential_dirs:
                    if prefix in d.upper():
                        search_root = os.path.join(bp_path, d)
                        break
            except:
                pass

        for root, dirs, files in os.walk(search_root):
            dirs[:] = [d for d in dirs if not any(s in d.upper() for s in SKIP_DIRS)]
            if f"{code_clean}.pdf" in files:
                full_path = os.path.join(root, f"{code_clean}.pdf")
                return {"status": "success", "path": full_path, "level": "deep_search"}
        
        return {"status": "error", "message": "Archivo no encontrado"}
    except Exception as e:
        return {"status": "error", "message": str(e)}

def run_full_diagnostics():
    # Estructura plana solicitada por el usuario v10.5
    response = {
        "db_status": False,
        "integrity_status": False,
        "logic_status": False,
        "path_status": False,
        "log": ""
    }
    
    log_buffer = []

    def add_log(msg):
        timestamp = datetime.datetime.now().strftime("%H:%M:%S")
        log_buffer.append(f"[{timestamp}] {msg}")

    try:
        add_log("=== INICIANDO DIAGNÓSTICO SENTINEL PRO v10.5 ===")
        
        # PASO 1: Conexión SQL
        try:
            add_log("1. Verificando Conexión SQL...")
            engine = get_engine()
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            response['db_status'] = True
            add_log("✅ Conexión SQL: EXITOSA")
        except Exception as e:
            add_log(f"❌ Error Crítico de Conexión: {str(e)}")
            raise e # Detener todo si no hay DB

        # PASO 2: Auditoría de Tablas
        try:
            add_log("2. Auditando Esquema de Tablas...")
            with engine.connect() as conn:
                tables = ['Tbl_Maestro_Piezas', 'Tbl_Historial_Resoluciones', 'Tbl_Historial_Proyectos']
                missing = []
                for t in tables:
                    try:
                        conn.execute(text(f"SELECT TOP 1 * FROM {t}"))
                        add_log(f"  - Tabla '{t}': OK")
                    except:
                        add_log(f"  - Tabla '{t}': NO ENCONTRADA")
                        missing.append(t)
                
                if missing:
                    add_log("❌ Tablas faltantes detectadas.")
                else:
                    try:
                        conn.execute(text("SELECT TOP 1 Nombre_Archivo, Nombre_Hoja, Numero_Fila_Excel FROM Tbl_Historial_Proyectos"))
                        add_log("  - Columnas de Metadatos Excel: OK")
                        response['integrity_status'] = True
                    except Exception as ce:
                        add_log(f"❌ Faltan columnas críticas en Tbl_Historial_Proyectos: {ce}")
        except Exception as e:
            add_log(f"❌ Error en auditoría de tablas: {e}")

        # PASO 3: Simulación Lógica Excel
        try:
            add_log("3. Simulando Lógica de Conflictos (Dry Run)...")
            query = "SELECT * FROM V_Auditoria_Conflictos"
            with engine.connect() as conn:
                df = pd.read_sql(query, conn)
            
            count = len(df)
            add_log(f"  - Filas leídas de V_Auditoria_Conflictos: {count}")
            
            if count == 0:
                add_log("⚠️ CERO conflictos detectados. ¿Lectura de Excel vacía?")
                # Warning status is technically "True" for logic operation but with warning log
                response['logic_status'] = True 
            else:
                add_log("✅ Lógica de Vistas operando correctamente.")
                response['logic_status'] = True

        except Exception as e:
            add_log(f"❌ Error leyendo vista de conflictos: {e}")

        # PASO 4: Integridad de Rutas
        try:
            add_log("4. Verificando Acceso a Recursos...")
            cfg = load_config()
            bp_path = cfg.get('blueprints_path', '')
            if not bp_path:
                 add_log("⚠️ Ruta de planos no configurada.")
            elif os.path.exists(bp_path):
                 add_log(f"✅ Ruta de Planos accesible: {bp_path}")
                 response['path_status'] = True
            else:
                 add_log(f"❌ Ruta de Planos INACCESIBLE: {bp_path}")
        except Exception as e:
            add_log(f"❌ Error validando rutas: {e}")

    except Exception as general_error:
        add_log(f"\n❌ EXCEPCIÓN GENERAL DEL SISTEMA: {str(general_error)}")
    
    finally:
        # Construir reporte final
        full_log = "\n".join(log_buffer)
        response['log'] = full_log
        
        # Guardar reporte físico en el Escritorio (USERPROFILE/Desktop)
        try:
            desktop = os.path.join(os.environ['USERPROFILE'], 'Desktop')
            report_path = os.path.join(desktop, "SENTINEL_LOG_v10.txt")
            with open(report_path, "w", encoding="utf-8") as f:
                f.write(full_log)
        except:
            pass # No fallar si no se puede escribir el archivo

        return response

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('command', help='Command to execute')
    parser.add_argument('--code', help='Part code')
    parser.add_argument('--id', help='Task ID')
    parser.add_argument('--stdin', action='store_true', help='Read payload from stdin (base64)')
    parser.add_argument('--force_resolve', action='store_true', help='Force resolution')
    parser.add_argument('--status', help='Custom resolution status')
    
    args = parser.parse_known_args()[0]
    
    payload = None
    if args.stdin:
        try:
            stdin_data = sys.stdin.read().strip()
            if stdin_data:
                try:
                    payload = json.loads(base64.b64decode(stdin_data).decode('utf-8'))
                except:
                    payload = json.loads(stdin_data)
        except:
            pass

    cmd = args.command
    
    try:
        result = None
        if cmd == 'test_connection':
            result = test_connection()
        elif cmd in ['get_all', 'catalog']:
            result = get_master_catalog()
        elif cmd in ['conflicts', 'get_conflicts']:
            result = get_conflicts()
        elif cmd in ['history', 'get_history']:
            result = get_history(args.code)
        elif cmd == 'update':
            result = update_master(args.code, payload, args.force_resolve, args.status)
        elif cmd == 'delete':
            result = delete_master(args.code)
        elif cmd == 'insert':
            result = insert_master(payload)
        elif cmd in ['fetch', 'fetch_part']:
            result = fetch_part(args.code)
        elif cmd in ['homologation', 'get_homologation']:
            result = get_homologation(args.code)
        elif cmd == 'get_resolved':
            result = get_resolved_tasks()
        elif cmd == 'get_pending':
            result = get_pending_tasks()
        elif cmd in ['mark_corrected', 'mark_solved']:
            result = mark_task_solved(args.id or args.code)
        elif cmd == 'find_blueprint':
            result = find_blueprint(args.code)
        elif cmd == 'export_master':
            result = export_master()
        elif cmd == 'diagnostic':
            result = run_full_diagnostics()
        else:
            result = {"status": "error", "message": f"Comando desconocido: {cmd}"}
            
        print(json.dumps(result, default=str))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}, default=str))
