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
    finally:
        conn.close()

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
        print("--- ✅ SISTEMA DE AUDITORIA INICIALIZADO CORRECTAMENTE ---")
    except Exception as e:
        print(f"--- ⚠️ ALERTA SQL (Auditoría): {e} ---")
    finally:
        try:
             conn.close()
        except:
             pass

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
                
                if cursor.rowcount > 0:
                    procesados += 1
                    # Log Auditoría CREACIÓN
                    try:
                        cursor.execute("""
                            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario)
                            VALUES (?, ?, ?, ?, ?)
                        """, (item.Codigo_Pieza, 'CREACION', 'NO EXISTIA', str(item.model_dump()), usuario))
                    except Exception as audit_e:
                        print(f"ERROR AUDITORIA INSERT: {audit_e}")
                
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
                    try:
                        cursor.execute("""
                            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario)
                            VALUES (?, ?, ?, ?, ?)
                        """, (item.Codigo_Pieza, 'MODIFICACION', val_anterior, str(item.model_dump()), usuario))
                    except Exception as audit_e:
                        print(f"ERROR AUDITORIA UPDATE: {audit_e}")

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
                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Link_Drive = ?, 
                        Ultima_Actualizacion = GETDATE(),
                        Modificado_Por = 'Sincronizador Excel'
                    WHERE Codigo_Pieza = ?
                """, (link, codigo))
                updated_count += cursor.rowcount

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

                
                updated_count += cursor.rowcount

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
    correcciones: str = Form(...), # JSON String
    file_path: str = Form(...) # Ruta local completa
):
    print(f"--- INICIANDO AUTOCORRECCIÓN SEGURA: {file_path} ---")
    
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="El archivo original no se encuentra en la ruta especificada.")

    try:
        corrections_list = json.loads(correcciones)
        
        # 1. RESPALDO CRÍTICO
        timestamp = datetime.now().strftime('%d-%m-%Y_%H%M%S')
        base, ext = os.path.splitext(file_path)
        backup_path = f"{base}-retirado-{timestamp}{ext}"
        
        os.rename(file_path, backup_path)
        print(f"Respaldo creado: {backup_path}")
        
        # 2. APLICAR CORRECCIONES (Sobre el respaldo, para guardar como nuevo original)
        wb = openpyxl.load_workbook(backup_path) # No data_only para preservar FÓRMULAS no afectadas
        ws = wb.active # Asumimos hoja activa. Idealmente deberíamos saber la hoja, pero para este caso sirve.
        
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
        
        # 3. GUARDAR COMO ORIGINAL
        wb.save(file_path)
        print(f"Archivo corregido guardado: {file_path} ({count} cambios)")
        
        return {"status": "ok", "mensaje": f"Se aplicaron {count} correcciones. Respaldo: {os.path.basename(backup_path)}"}

    except Exception as e:
        # Intentar restaurar si falló algo crítico después del rename?
        # Si falló rename, no pasa nada. Si falló save, tenemos backup.
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

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
