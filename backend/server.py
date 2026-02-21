import socket
import uvicorn
import pyodbc
import pandas as pd
import openpyxl
from fastapi import FastAPI, HTTPException, Request, Response, UploadFile, File, Form
from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from typing import Dict, Any, List, Optional
from pydantic import BaseModel, ConfigDict
import io
import os
import re

# 1. CONFIGURACIÓN SQL (Auto-Detectada con Driver 18 Prioritario)
DB_SERVER = '192.168.1.73'
DB_PORT = 1433
DB_DATABASE = 'DB_Materiales_Industrial'

# Detectar el mejor driver disponible (18 > 17 > otros)
try:
    available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
    if available_drivers:
        # Tomar el último (usualmente la versión más reciente, ej: ODBC Driver 18)
        best_driver = available_drivers[-1]
        DB_DRIVER = f'{{{best_driver}}}'
        print(f"SQL DRIVER SELECCIONADO: {DB_DRIVER}")
    else:
        DB_DRIVER = '{ODBC Driver 17 for SQL Server}'
        print("AVISO: No se detectaron drivers SQL. Usando default 17.")
except Exception as e:
    DB_DRIVER = '{ODBC Driver 17 for SQL Server}'
    print(f"Error detectando drivers: {e}")

# Connection String con TrustServerCertificate para Driver 18+
CONNECTION_STRING = (
    f'DRIVER={DB_DRIVER};'
    f'SERVER={DB_SERVER},{DB_PORT};'
    f'DATABASE={DB_DATABASE};'
    'Trusted_Connection=yes;'
    'TrustServerCertificate=yes;' # Crucial para Driver 18
)

# 2. SEGURIDAD Y PERMISOS
ADMIN_HOSTNAME = socket.gethostname()
try:
    ADMIN_IP = socket.gethostbyname(ADMIN_HOSTNAME)
except:
    ADMIN_IP = "127.0.0.1"

# 4. INFRAESTRUCTURA (Lifespan)
@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"--- SERVER STARTED on {ADMIN_HOSTNAME} ---")
    print(f"--- LISTENING ON 0.0.0.0:8001 ---")
    
    # Inicializaciones Seguras
    iniciar_auditoria()
    
    try:
        init_auth_db()
    except Exception as e:
        print(f"ERROR INITIALIZING AUTH DB: {e}")
    
    yield
    print("--- SERVER SHUTTING DOWN ---")

# Variables Globales de Configuración (RE-APPLIED)
REGLA_ESPEJO_ACTIVA = True

class MirrorConfig(BaseModel):
    activa: bool

app = FastAPI(title="Industrial Manager API", version="15.5", lifespan=lifespan)

# === MATERIALES APROBADOS ===
class MaterialPayload(BaseModel):
    material: str

class LoginRequest(BaseModel):
    username: str
    password: str

@app.get("/")
def read_root():
    return {"status": "online", "message": "Servidor Industrial Manager Activo"}

@app.get("/api/config/materiales")
def get_materiales():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT Material FROM Tbl_Materiales_Aprobados ORDER BY Material")
    rows = cursor.fetchall()
    conn.close()
    return [row[0] for row in rows]

@app.post("/api/config/materiales")
def add_material(payload: MaterialPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)", (payload.material.upper(),))
        conn.commit()
        return {"mensaje": "Material agregado correctamente"}
    except pyodbc.IntegrityError:
        raise HTTPException(status_code=400, detail="El material ya existe")
    finally:
        conn.close()

@app.delete("/api/config/materiales/{material_name}")
def delete_material(material_name: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Materiales_Aprobados WHERE Material = ?", (material_name,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Material no encontrado")
        conn.commit()
        return {"mensaje": "Material eliminado correctamente"}
    finally:
        conn.close()

# === FIN MATERIALES APROBADOS ===
# --- ENDPOINTS CONFIGURACIÓN ---
@app.get("/api/config/regla_espejo")
async def get_mirror_config():
    return {"activa": REGLA_ESPEJO_ACTIVA}

@app.post("/api/config/regla_espejo")
async def set_mirror_config(config: MirrorConfig):
    global REGLA_ESPEJO_ACTIVA
    REGLA_ESPEJO_ACTIVA = config.activa
    print(f"--- REGLA ESPEJO ACTUALIZADA: {REGLA_ESPEJO_ACTIVA} ---")
    return {"activa": REGLA_ESPEJO_ACTIVA}

# Middleware CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

def get_db_connection():
    try:
        conn = pyodbc.connect(CONNECTION_STRING)
        return conn
    except Exception as e:
        print(f"Error de conexión SQL: {e}")
        raise HTTPException(status_code=500, detail=f"Database Connection Error: {str(e)}")

def init_auth_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='Tbl_Usuarios' AND xtype='U')
            CREATE TABLE Tbl_Usuarios (
                ID INT PRIMARY KEY IDENTITY(1,1),
                Username NVARCHAR(50) UNIQUE NOT NULL,
                Password NVARCHAR(50) NOT NULL,
                Role NVARCHAR(20) DEFAULT 'User'
            )
        """)
        conn.commit()
        
        users_to_seed = [
            ("jaes_admin", "Industrial.2026", "Admin"),
            ("ing_01", "Ing.2026", "User"),
            ("ing_02", "Ing.2026", "User"),
            ("ing_03", "Ing.2026", "User"),
            ("ing_04", "Ing.2026", "User"),
            ("ing_05", "Ing.2026", "User"),
            ("ing_06", "Ing.2026", "User"),
        ]
        
        for user, password, role in users_to_seed:
            cursor.execute("SELECT ID FROM Tbl_Usuarios WHERE Username = ?", (user,))
            if cursor.fetchone():
                cursor.execute("UPDATE Tbl_Usuarios SET Password = ?, Role = ? WHERE Username = ?", (password, role, user))
            else:
                cursor.execute("INSERT INTO Tbl_Usuarios (Username, Password, Role) VALUES (?, ?, ?)", (user, password, role))
        
        conn.commit()
    finally:
        conn.close()

@app.post("/api/login")
def login(request: LoginRequest):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute("SELECT Role FROM Tbl_Usuarios WHERE Username = ? AND Password = ?", (request.username, request.password))
        user = cursor.fetchone()
        
        conn.close()
        
        if user:
            return {"success": True, "role": user[0]}
        else:
            from fastapi import HTTPException
            raise HTTPException(status_code=401, detail="Credenciales incorrectas")
            
    except Exception as e:
        print(f"Error en login: {e}")
        from fastapi import HTTPException
        raise HTTPException(status_code=500, detail="Error interno del servidor")

def iniciar_auditoria():
    """Crea la tabla de auditoría si no existe. No detiene el arranque si falla."""
    print("--- INICIANDO SISTEMA DE AUDITORIA ---")
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Auditoria_Cambios')
            BEGIN
                CREATE TABLE Tbl_Auditoria_Cambios (
                    ID_Log INT IDENTITY(1,1) PRIMARY KEY,
                    Codigo_Pieza VARCHAR(50),
                    Accion VARCHAR(50),
                    Valor_Anterior NVARCHAR(MAX),
                    Valor_Nuevo NVARCHAR(MAX),
                    Usuario VARCHAR(100),
                    Fecha_Hora DATETIME DEFAULT GETDATE()
                );
            END
        """)
        conn.commit()
    # TABLA DE MATERIALES APROBADOS
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Materiales_Aprobados')
            BEGIN
                CREATE TABLE Tbl_Materiales_Aprobados (
                    ID INT IDENTITY(1,1) PRIMARY KEY,
                    Material VARCHAR(200) UNIQUE
                );
            END
        """)
        
        # POBLAR TABLA SI ESTÁ VACÍA
        cursor.execute("SELECT COUNT(*) FROM Tbl_Materiales_Aprobados")
        if cursor.fetchone()[0] == 0:
            materiales_iniciales = [
                "ACERO ASTM A36 1/8\"", "ACERO ASTM A36 3/16\"", "ACERO ASTM A36 C.10", "ACERO ASTM A36 C.14", "ACERO ASTM A36 C.16",
                "ACERO ASTM A572 G50 1/2\"", "ACERO ASTM A572 G50 1/4\"", "ACERO ASTM A572 G50 3/4\"", "ACERO ASTM A572 G50 3/8\"", "ACERO ASTM A572 G50 5/16\"",
                "ACERO INOXIDABLE 304 CAL.16", "ACERO INOXIDABLE C.11", "ALUMINIO 3003 C.11", "ALUMINIO 3003 C.14", "ALUMINIO 5052 1/4\"", "ALUMINIO NEGRO 3003 C.19",
                "ALUMINIO MACIZO 6026 Ø 1 1/2\"", "ALUMINIO MACIZO 6026 Ø 1/2\"", "ALUMINIO MACIZO 6026 Ø 2 1/2\"", "ALUMINIO MACIZO 6026 Ø 2\"", "ALUMINIO MACIZO 6026 Ø 3 1/2\"", "ALUMINIO MACIZO 6026 Ø 3\"", "ALUMINIO MACIZO 6026 Ø 4\"", "ALUMINIO MACIZO 6026 Ø 7/8\"",
                "ANGULO ASTM A36 1 1/2\" x 1 1/2\" x 3/16\"", "ANGULO ASTM A36 1\" x 1\" x 3/16\"", "ANGULO ASTM A36 2\" x 2\" x 3/16\"",
                "BARRA HUECA AISI 1018 Ø 33mm x 14mm", "BARRA HUECA AISI 1018 Ø 40mm x 25mm", "BARRA HUECA AISI 1018 Ø 40mm x 28mm", "BARRA HUECA AISI 1018 Ø 50mm x 35mm", "BARRA HUECA AISI 1018 Ø 76mm x 38mm",
                "BARRA CROMADA AISI 1045 Ø 28mm", "BARRA CROMADA AISI 1045 Ø 45mm", "TUBO HONEADO AISI 1018 Ø 60mm x 50mm", "TUBO HONEADO AISI 1018 Ø 73mm x 63mm",
                "BARRA HUECA CROMADA AISI 1018 Ø 38.1mm X 25.4mm",
                "BARRA HUECA DE ALUMINIO B241 6026 Ø 101.6mm X 50.5mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 63.5mm X 29.7mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 76.2mm X 29.7mm", "BARRA HUECA DE ALUMINIO B241 6026 Ø 88.9mm X 24.7mm",
                "CAJA DE TENSADO DE LONA", "CANAL C A36 4\"", "COMERCIAL BISAGRA DE LIBRO", "COMERCIAL BISAGRA DE PIANO", "MATRACA DE LONA", "PERFIL ALUMINIO PELDAÑO 688 6061 T6", "PERNO REY  COMERCIAL", "SEGURO DE FUNDICION -", "SEGURO DE RESORTE CORTO", "SEGURO DE RESORTE LARGO",
                "HSS ASTM A500 °B 2 1/2\" x 2 1/2\" x 1/4\"", "HSS ASTM A500 °B 2 1/2\" x 2 1/2\" x 3/16\"", "HSS ASTM A500 °B 2\" x 2\" x 1/4\"", "HSS ASTM A500 °B 2\" x 2\" x 3/16\"", "HSS ASTM A500 °B 3 1/2\" X 3 1/2\" X 3/16\"", "HSS ASTM A500 °B 3\" x 2\" x 1/4\"", "HSS ASTM A500 °B 3\" x 2\" x 3/16\"", "HSS ASTM A500 °B 3\" x 3\" x 1/4\"", "HSS ASTM A500 °B 3\" x 3\" x 3/16\"", "HSS ASTM A500 °B 4 1/2\" x 3 1/2\" x 3/16\"", "HSS ASTM A500 °B 4\" x 2\" x 1/4\"", "HSS ASTM A500 °B 4\" x 2\" x 3/16\"", "HSS ASTM A500 °B 4\" x 3\" x 1/4\"", "HSS ASTM A500 °B 4\" x 3\" x 3/16\"", "HSS ASTM A500 °B 4\" x 3\" x 3/8\"", "HSS ASTM A500 °B 4\" x 4\" x 3/8\"", "HSS ASTM A500 °B 6\" x 2\" x 1/4\"", "HSS ASTM A500 °B 6\" x 2\" x 3/16\"", "HSS ASTM A500 °B 6\" x 3\" x 1/4\"", "HSS ASTM A500 °B 6\" x 3\" x 3/16\"", "HSS ASTM A500 °B 6\" x 4\" x 1/4\"", "HSS ASTM A500 °B 6\" x 4\" x 3/8\"", "HSS ASTM A500 °B 6\" X 6\" X 1/4\"", "HSS ASTM A500 °B 6\" x 6\" x 3/8\"",
                "PLACA HARDOX 1/4\"", "PLACA STRENX 110 XF 3/16\"", "PLACA STRENX 110XF 1/2\"",
                "PTR ASTM A36 1 1/2\" x 1 1/2 \" x 3/16\"", "PTR ASTM A36 1\" x 1\" x C.11",
                "REDONDO AISI 1018 Ø 1 1/2\"", "REDONDO AISI 1018 Ø 1 1/4\"", "REDONDO AISI 1018 Ø 1 3/8\"", "REDONDO AISI 1018 Ø 1\"", "REDONDO AISI 1018 Ø 1/2\"", "REDONDO AISI 1018 Ø 2 1/2\"", "REDONDO AISI 1018 Ø 2 5/8\"", "REDONDO AISI 1018 Ø 2\"", "REDONDO AISI 1018 Ø 3\"", "REDONDO AISI 1018 Ø 3/4\"", "REDONDO AISI 1018 Ø 7/8\"", "REDONDO NEGRO Ø 5/16\"", "REDONDO NEGRO Ø 5/8\"",
                "RIEL DE ACERO A36 1500", "SOLERA ASTM A36 1 1/2\" x 1/2\"", "SOLERA ASTM A36 1 1/4\" x 1/4\"", "SOLERA ASTM A36 1\" x 1/2\"", "SOLERA ASTM A36 2\" x 1\"", "SOLERA ASTM A36 4\" x 1\"", "SOLERA ASTM A36 6\" x 1\"", "SOLERA DE ALUMINIO ASTM A36 2\" X 1\"",
                "TOLDO ALUMINIO C.19",
                "TUBO DE ACERO A500 °B Ø 1 1/2\" CED. 80", "TUBO DE ACERO A500 °B Ø 1 1/2\" CED. 80 SIN/COS", "TUBO DE ACERO A500 °B Ø 1\" CED. 40 C/COS", "TUBO DE ACERO A500 °B Ø 1\" CED. 40 SIN/COS",
                "TUBO DE ALUMINIO B241 Ø  2\" x  1\" x 1/8\"", "TUBO DE ALUMINIO B241 Ø 2 1/2\"", "TUBO DE ALUMINIO B241 Ø 2\"", "TUBO DE ALUMINIO B241 Ø 2\" x  1\" x 1/8\"", "TUBO DE ALUMINIO B241 Ø 3 1/2\"", "TUBO DE ALUMINIO NEGRO B241 Ø 2 1/2\"",
                "TUBO STROCK CROMADO ASTM 1045 Ø 70mm X 63mm",
                "PERFIL ALUMINIO CUERNO EA 685 6061T6", "PERFIL ALUMINIO PRINCIPAL EXT 684 6061T6", "PERFIL ALUMINIO ANGULO VISTA 686", "PERFIL ALUMINIO REFUERZO INT 683", "BORDA LATERAL BASCULANTE 4.9 6061", "BORDA LATERAL BASCULANTE 3.5 6061", "PERFIL DE ALUMINIO TIPO BISAGRA ABATIBLE 3.10 MT 6061-T6", "PERFIL DE ALUMINIO TIPO ESCALON ABATIBLE 3.10 MT 6061-T6"
            ]
            
            for mat in materiales_iniciales:
                cursor.execute("IF NOT EXISTS (SELECT * FROM Tbl_Materiales_Aprobados WHERE Material = ?) INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)", (mat, mat))
            
            conn.commit()
            print(f"--- TB_MATERIALES_APROBADOS INICIALIZADA ({len(materiales_iniciales)} items) ---")

        print("--- ✅ SISTEMA DE AUDITORIA INICIALIZADO CORRECTAMENTE ---")
    except Exception as e:
        print(f"--- ⚠️ ALERTA SQL (Auditoría): {e} ---")
    finally:
        try:
             conn.close()
        except:
             pass

def registrar_auditoria(cursor, codigo_pieza, accion, valor_anterior, valor_nuevo, usuario):
    """
    Registra un evento en Tbl_Auditoria_Cambios.
    Maneja la conversión de dicts a JSON string si es necesario.
    """
    try:
        # Convertir a cadena si son diccionarios/listas
        if isinstance(valor_anterior, (dict, list)):
            valor_anterior = str(valor_anterior) # Usamos str() para ser consistente con lo que espera el parser (ast.literal_eval/json)
        if isinstance(valor_nuevo, (dict, list)):
            valor_nuevo = str(valor_nuevo)

        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (codigo_pieza, accion, str(valor_anterior), str(valor_nuevo), usuario))
    except Exception as e:
        print(f"--- ⚠️ ERROR AUDITORIA INTERNA: {e} ---")

@app.get("/api/catalog")
async def get_catalog():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = "SELECT * FROM Tbl_Maestro_Piezas"
        cursor.execute(query)
        columns = [column[0] for column in cursor.description]
        data = []
        for row in cursor.fetchall():
            record = {}
            for col, val in zip(columns, row):
                record[col] = val if val is not None else "-"
            data.append(record)
        return data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# 6. EDICIÓN DE MATERIALES (ESPECÍFICA + CAMPOS NUEVOS + PROCESO 3)
@app.put("/api/material/update")
async def update_material(request: Request, payload: Dict[str, Any]):
    print(f"--- UPDATE MATERIAL FULL EDITOR V2 ---")
    print(f"Payload: {payload}")

    # Extraer ID
    codigo_pieza = payload.get('Codigo_Pieza')
    codigo_legacy = payload.get('Codigo')
    id_param = codigo_pieza if codigo_pieza else codigo_legacy

    if not id_param:
        raise HTTPException(status_code=400, detail="Falta Codigo_Pieza o Codigo")

    # Campos Permitidos (Whitelist) - Incluyendo Proceso_3
    allowed_fields = [
        'Descripcion', 'Medida', 'Material', 'Link_Drive', 
        'Simetria', 'Proceso_Primario', 'Proceso_1', 'Proceso_2', 'Proceso_3'
    ]
    
    # REGLA ESPEJO: Si está activa y se actualiza la descripción, también el material
    if REGLA_ESPEJO_ACTIVA and 'Descripcion' in payload:
        payload['Material'] = payload['Descripcion']

    usuario = payload.get('usuario') or payload.get('Modificado_Por') or 'Sistema'

    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # Asegurar columna Modificado_Por
        try:
            cursor.execute("SELECT Modificado_Por FROM Tbl_Maestro_Piezas WHERE 1=0")
        except:
             conn.rollback()
             cursor.execute("ALTER TABLE Tbl_Maestro_Piezas ADD Modificado_Por NVARCHAR(50)")
             conn.commit()

        # Construcción Dinámica Segura de la Query
        set_clauses = []
        values = []
        
        for field in allowed_fields:
            if field in payload:
               set_clauses.append(f"{field} = ?")
               values.append(payload[field])
        
        if not set_clauses:
             return {"status": "ignored", "message": "No hay campos válidos para actualizar"}


        # Agregar Auditoría
        set_clauses.append("Modificado_Por = ?")
        values.append(usuario)
        
        set_clauses.append("Ultima_Actualizacion = GETDATE()")
        
        query_set = ", ".join(set_clauses)
        
        # --- AUDITORIA: CAPTURAR VALOR ANTERIOR ---
        try:
             # Seleccionamos todos los campos afectados + ID
             cols_to_select = ", ".join(allowed_fields)
             cursor.execute(f"SELECT {cols_to_select} FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (id_param,))
             row_prev = cursor.fetchone()
             
             valor_anterior = {}
             if row_prev:
                 for i, field in enumerate(allowed_fields):
                     valor_anterior[field] = str(row_prev[i]) if row_prev[i] is not None else ""
             else:
                 valor_anterior = "REGISTRO NO ENCONTRADO (Posible error en Update)"
        except Exception as audit_read_e:
             valor_anterior = f"ERROR LECTURA PREVIA: {audit_read_e}"
        # ------------------------------------------

        # Query Principal
        query = f"UPDATE Tbl_Maestro_Piezas SET {query_set} WHERE Codigo_Pieza = ?"
        values.append(id_param)
        
        print(f"SQL GENERADO: {query}")
        
        cursor.execute(query, values)
        
        if cursor.rowcount == 0:
            print("Fallback: Actualizando por Codigo...")
            query_fallback = f"UPDATE Tbl_Maestro_Piezas SET {query_set} WHERE Codigo = ?"
            cursor.execute(query_fallback, values)

        conn.commit()
        
        if cursor.rowcount > 0:
             # --- AUDITORIA: REGISTRAR CAMBIO ---
             registrar_auditoria(cursor, id_param, 'EDICION_CATALOGO', valor_anterior, payload, usuario)
             conn.commit() # Commit del log
             # -----------------------------------
             return {"status": "success", "message": "Actualizado correctamente"}
        else:
             raise HTTPException(status_code=404, detail="No se encontró registro (Codigo/Codigo_Pieza)")

    except Exception as e:
        conn.rollback()
        print(f"ERROR UPDATE: {e}")
        raise HTTPException(status_code=500, detail=f"SQL Error: {str(e)}")
    finally:
        conn.close()

# 5. MOTOR DE ARBITRAJE EXCEL
@app.post("/api/excel/procesar")
async def procesar_excel(file: UploadFile = File(...)):
    print(f"--- PROCESANDO BOM EXCEL: {file.filename} ---")
    contents = await file.read()
    
    try:
        # 1. Leer Excel (Memoria)
        wb = openpyxl.load_workbook(io.BytesIO(contents), data_only=True)
        ws = wb.active
        
        scan_data = []
        last_estacion = None
        last_ensamble = None
        
        # 2. Iterar filas (Start Row 6 - 0-indexed es 5, pero openpyxl es 1-based, así que min_row=6)
        start_row = 6
        for row in ws.iter_rows(min_row=start_row, values_only=True):
            # Mapeo por índice (0-based)
            # Col 3 (D): CODIGO_PIEZA
            # Col 4 (E): DESCRIPCION / MATERIAL
            # Col 5 (F): MEDIDA
            # Col 7 (H): SIMETRIA
            # Col 8 (I): PROCESO PRIMARIO
            # Col 9 (J): PROCESO 1
            # Col 10 (K): PROCESO 2
            # Col 11 (L): PROCESO 3
            
            if not row: continue

            # Forward Fill Logic
            estacion = row[1] if len(row) > 1 and row[1] is not None else last_estacion
            ensamble = row[2] if len(row) > 2 and row[2] is not None else last_ensamble
            
            if estacion: last_estacion = estacion
            if ensamble: last_ensamble = ensamble

            # Validar Codigo Pieza (Columna D - Index 3)
            if len(row) <= 3: continue
            raw_codigo = row[3]
            codigo_pieza = str(raw_codigo).strip() if raw_codigo else None
            
            if not codigo_pieza or codigo_pieza.lower() in ['none', 'codigo', 'codigo_pieza', '']:
                continue

            # Extracción segura con manejo de nulos
            def get_val(idx):
                if idx < len(row) and row[idx] is not None:
                    return str(row[idx]).strip()
                return ""

            scan_data.append({
                'Estacion': last_estacion,
                'Ensamble': last_ensamble,
                'Codigo_Pieza': codigo_pieza,
                'Cantidad': 0, 
                'Descripcion_Excel': get_val(4),
                'Medida_Excel': get_val(5),
                'Material_Excel': "", # No mapeado explícitamente en columna aparte, dejamos vacío (Regla Espejo lo llenará si aplica)
                'Simetria': get_val(7),
                'Proceso_Primario': get_val(8),
                'Proceso_1': get_val(9),
                'Proceso_2': get_val(10),
                'Proceso_3': get_val(11),
                'Link_Drive': "" # No mapeado en este bloque
            })

        # 3. Comparar contra SQL
        conn = get_db_connection()
        cursor = conn.cursor()
        
        conflictos = []
        
        for item in scan_data:
            cursor.execute("SELECT Descripcion, Medida, Material, Simetria, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3, Link_Drive FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (item['Codigo_Pieza'],))
            row_sql = cursor.fetchone()
            
            status = "OK"
            detalles = []

            if not row_sql:
                status = "NUEVO"
                sql_data = {}
            else:
                desc_sql = (row_sql[0] or "").strip()
                med_sql = (row_sql[1] or "").strip()
                mat_sql = (row_sql[2] or "").strip()
                # Otros campos para mostrar en UI
                sim_sql = (row_sql[3] or "").strip()
                pp_sql = (row_sql[4] or "").strip()
                p1_sql = (row_sql[5] or "").strip()
                p2_sql = (row_sql[6] or "").strip()
                p3_sql = (row_sql[7] or "").strip()
                link_sql = (row_sql[8] or "").strip()

                sql_data = {
                    'Descripcion': desc_sql,
                    'Medida': med_sql,
                    'Material': mat_sql,
                    'Simetria': sim_sql,
                    'Proceso_Primario': pp_sql,
                    'Proceso_1': p1_sql,
                    'Proceso_2': p2_sql,
                    'Proceso_3': p3_sql,
                    'Link_Drive': link_sql
                }

                # Comparación Flexible (Case Insensitive)
                if item['Descripcion_Excel'].lower() != desc_sql.lower():
                     if item['Descripcion_Excel']: # Solo si excel tiene dato
                        status = "CONFLICTO"
                        detalles.append(f"Desc: '{item['Descripcion_Excel']}' vs SQL '{desc_sql}'")
                
                if item['Medida_Excel'].lower() != med_sql.lower():
                     if item['Medida_Excel']:
                        status = "CONFLICTO"
                        detalles.append(f"Med: '{item['Medida_Excel']}' vs SQL '{med_sql}'")

            if status != "OK":
                conflictos.append({
                    'Codigo_Pieza': item['Codigo_Pieza'],
                    'Estado': status,
                    'Detalles': "; ".join(detalles),
                    'Excel_Data': item,
                    'SQL_Data': sql_data # <--- DATOS FALTANTES
                })

        return {
            "total_leidos": len(scan_data),
            "conflictos": conflictos,
            "mensaje": f"Procesado exitoso. {len(conflictos)} conflictos detectados."
        }

    except Exception as e:
        print(f"ERROR EXCEL: {e}")
        raise HTTPException(status_code=500, detail=f"Error procesando Excel: {str(e)}")

class SincronizacionItem(BaseModel):
    Codigo_Pieza: str
    Descripcion: Optional[str] = None
    Medida: Optional[str] = None
    Material: Optional[str] = None
    Link_Drive: Optional[str] = None
    Simetria: Optional[str] = None
    Proceso_Primario: Optional[str] = None
    Proceso_1: Optional[str] = None
    Proceso_2: Optional[str] = None
    Proceso_3: Optional[str] = None
    Modificado_Por: Optional[str] = None 
    Estado: str 
    
    model_config = ConfigDict(extra='ignore')

@app.post("/api/excel/sincronizar")
async def sincronizar_excel(items: List[SincronizacionItem]):
    conn = get_db_connection()
    cursor = conn.cursor()
    
    procesados = 0
    errores = 0
    
    try:
        for item in items:
            # REGLA ESPEJO
            if REGLA_ESPEJO_ACTIVA:
                item.Material = item.Descripcion

            # Sanitizar datos (Evitar NULLs -> Strings Vacíos)
            desc = item.Descripcion if item.Descripcion is not None else ""
            medida = item.Medida if item.Medida is not None else ""
            material = item.Material if item.Material is not None else ""
            link = item.Link_Drive if item.Link_Drive is not None else ""
            simetria = item.Simetria if item.Simetria is not None else ""
            proc_prim = item.Proceso_Primario if item.Proceso_Primario is not None else ""
            proc_1 = item.Proceso_1 if item.Proceso_1 is not None else ""
            proc_2 = item.Proceso_2 if item.Proceso_2 is not None else ""
            proc_3 = item.Proceso_3 if item.Proceso_3 is not None else ""
            
            # Auditoría
            usuario = item.Modificado_Por if item.Modificado_Por else "Importador Excel"

            if item.Estado == "NUEVO":
                # Lógica de Inserción (INSERT COMPLETO)
                cursor.execute("""
                    IF NOT EXISTS (SELECT 1 FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?)
                    BEGIN
                        INSERT INTO Tbl_Maestro_Piezas 
                        (Codigo_Pieza, Descripcion, Medida, Material, Simetria, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3, Link_Drive, Ultima_Actualizacion, Modificado_Por)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, GETDATE(), ?)
                    END
                """, (item.Codigo_Pieza, item.Codigo_Pieza, desc, medida, material, simetria, proc_prim, proc_1, proc_2, proc_3, link, usuario))
                

                if cursor.rowcount > 0:
                    procesados += 1
                    # Log Auditoría CREACIÓN
                    registrar_auditoria(cursor, item.Codigo_Pieza, 'CREACION', 'NO EXISTIA', item.model_dump(), usuario)

            elif item.Estado == "CONFLICTO":
                # Lógica de Actualización (UPDATE COMPLETO)
                # 1. Obtener datos anteriores
                cursor.execute("SELECT * FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (item.Codigo_Pieza,))
                row_old = cursor.fetchone()
                val_anterior = str(row_old) if row_old else "DESCONOCIDO"

                # 2. Ejecutar Update
                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas
                    SET Descripcion = ?,
                        Medida = ?,
                        Material = ?,
                        Simetria = ?,
                        Proceso_Primario = ?,
                        Proceso_1 = ?,
                        Proceso_2 = ?,
                        Proceso_3 = ?,
                        Link_Drive = ?,
                        Ultima_Actualizacion = GETDATE(),
                        Modificado_Por = ?
                    WHERE Codigo_Pieza = ?
                """, (desc, medida, material, simetria, proc_prim, proc_1, proc_2, proc_3, link, usuario, item.Codigo_Pieza))
                
                if cursor.rowcount > 0:
                    procesados += 1
                    # Log Auditoría MODIFICACIÓN
                    registrar_auditoria(cursor, item.Codigo_Pieza, 'MODIFICACION', val_anterior, item.model_dump(), usuario)

        conn.commit()
        return {"status": "ok", "message": f"{procesados} registros sincronizados exitosamente."}

    except Exception as e:
        conn.rollback()
        print(f"Error en sincronizacion: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error al sincronizar BD: {str(e)}")
    finally:
        conn.close()

# 7. CONFIGURACIÓN Y UTILIDADES (ACTUALIZADOR DE LINKS)
@app.post("/api/config/update_links")
async def update_links(payload: Dict[str, str]):
    root_path = payload.get('root_path')
    if not root_path or not os.path.exists(root_path):
        raise HTTPException(status_code=400, detail="Ruta base inválida o inaccesible")

    # Archivo Maestro definido por el usuario
    excel_path = os.path.join(root_path, "MAESTRO DE MATERIALES.xlsx")
    if not os.path.exists(excel_path):
        print(f"ERROR: No se encontró {excel_path}")
        # Retornamos error claro para el frontend
        raise HTTPException(status_code=404, detail=f"No se encontró el archivo 'MAESTRO DE MATERIALES.xlsx' en {root_path}")

    print(f"--- SINCRONIZANDO ENLACES DESDE EXCEL: {excel_path} ---")
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # 1. Leer Excel usando pandas (según imagen: Col A=Codigo, Col B=URL_Google_Drive)
        df = pd.read_excel(excel_path)
        
        # Normalizar nombres de columnas
        df.columns = [str(c).strip() for c in df.columns]
        
        # Validar Columnas (Basado en captura de pantalla)
        if 'Codigo' not in df.columns:
            raise HTTPException(status_code=400, detail="El Excel no tiene la columna 'Codigo'")
        
        # Buscar columna de Drive (puede ser 'URL_Google_Drive' o similar)
        drive_col = next((c for c in df.columns if 'drive' in c.lower() or 'url' in c.lower()), None)
        
        if not drive_col:
             raise HTTPException(status_code=400, detail="No se encontró la columna de enlaces de Drive")

        updated_count = 0
        
        # 2. Iterar y Actualizar
        for _, row in df.iterrows():
            codigo = str(row['Codigo']).strip()
            link = str(row[drive_col]).strip()
            

            # Solo actualizar si el link existe y no es nulo
            if codigo and link and link.lower() != 'nan' and link != "":
                
                # --- AUDITORIA: CAPTURAR LINK ANTERIOR ---
                prev_link_val = "N/A"
                try:
                    cursor.execute("SELECT Link_Drive FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
                    row_link = cursor.fetchone()
                    if row_link:
                         prev_link_val = row_link[0]
                except:
                    pass
                # ----------------------------------------

                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Link_Drive = ?, 
                        Ultima_Actualizacion = GETDATE(),
                        Modificado_Por = 'Sincronizador Excel'
                    WHERE Codigo_Pieza = ?
                """, (link, codigo))
                
                if cursor.rowcount > 0:
                     updated_count += cursor.rowcount
                     # --- AUDITORIA ---
                     registrar_auditoria(cursor, codigo, 'ACTUALIZACION_LINKS', prev_link_val, link, 'Sincronizador Excel')
                     # -----------------

        conn.commit()
        print(f"--- SINCRONIZACIÓN EXCEL FINALIZADA: {updated_count} links actualizados ---")
        return {"status": "ok", "updated": updated_count}

    except Exception as e:
        if 'conn' in locals(): conn.rollback()
        print(f"ERROR EN SINCRONIZACIÓN EXCEL: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if 'conn' in locals(): conn.close()

@app.post("/api/excel/actualizar_enlaces")
async def actualizar_enlaces_manual(file: UploadFile = File(...)):
    """
    Actualiza enlaces Drive desde un Excel cargado por el usuario.
    Estructura: Col 0 = Código, Col 1 = Link_Drive
    """
    print(f"--- ACTUALIZANDO ENLACES DESDE EXCEL MANUAL: {file.filename} ---")
    contents = await file.read()
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # 1. Leer Excel (Memoria)
        wb = openpyxl.load_workbook(io.BytesIO(contents), data_only=True)
        ws = wb.active
        
        updated_count = 0
        row_idx = 0
        
        # 2. Iterar filas
        for row in ws.iter_rows(values_only=True):
            row_idx += 1
            # Saltar encabezado (fila 1)
            if row_idx == 1:
                continue
                
            if not row or len(row) < 2:
                continue
                
            codigo = str(row[0]).strip() if row[0] else None
            link = str(row[1]).strip() if row[1] else None
            

            # Solo procesar si hay código y link válido
            if codigo and link and link.lower() != 'nan' and link != "" and link != "-":
                
                # --- AUDITORIA: CAPTURAR LINK ANTERIOR ---
                prev_link_val = "N/A"
                try:
                    cursor.execute("SELECT Link_Drive FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
                    row_link = cursor.fetchone()
                    if row_link:
                         prev_link_val = row_link[0]
                except:
                    pass
                # ----------------------------------------

                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Link_Drive = ?, 
                        Ultima_Actualizacion = GETDATE(),
                        Modificado_Por = 'Sincronizador Manual (Excel)'
                    WHERE Codigo_Pieza = ?
                """, (link, codigo))
                
                if cursor.rowcount == 0:
                    # Fallback eliminado: La columna 'Codigo' no existe en esta versión de la BD.
                    # Si se requiere soporte legacy, asegurar que la columna exista primero.
                    print(f"--- AVISO: Codigo '{codigo}' no encontrado por Codigo_Pieza ---")
                
                else: 
                     updated_count += cursor.rowcount
                     # --- AUDITORIA ---
                     registrar_auditoria(cursor, codigo, 'ACTUALIZACION_LINKS', prev_link_val, link, 'Sincronizador Manual (Excel)')
                     # -----------------

        conn.commit()
        print(f"--- ACTUALIZACIÓN MANUAL FINALIZADA: {updated_count} enlaces actualizados ---")
        return {"status": "ok", "actualizados": updated_count}

    except Exception as e:
        if 'conn' in locals(): conn.rollback()
        print(f"ERROR EN ACTUALIZACIÓN MANUAL: {e}")
        raise HTTPException(status_code=500, detail=f"Error procesando Excel: {str(e)}")
    finally:
        if 'conn' in locals(): conn.close()

# --- FASE 12 y 13: AUDITOR AVANZADO Y HERRAMIENTAS ---

@app.post("/api/excel/auditar")
async def auditar_excel(file: UploadFile = File(...)):
    """
    Audita un archivo Excel comparando múltiples columnas con la BD.
    Retorna errores puntuales para UI y reporte detallado para Excel.
    """
    print(f"--- INICIANDO AUDITORÍA AVANZADA: {file.filename} ---")
    contents = await file.read()
    
    errores = []
    reporte_detallado = [] # Lista de objetos con contexto completo
    
    field_map = {
        'Descripcion': 4,
        'Medida': 5,
        'Simetria': 7,
        'Proceso_Primario': 8,
        'Proceso_1': 9,
        'Proceso_2': 10,
        'Proceso_3': 11
    }

    try:
        wb = openpyxl.load_workbook(io.BytesIO(contents), data_only=True)
        ws = wb.active
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        for row_idx, row in enumerate(ws.iter_rows(min_row=6, values_only=True), start=6):
            if not row or len(row) < 12: 
                continue
            
            codigo_excel = str(row[3]).strip() if row[3] else None
            if not codigo_excel: continue

            cursor.execute("""
                SELECT Descripcion, Medida, Simetria, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3 
                FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?
            """, (codigo_excel,))
            row_bd = cursor.fetchone()
            
            if row_bd:
                vals_bd = {
                    'Descripcion': str(row_bd[0] or "").strip(),
                    'Medida': str(row_bd[1] or "").strip(),
                    'Simetria': str(row_bd[2] or "").strip(),
                    'Proceso_Primario': str(row_bd[3] or "").strip(),
                    'Proceso_1': str(row_bd[4] or "").strip(),
                    'Proceso_2': str(row_bd[5] or "").strip(),
                    'Proceso_3': str(row_bd[6] or "").strip(),
                }
                
                vals_excel = {}
                row_diffs = []

                # Recolectar datos y diffs
                for field, col_idx in field_map.items():
                    val_excel = str(row[col_idx]).strip() if row[col_idx] else ""
                    vals_excel[field] = val_excel
                    
                    if val_excel != vals_bd[field]:
                         errores.append({
                            "fila": row_idx,
                            "codigo": codigo_excel,
                            "campo": field,
                            "excel": val_excel,
                            "bd": vals_bd[field]
                        })
                         row_diffs.append(field)
                
                # Si hubo diferencias en esta fila, guardamos contexto completo
                if row_diffs:
                    reporte_detallado.append({
                        "fila": row_idx,
                        "codigo": codigo_excel,
                        "excel_data": vals_excel,
                        "bd_data": vals_bd,
                        "campos_error": row_diffs
                    })

        print(f"--- AUDITORÍA FINALIZADA: {len(errores)} discrepancias en {len(reporte_detallado)} filas ---")
        return {"status": "ok", "errores": errores, "reporte_detallado": reporte_detallado}

    except Exception as e:
        print(f"ERROR AUDITORIA: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if 'conn' in locals(): conn.close()

from datetime import datetime
import json

@app.post("/api/excel/corregir")
async def corregir_excel(
    file: UploadFile = File(...), 
    correcciones: str = Form(...) # JSON String
):
    print(f"--- INICIANDO AUTOCORRECCIÓN SEGURA: {file.filename} ---")

    try:
        corrections_list = json.loads(correcciones)
        
        # Leer archivo en memoria
        contents = await file.read()
        
        # 2. APLICAR CORRECCIONES
        wb = openpyxl.load_workbook(io.BytesIO(contents)) # No data_only para preservar FÓRMULAS
        ws = wb.active # Asumimos hoja activa

        
        # Mapeo Campo -> Columna (1-based para cell.column)
        # D(4)=Codigo, E(5)=Desc, F(6)=Medida, H(8)=Simetria
        # PROCESOS DISTRIBUIDOS (NO COMBINADOS):
        # I(9)=Primario, J(10)=Proc1, K(11)=Proc2, L(12)=Proc3
        col_map = {
            'Descripcion': 5, # E
            'Medida': 6,      # F
            'Simetria': 8,    # H
            'Proceso_Primario': 9, # I
            'Proceso_1': 10,  # J
            'Proceso_2': 11,  # K
            'Proceso_3': 12   # L
        }

        count = 0
        for item in corrections_list:
            fila = int(item['fila'])
            campo = item['campo']
            valor_correcto = item['bd']
            
            if campo in col_map:
                col_idx = col_map[campo]
                # openpyxl: ws.cell(row=X, column=Y).value = ...
                ws.cell(row=fila, column=col_idx).value = valor_correcto
                count += 1
        
        # 3. GUARDAR COMO BINARIO Y DEVOLVER
        output = io.BytesIO()
        wb.save(output)
        output.seek(0)
        
        print(f"Archivo corregido en memoria ({count} cambios). Enviando al cliente...")
        
        headers = {
            'Content-Disposition': f'attachment; filename="CORREGIDO_{file.filename}"'
        }
        from fastapi.responses import StreamingResponse
        return StreamingResponse(
            output, 
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", 
            headers=headers
        )

    except Exception as e:
        print(f"ERROR CORRECCIÓN: {e}")
        raise HTTPException(status_code=500, detail=f"Error al corregir archivo: {str(e)}")

@app.post("/api/system/open_file")
async def open_file_endpoint(payload: Dict[str, str]):
    path = payload.get('path')
    if not path or not os.path.exists(path):
         raise HTTPException(status_code=404, detail="Archivo no encontrado")
    
    try:
        os.startfile(path)
        return {"status": "ok"}
    except Exception as e:
         raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/excel/exportar_reporte")
async def exportar_reporte(payload: List[Dict[str, Any]]):
    """
    Genera reporte estilo comparativo:
    Fila Excel
    Fila BD (Errors Highlighted)
    [Empty Row]
    """
    try:
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "Reporte de Auditoria"
        
        # Estilos
        header_font = Font(bold=True, color="FFFFFF")
        header_fill = PatternFill(start_color="333333", end_color="333333", fill_type="solid")
        error_fill = PatternFill(start_color="FFCCCC", end_color="FFCCCC", fill_type="solid") # Rojo claro
        bd_row_fill = PatternFill(start_color="F0F0F0", end_color="F0F0F0", fill_type="solid") # Gris muy claro
        
        headers = ['Fila', 'Código', 'Fuente', 'Descripción', 'Medida', 'Simetría', 'Proceso Primario', 'Proceso 1', 'Proceso 2', 'Proceso 3']
        ws.append(headers)
        
        # Aplicar estilo headers
        for cell in ws[1]:
            cell.font = header_font
            cell.fill = header_fill
            cell.alignment = Alignment(horizontal="center")

        current_row = 2
        
        # Ordenar columnas para iteración
        col_keys = ['Descripcion', 'Medida', 'Simetria', 'Proceso_Primario', 'Proceso_1', 'Proceso_2', 'Proceso_3']

        for item in payload:
            fila_orig = item.get('fila', '-')
            codigo = item.get('codigo', '-')
            excel_data = item.get('excel_data', {})
            bd_data = item.get('bd_data', {})
            errores = item.get('campos_error', [])
            
            # --- FILA 1: EXCEL ---
            ws.cell(row=current_row, column=1, value=fila_orig)
            ws.cell(row=current_row, column=2, value=codigo)
            ws.cell(row=current_row, column=3, value="EXCEL").font = Font(bold=True)
            
            for idx, key in enumerate(col_keys, start=4):
                ws.cell(row=current_row, column=idx, value=excel_data.get(key, ""))
            
            # --- FILA 2: BASE DE DATOS ---
            next_row = current_row + 1
            ws.cell(row=next_row, column=1, value=fila_orig)
            ws.cell(row=next_row, column=2, value=codigo)
            ws.cell(row=next_row, column=3, value="BASE DATOS").font = Font(bold=True)
            
            for idx, key in enumerate(col_keys, start=4):
                cell = ws.cell(row=next_row, column=idx, value=bd_data.get(key, ""))
                cell.fill = bd_row_fill # Default BD style
                
                # Highlight si hay error
                if key in errores:
                    cell.fill = error_fill
                    cell.font = Font(bold=True, color="CC0000")

            # Separador (Row vacía)
            current_row += 3 

        # Auto-width básico
        for col in ws.columns:
            max_length = 0
            column = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except:
                    pass
            adjusted_width = (max_length + 2)
            ws.column_dimensions[column].width = adjusted_width

        output = io.BytesIO()
        wb.save(output)
        output.seek(0)
        
        headers = {
            'Content-Disposition': 'attachment; filename="Reporte_Auditoria_Avanzado.xlsx"'
        }
        return Response(content=output.read(), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", headers=headers)

    except Exception as e:
        print(f"ERROR REPORTE: {e}")
        raise HTTPException(status_code=500, detail=str(e))

import ast

@app.get("/api/historial")
async def obtener_historial(busqueda: Optional[str] = None, limite: int = 50):
    print(f"--- CONSULTANDO HISTORIAL (Busqueda: {busqueda}, Limite: {limite}) ---")
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        query = """
            SELECT TOP (?) ID_Log, Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora 
            FROM Tbl_Auditoria_Cambios 
        """
        params = [limite]
        
        if busqueda:
            query += " WHERE Codigo_Pieza LIKE ? OR Usuario LIKE ? "
            search_term = f"%{busqueda}%"
            params.extend([search_term, search_term])
            
        query += " ORDER BY Fecha_Hora DESC"
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        
        historial = []
        for row in rows:
            val_ant = row[3]
            val_nue = row[4]
            
            # Intentar parsear Valor_Anterior
            if val_ant and isinstance(val_ant, str):
                try:
                    if val_ant.strip().startswith('{') or val_ant.strip().startswith('['):
                         val_ant = json.loads(val_ant.replace("'", '"')) # Attempt JSON fix or standard load
                    elif val_ant.strip().startswith('('):
                         val_ant = ast.literal_eval(val_ant)
                    else:
                         # Try literal eval for python dict repr
                         val_ant = ast.literal_eval(val_ant)
                except:
                    pass # Keep as string if fail

            # Intentar parsear Valor_Nuevo
            if val_nue and isinstance(val_nue, str):
                try:
                    if val_nue.strip().startswith('{') or val_nue.strip().startswith('['):
                         val_nue = json.loads(val_nue.replace("'", '"'))
                    elif val_nue.strip().startswith('('):
                         val_nue = ast.literal_eval(val_nue)
                    else:
                         val_nue = ast.literal_eval(val_nue)
                except:
                    pass

            historial.append({
                "id": row[0],
                "codigo": row[1],
                "accion": row[2],
                "valor_anterior": val_ant,
                "valor_nuevo": val_nue,
                "usuario": row[5],
                "fecha": row[6].strftime("%Y-%m-%d %H:%M:%S") if row[6] else None
            })
            
        return historial

    except Exception as e:
        print(f"ERROR HISTORIAL: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if 'conn' in locals(): conn.close()


# --- FASE 18: ESTANDARIZACIÓN DE DATOS ---

@app.get("/api/limpieza/descripciones_unicas")
async def get_unique_descriptions():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = """
            SELECT Descripcion, COUNT(Codigo_Pieza) as Total 
            FROM Tbl_Maestro_Piezas 
            WHERE Descripcion IS NOT NULL AND Descripcion != ''
            GROUP BY Descripcion 
            ORDER BY Descripcion ASC
        """
        cursor.execute(query)
        data = [{"descripcion": row[0], "total": row[1]} for row in cursor.fetchall()]
        return data
    except Exception as e:
         print(f"ERROR DESC UNICAS: {e}")
         raise HTTPException(status_code=500, detail=str(e))
    finally:
         conn.close()

class MasivoUpdate(BaseModel):
    old_desc: str
    new_desc: str
    usuario: str

@app.post("/api/limpieza/actualizar_masivo")
async def actualizar_masivo(payload: MasivoUpdate):
    print(f"--- INICIANDO ESTANDARIZACION MASIVA: '{payload.old_desc}' -> '{payload.new_desc}' ---")
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # 1. Obtener todas las piezas afectadas para auditoría individual
        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Descripcion = ?", (payload.old_desc,))
        piezas = cursor.fetchall()
        
        if not piezas:
             return {"status": "ignored", "message": "No se encontraron piezas con esa descripción."}
        
        actualizadas = 0
        
        # 2. Iterar y actualizar UNO A UNO
        for p in piezas:
            codigo = p[0]
            
            val_nuevo = ""
            
            # REGLA ESPEJO
            if globals().get('REGLA_ESPEJO_ACTIVA', True):
                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Descripcion = ?, Material = ?, Ultima_Actualizacion = GETDATE(), Modificado_Por = ?
                    WHERE Codigo_Pieza = ?
                """, (payload.new_desc, payload.new_desc, payload.usuario, codigo))
                val_nuevo = str({"Descripcion": payload.new_desc, "Material": payload.new_desc})
            else:
                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Descripcion = ?, Ultima_Actualizacion = GETDATE(), Modificado_Por = ?
                    WHERE Codigo_Pieza = ?
                """, (payload.new_desc, payload.usuario, codigo))
                val_nuevo = str({"Descripcion": payload.new_desc})
            
            if cursor.rowcount > 0:
                actualizadas += 1
                # Auditoría Individual
                registrar_auditoria(
                    cursor, 
                    codigo_pieza=codigo, 
                    accion='ESTANDARIZACION_MASIVA', 
                    valor_anterior=str({'Descripcion': payload.old_desc}), 
                    valor_nuevo=val_nuevo, 
                    usuario=payload.usuario
                )
        
        conn.commit()
        print(f"--- ESTANDARIZACION FINALIZADA: {actualizadas} piezas actualizadas ---")
        return {"status": "ok", "actualizadas": actualizadas}
        
    except Exception as e:
        conn.rollback()
        print(f"ERROR MASIVO: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
