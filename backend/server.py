import socket
import uvicorn
import pyodbc
import pandas as pd
import openpyxl
from fastapi import FastAPI, HTTPException, Request, Response, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from typing import Dict, Any, List, Optional
from pydantic import BaseModel, ConfigDict
import io

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
    except Exception as e:
        conn.rollback()
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
        
        # 2. Iterar filas (Start Row 6/7 - ajustamos a 7 para saltar headers complejos)
        start_row = 7 
        for row in ws.iter_rows(min_row=start_row, values_only=True):
            # Mapeo por índice (Asumiendo estructura estándar del BOM de Ingeniería)
            # Col 0 (A): N/A
            # Col 1 (B): Estacion
            # Col 2 (C): Ensamble
            # Col 3 (D): CODIGO_PIEZA (Clave)
            # Col 4 (E): DESCRIPCION
            # Col 5 (F): MEDIDA
            # Col 6 (G): MATERIAL
            
            if not row: continue

            # Forward Fill Logic (Herencia de valores padre)
            estacion = row[1] if row[1] is not None else last_estacion
            ensamble = row[2] if row[2] is not None else last_ensamble
            
            if estacion: last_estacion = estacion
            if ensamble: last_ensamble = ensamble

            # Validar Codigo Pieza (Columna D - Index 3)
            raw_codigo = row[3]
            codigo_pieza = str(raw_codigo).strip() if raw_codigo else None
            
            if not codigo_pieza or codigo_pieza.lower() in ['none', 'codigo', 'codigo_pieza', '']:
                continue

            scan_data.append({
                'Estacion': last_estacion,
                'Ensamble': last_ensamble,
                'Codigo_Pieza': codigo_pieza,
                'Cantidad': row[7] if len(row) > 7 else 0, # Asumiendo Cantidad en H
                'Descripcion_Excel': str(row[4]).strip() if row[4] else "",
                'Medida_Excel': str(row[5]).strip() if row[5] else "",
                'Material_Excel': str(row[6]).strip() if row[6] else ""
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
                procesados += 1
                
            elif item.Estado == "CONFLICTO":
                # Lógica de Actualización (UPDATE COMPLETO)
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
                procesados += 1

        conn.commit()
        return {"status": "ok", "message": f"{procesados} registros sincronizados exitosamente."}

    except Exception as e:
        conn.rollback()
        print(f"Error en sincronizacion: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error al sincronizar BD: {str(e)}")
    finally:
        conn.close()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
