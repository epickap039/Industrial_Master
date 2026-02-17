import socket
import uvicorn
import pyodbc
import pandas as pd
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from typing import Dict, Any, List

# 1. CONFIGURACIÓN SQL (Auto-Detectada)
DB_SERVER = '192.168.1.73'
DB_PORT = 1433
DB_DATABASE = 'DB_Materiales_Industrial'
DB_DRIVER = '{ODBC Driver 17 for SQL Server}'

# Usando Autenticación de Windows (Trusted) ya que 'jaes_admin' falló.
CONNECTION_STRING = (
    f'DRIVER={DB_DRIVER};'
    f'SERVER={DB_SERVER},{DB_PORT};'
    f'DATABASE={DB_DATABASE};'
    'Trusted_Connection=yes;'
    'TrustServerCertificate=yes;'
)

# 2. SEGURIDAD Y PERMISOS
ADMIN_HOSTNAME = socket.gethostname()
# Resolver la IP del admin para comparaciones, aunque localhost (127.0.0.1) siempre es permitido localmente.
try:
    ADMIN_IP = socket.gethostbyname(ADMIN_HOSTNAME)
except:
    ADMIN_IP = "127.0.0.1"

# 4. INFRAESTRUCTURA (Lifespan)
@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"--- SERVER STARTED on {ADMIN_HOSTNAME} ---")
    print(f"--- LISTENING ON 0.0.0.0:8001 ---")
    
    # Inicializar Base de Datos de Usuarios
    try:
        init_auth_db()
    except Exception as e:
        print(f"ERROR INITIALIZING AUTH DB: {e}")
        
    yield
    print("--- SERVER SHUTTING DOWN ---")

app = FastAPI(title="Industrial Manager API", version="15.5", lifespan=lifespan)

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
        # 1. Crear Tabla si no existe
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
        
        # 2. Usuarios a insertar/actualizar
        users_to_seed = [
            ("jaes_admin", "Industrial.2026", "Admin"),
            ("ing_01", "Ing.2026", "User"),
            ("ing_02", "Ing.2026", "User"),
            ("ing_03", "Ing.2026", "User"),
            ("ing_04", "Ing.2026", "User"),
            ("ing_05", "Ing.2026", "User"),
            ("ing_06", "Ing.2026", "User"),
        ]
        
        print("Sincronizando Tbl_Usuarios...")
        for user, password, role in users_to_seed:
            # Upsert logic simple
            cursor.execute("SELECT ID FROM Tbl_Usuarios WHERE Username = ?", (user,))
            row = cursor.fetchone()
            if row:
                # Update password just in case
                cursor.execute("UPDATE Tbl_Usuarios SET Password = ?, Role = ? WHERE Username = ?", (password, role, user))
            else:
                # Insert
                cursor.execute("INSERT INTO Tbl_Usuarios (Username, Password, Role) VALUES (?, ?, ?)", (user, password, role))
        
        conn.commit()
        print("Tbl_Usuarios actualizada correctamente.")
        
    except Exception as e:
        conn.rollback()
        print(f"Error en init_auth_db: {e}")
        raise e
    finally:
        conn.close()

# 3. GESTIÓN DE DATOS (Mapeo)
@app.get("/api/catalog")
async def get_catalog():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = "SELECT * FROM Tbl_Maestro_Piezas"
        cursor.execute(query)
        
        # Obtener nombres de columnas
        columns = [column[0] for column in cursor.description]
        
        # Construir lista de diccionarios
        data = []
        for row in cursor.fetchall():
            # Crear diccionario, reemplazando None con "-"
            record = {}
            for col, val in zip(columns, row):
                record[col] = val if val is not None else "-"
            data.append(record)
            
        return data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# ... (Endpoints de Sync y Excel) ...

# 2. SEGURIDAD - Endpoint Protegido
@app.post("/api/excel/save")
async def save_excel(request: Request):
    client_host = request.client.host
    
    # Bloquear acceso si no es el Admin (Localhost o la IP de la máquina Admin)
    # Lista blanca de IPs permitidas: Localhost (IPv4/IPv6) y la propia IP de la máquina.
    allowed_ips = ["127.0.0.1", "::1", "localhost", ADMIN_IP]
    
    if client_host not in allowed_ips:
        print(f"Acceso DENEGADO a {client_host}. Solo permitido para {ADMIN_HOSTNAME} ({ADMIN_IP})")
        raise HTTPException(status_code=403, detail="Forbidden: Action reserved for Admin only.")
    
    return {"status": "success", "message": "Acceso permitido. (Lógica de guardado pendiente)"}

# 4. SINCRONIZACIÓN DRIVE - Endpoint Avanzado
from pydantic import BaseModel

class DriveSyncRequest(BaseModel):
    excel_path: str

@app.post("/api/sync/drive")
async def sync_drive_links(request: Request, payload: DriveSyncRequest):
    client_host = request.client.host
    
    # 1. Seguridad: Solo Admin
    allowed_ips = ["127.0.0.1", "::1", "localhost", ADMIN_IP]
    if client_host not in allowed_ips:
        raise HTTPException(status_code=403, detail="Forbidden: Action reserved for Admin only.")

    excel_path = payload.excel_path
    
    conn = get_db_connection()
    cursor = conn.cursor()
    updated_count = 0
    
    try:
        # 2. Verificar/Crear columna Link_Drive
        try:
            print("Verificando columna Link_Drive...")
            cursor.execute("SELECT Link_Drive FROM Tbl_Maestro_Piezas WHERE 1=0")
        except pyodbc.ProgrammingError:
            print("Columna Link_Drive no existe. Creándola...")
            conn.rollback() # Limpiar error anterior
            cursor.execute("ALTER TABLE Tbl_Maestro_Piezas ADD Link_Drive NVARCHAR(MAX)")
            conn.commit()
            print("Columna Link_Drive creada exitosamente.")

        # 3. Leer Excel con Pandas
        # Asumimos columnas: A=Codigo, B=Hipervinculo, C=Carpeta
        # Pandas lee 0-indexed: 0=A, 1=B, 2=C
        print(f"Leyendo archivo Excel: {excel_path}")
        df = pd.read_excel(excel_path, header=None, usecols=[0, 1, 2])
        df.columns = ['Codigo', 'Link', 'Carpeta']
        
        # Limpiar datos
        df = df.dropna(subset=['Codigo', 'Link']) # Ignorar si falta codigo o link
        
        print(f"Procesando {len(df)} filas...")

        # 4. Actualizar SQL
        for index, row in df.iterrows():
            codigo = str(row['Codigo']).strip()
            link = str(row['Link']).strip()
            
            # Ejecutar Update
            cursor.execute("""
                UPDATE Tbl_Maestro_Piezas 
                SET Link_Drive = ? 
                WHERE Codigo_Pieza = ?
            """, (link, codigo))
            
            if cursor.rowcount > 0:
                updated_count += 1
                
        conn.commit()
        print(f"Sincronización completada. Actualizados: {updated_count}")
        
        return {
            "status": "success",
            "message": f"Sincronización Completada. {updated_count} registros actualizados.",
            "updated_count": updated_count
        }

    except Exception as e:
        print(f"Error en sync_drive_links: {e}")
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error processing sync: {str(e)}")
    finally:
        if 'conn' in locals():
            conn.close()

# 5. AUTENTICACIÓN
class LoginRequest(BaseModel):
    username: str
    password: str

@app.post("/api/login")
async def login(payload: LoginRequest):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Validación SQL Directa
        # En producción: Usar Hashing (Bcrypt/Argon2) en lugar de texto plano
        cursor.execute("SELECT Role FROM Tbl_Usuarios WHERE Username = ? AND Password = ?", (payload.username, payload.password))
        row = cursor.fetchone()
        
        if row:
            role = row[0]
            # Token Mock
            return {
                "status": "success", 
                "token": f"token-{payload.username}-{role}", 
                "username": payload.username,
                "role": role
            }
        else:
            raise HTTPException(status_code=401, detail="Usuario o contraseña incorrectos")
            
    except Exception as e:
        print(f"Error en login: {e}")
        raise HTTPException(status_code=500, detail="Error interno de autenticación")
    finally:
        conn.close()

# 6. EDICIÓN DE MATERIALES
class MaterialUpdateRequest(BaseModel):
    Codigo: str
    Descripcion: str | None = None
    Medida: str | None = None
    Material: str | None = None
    # Aceptamos campos adicionales dinámicamente si es necesario, 
    # pero por seguridad explicitamos los más comunes.
    
@app.put("/api/material/update")
async def update_material(request: Request, payload: Dict[str, Any]):
    # Debug Inicial
    print(f"--- INICIO UPDATE MATERIAL ---")
    print(f"Payload recibido: {payload}")

    # 1. Identificar ID
    # El usuario indica que ID principal es 'Codigo_Pieza'
    codigo = payload.get('Codigo_Pieza') or payload.get('Codigo')
    
    if not codigo:
         print("ERROR: No se encontró 'Codigo_Pieza' ni 'Codigo' en el payload.")
         raise HTTPException(status_code=400, detail="Falta el campo 'Codigo_Pieza' o 'Codigo'")
    
    print(f"Identificador de pieza: {codigo}")

    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # 2. Construir Query Dinámica
        forbidden_fields = ['ID', 'Codigo', 'Codigo_Pieza', 'Ultima_Actualizacion', 'Modificado_Por', 'usuario'] 
        fields_to_update = []
        values = []
        
        for key, value in payload.items():
            if key not in forbidden_fields:
                fields_to_update.append(f"{key} = ?")
                values.append(value)
                
        if not fields_to_update:
            print("AVISO: No hay campos para actualizar.")
            return {"status": "ignored", "message": "No hay campos para actualizar"}
            
        # 3. Verificar Columna Modificado_Por (Migración al vuelo)
        try:
            cursor.execute("SELECT Modificado_Por FROM Tbl_Maestro_Piezas WHERE 1=0")
        except pyodbc.ProgrammingError:
            print("Columna Modificado_Por no existe. Creándola...")
            conn.rollback()
            cursor.execute("ALTER TABLE Tbl_Maestro_Piezas ADD Modificado_Por NVARCHAR(50)")
            conn.commit()
            print("Columna Modificado_Por creada.")

        # 4. Ejecutar Update (Con GETDATE() y Modificado_Por)
        usuario = payload.get('usuario') or 'Sistema'
        
        set_clause = ', '.join(fields_to_update)
        set_clause += ", Ultima_Actualizacion = GETDATE(), Modificado_Por = ?"
        values.append(usuario)
        
        query = f"UPDATE Tbl_Maestro_Piezas SET {set_clause} WHERE Codigo_Pieza = ?"
        values.append(codigo) 
        
        print(f"QUERY SQL: {query}")
        print(f"VALORES: {values}")
        
        cursor.execute(query, values)
        
        if cursor.rowcount == 0:
             # Fallback
             print("AVISO: No se actualizó ninguna fila con Codigo_Pieza. Intentando con Codigo...")
             query_fallback = f"UPDATE Tbl_Maestro_Piezas SET {set_clause} WHERE Codigo = ?"
             # Reusamos values
             # values: [campo1, campo2, ..., usuario, codigo] - codigo está al final
             print(f"QUERY FALLBACK: {query_fallback}")
             cursor.execute(query_fallback, values)
             
        if cursor.rowcount == 0:
             print("ERROR: No se encontró el registro (Rowcount=0).")
             raise HTTPException(status_code=404, detail="No se encontró el registro para actualizar")

        conn.commit()
        print(f"EXITO: {cursor.rowcount} filas actualizadas.")
        
        return {"status": "success", "message": "Registro actualizado correctamente"}
        
    except pyodbc.Error as db_err:
        print(f"ERROR SQL CRÍTICO: {db_err}")
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Database Error: {db_err}")
    except Exception as e:
        print(f"ERROR GENÉRICO UPDATE: {e}")
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        print("--- FIN UPDATE MATERIAL ---")
        conn.close()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
