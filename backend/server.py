import socket
import uvicorn
import math
import pyodbc
import pandas as pd
import openpyxl
from fastapi import FastAPI, HTTPException, Request, Response, UploadFile, File, Form, BackgroundTasks, Header
from fastapi.responses import StreamingResponse
from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from typing import Dict, Any, List, Optional
from pydantic import BaseModel, ConfigDict
from pathlib import Path
import io
import os
import sys
import re
import uuid
import shutil
import traceback

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

app = FastAPI(title="Industrial Manager API v60.0", version="60.0", lifespan=lifespan)

# === MATERIALES APROBADOS ===
class MaterialPayload(BaseModel):
    material: str

class LoginRequest(BaseModel):
    username: str
    password: str

@app.get("/")
def read_root():
    return {"status": "online", "message": "Servidor Industrial Manager Activo"}

@app.get("/api/health")
def health_check():
    """Un simple healthcheck de base de datos sin carga."""
    try:
        conn = get_db_connection()
        conn.close()
        return {"status": "ok", "db_connected": True}
    except Exception as e:
        return {"status": "error", "db_connected": False, "detail": str(e)}

@app.get("/api/dashboard/kpi")
def get_dashboard_kpis():
    """Calcula indicadores clave (KPI) para el lobby principal.
    AUDITADO (sin riesgo de producto cartesiano): el CTE sólo cruza
    BOM_Estructura → Ensambles → Estaciones → Maestro_Piezas.
    No hay JOIN a Tbl_Clientes_Configuracion en ninguna agregación."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Obtener conteo de piezas válidas vs huérfanas (Misma lógica que Analytics)
        cursor.execute("""
            WITH PiezasBase AS (
                SELECT 
                    COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            )
            SELECT 
                SUM(CASE WHEN MaterialLimpio != 'FALTA ASIGNAR EN CAD' AND (ISNULL(AreaLimpia, 0) > 0 OR ISNULL(LargoLimpio, 0) > 0 OR (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) > 0) THEN 1 ELSE 0 END) AS Piezas_Validas,
                SUM(CASE WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD' OR (ISNULL(AreaLimpia, 0) = 0 AND ISNULL(LargoLimpio, 0) = 0 AND (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) = 0) THEN 1 ELSE 0 END) AS Piezas_Huerfanas
            FROM PiezasBase
        """)
        row = cursor.fetchone()
        validas = int(row.Piezas_Validas or 0)
        huerfanas = int(row.Piezas_Huerfanas or 0)
        total = validas + huerfanas

        # 2. Cálculo de salud en Python
        salud_cad = (validas / total * 100.0) if total > 0 else 0.0

        # 3. Conteo de unidades físicas (VINs) registradas
        cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas")
        row_u = cursor.fetchone()
        total_unidades = int(row_u.Total or 0) if row_u else 0

        # 4. Versiones de ingeniería únicas — COUNT(DISTINCT) para no inflar
        #    cuando una versión tiene N listas de materiales o N clientes.
        cursor.execute(
            "SELECT COUNT(DISTINCT ID_Version) AS Total FROM Tbl_BOM_Revisiones"
        )
        row_v = cursor.fetchone()
        total_versiones = int(row_v.Total or 0) if row_v else 0

        return {
            "total_piezas":    total,
            "total_unidades":  total_unidades,
            "total_versiones": total_versiones,
            "merma_configurada": 15,
            "salud_cad": round(salud_cad, 2),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

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

class MaterialOficial(BaseModel):
    descripcion: str

@app.post("/api/materiales/oficial")
def agregar_material_oficial(payload: MaterialOficial):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)",
            (payload.descripcion.upper(),)
        )
        conn.commit()
        return {"status": "success", "message": "Material oficial guardado correctamente"}
    except pyodbc.IntegrityError:
        conn.rollback()
        # En caso de que el material ya exista (UNIQUE constraint)
        return {"status": "success", "message": "Material ya existe o se guardó correctamente"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en SQL Server al guardar material: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/materiales/oficial/{identificador}")
def eliminar_material_oficial(identificador: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Materiales_Aprobados WHERE Material = ?", (identificador,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Material no encontrado")
        conn.commit()
        return {"status": "success", "message": "Material oficial eliminado correctamente"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en SQL Server al eliminar material: {str(e)}")
    finally:
        conn.close()

# === MODULO: JERARQUIA DE PROYECTOS ===
class TractoPayload(BaseModel):
    nombre: str

class TipoProyectoPayload(BaseModel):
    id_tracto: int
    nombre: str

class VersionPayload(BaseModel):
    id_tipo: int
    nombre: str

class ClientePayload(BaseModel):
    id_version: int
    nombre: str

# === MODELOS BOM ===
class RevisionPayload(BaseModel):
    nombre_revision: Optional[str] = None  # Ignorado: nombre se auto-genera
    notas: Optional[str] = None

class VINPayload(BaseModel):
    vin: str
    notas: Optional[str] = None
    observaciones: Optional[str] = None

# === TAREA 1: Modelo ligero para reemplazar notas (sin vin obligatorio) ===
class NotasReplacePayload(BaseModel):
    observaciones: Optional[str] = None
    notas: Optional[str] = None

class DeleteVinPayload(BaseModel):
    password: str
    motivo: Optional[str] = None

class BranchingPayload(BaseModel):
    id_revision_origen: int
    tipo_cambio: str                       # 'GLOBAL' | 'ESPECIFICO'
    lista_clientes: Optional[List[int]] = None  # IDs para ESPECIFICO

class BugReportPayload(BaseModel):
    usuario: str
    modulo: str
    gravedad: str
    descripcion: str
    captura: Optional[str] = None


class ClonarPayload(BaseModel):
    id_revision_origen: int
    id_revision_destino: int
    rama_cliente: bool = False
    id_cliente_destino: Optional[int] = None

class PropagarPayload(BaseModel):
    codigo_pieza: str
    nueva_cantidad: float
    id_revisiones: list[int]

class EstacionPayload(BaseModel):
    id_revision: int
    nombre: str

class EnsamblePayload(BaseModel):
    id_estacion: int
    nombre: str

class BOMPayload(BaseModel):
    id_ensamble: int
    codigo_pieza: str
    cantidad: float

class AsignarRevisionPayload(BaseModel):
    id_revision_asignada: Optional[int] = None

class LogAuditoriaPayload(BaseModel):
    motivo: str = ""
    observaciones: str = ""

# Endpoints Tracto
@app.get("/api/proyectos/tractos")
def get_tractos():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Tracto, Nombre_Tracto FROM Tbl_Proyectos_Tracto ORDER BY Nombre_Tracto")
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@app.post("/api/proyectos/tractos")
def add_tracto(payload: TractoPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Proyectos_Tracto (Nombre_Tracto) VALUES (?)", (payload.nombre.upper(),))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"El Tracto '{payload.nombre}' ya existe o hay un error de integridad. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar tracto: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/proyectos/tractos/{id_tracto}")
def delete_tracto(id_tracto: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Proyectos_Tracto WHERE ID_Tracto = ?", (id_tracto,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()

# Endpoints Tipo de Proyecto
@app.get("/api/proyectos/tipos/{id_tracto}")
def get_tipos(id_tracto: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Tipo, Nombre_Tipo FROM Tbl_Tipos_Proyecto WHERE ID_Tracto = ? ORDER BY Nombre_Tipo", (id_tracto,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@app.post("/api/proyectos/tipos")
def add_tipo(payload: TipoProyectoPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Tipos_Proyecto (ID_Tracto, Nombre_Tipo) VALUES (?, ?)", (payload.id_tracto, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error al agregar Tipo. Verifica que no exista ya y que el Tracto sea válido. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/proyectos/tipos/{id_tipo}")
def delete_tipo(id_tipo: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Tipos_Proyecto WHERE ID_Tipo = ?", (id_tipo,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()

# Endpoints Version
@app.get("/api/proyectos/versiones/{id_tipo}")
def get_versiones(id_tipo: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Version, Nombre_Version FROM Tbl_Versiones_Ingenieria WHERE ID_Tipo = ? ORDER BY Nombre_Version", (id_tipo,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@app.post("/api/proyectos/versiones")
def add_version(payload: VersionPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Versiones_Ingenieria (ID_Tipo, Nombre_Version) VALUES (?, ?)", (payload.id_tipo, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error en inserción de Versión. Asegúrate de que el Tipo de Proyecto exista. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar versión: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/proyectos/versiones/{id_version}")
def delete_version(id_version: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Versiones_Ingenieria WHERE ID_Version = ?", (id_version,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError:
        conn.rollback()
        raise HTTPException(status_code=400, detail="No se puede eliminar esta versión porque hay clientes o unidades asignadas a ella. Desvincule los clientes primero.")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# Endpoints Clientes
@app.get("/api/proyectos/clientes/{id_version}")
def get_clientes(id_version: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Config_Cliente, Nombre_Cliente FROM Tbl_Clientes_Configuracion WHERE ID_Version = ? ORDER BY Nombre_Cliente", (id_version,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@app.post("/api/proyectos/clientes")
def add_cliente(payload: ClientePayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Clientes_Configuracion (ID_Version, Nombre_Cliente) VALUES (?, ?)", (payload.id_version, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error en inserción de Cliente. Asegúrate de que la Versión exista. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar cliente: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/proyectos/clientes/{id_cliente}")
def delete_cliente(id_cliente: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Clientes_Configuracion WHERE ID_Config_Cliente = ?", (id_cliente,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()
# === FIN JERARQUIA DE PROYECTOS ===

# === MAPA DE INGENIERÍA ===
@app.get("/api/mapa/jerarquia")
def get_mapa_jerarquia():
    """Devuelve el árbol completo: Tracto > Tipo > Versión > Revisiones."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                TR.ID_Tracto, TR.Nombre_Tracto,
                TP.ID_Tipo, TP.Nombre_Tipo,
                V.ID_Version, V.Nombre_Version,
                R.ID_Revision, R.Numero_Revision, R.Estado, R.Fecha_Creacion,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Nombre_Cliente
            FROM Tbl_Proyectos_Tracto TR
            JOIN Tbl_Tipos_Proyecto TP ON TP.ID_Tracto = TR.ID_Tracto
            JOIN Tbl_Versiones_Ingenieria V ON V.ID_Tipo = TP.ID_Tipo
            LEFT JOIN Tbl_BOM_Revisiones R ON R.ID_Version = V.ID_Version AND R.Estado = 'Aprobada'
            LEFT JOIN Tbl_Clientes_Configuracion C ON C.ID_Version = V.ID_Version
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """)
        rows = cursor.fetchall()
        # Construir árbol en Python
        tractos: dict = {}
        for r in rows:
            tid = r.ID_Tracto
            if tid not in tractos:
                tractos[tid] = {"id": tid, "nombre": r.Nombre_Tracto, "tipos": {}}
            tipos = tractos[tid]["tipos"]
            pid = r.ID_Tipo
            if pid not in tipos:
                tipos[pid] = {"id": pid, "nombre": r.Nombre_Tipo, "versiones": {}}
            versiones = tipos[pid]["versiones"]
            vid = r.ID_Version
            if vid not in versiones:
                versiones[vid] = {"id": vid, "nombre": r.Nombre_Version, "revisiones": []}
            if r.ID_Revision:
                versiones[vid]["revisiones"].append({
                    "id_revision": r.ID_Revision,
                    "numero_revision": r.Numero_Revision,
                    "estado": r.Estado,
                    "fecha_creacion": r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None,
                    "cliente": r.Nombre_Cliente
                })
        # Serializar a lista
        result = []
        for tracto in tractos.values():
            t = {"id": tracto["id"], "nombre": tracto["nombre"], "tipos": []}
            for tipo in tracto["tipos"].values():
                tp = {"id": tipo["id"], "nombre": tipo["nombre"], "versiones": []}
                for ver in tipo["versiones"].values():
                    tp["versiones"].append({
                        "id": ver["id"],
                        "nombre": ver["nombre"],
                        "revisiones": ver["revisiones"]
                    })
                t["tipos"].append(tp)
            result.append(t)
        return result
    finally:
        conn.close()

@app.get("/api/bom/where-used/{codigo_pieza}")
def get_where_used(codigo_pieza: str):
    """Búsqueda ascendente (Bottom-Up) para encontrar dónde se usa una pieza."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT 
                EN.ID_Ensamble,
                EN.Nombre_Ensamble,
                E.Cantidad,
                R.Numero_Revision AS Lista_BOM,
                V.Nombre_Version,
                TP.Nombre_Tipo AS Proyecto,
                TR.Nombre_Tracto AS Tracto,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Cliente
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            LEFT JOIN Tbl_Clientes_Configuracion C ON V.ID_Version = C.ID_Version
            WHERE E.Codigo_Pieza = ?
        """, (codigo_pieza.upper(),))
        rows = cursor.fetchall()
        
        result = []
        for r in rows:
            result.append({
                "id_ensamble": r.ID_Ensamble,
                "nombre_ensamble": r.Nombre_Ensamble,
                "cantidad": float(r.Cantidad),
                "lista_bom": f"Rev {r.Lista_BOM}",
                "version": r.Nombre_Version,
                "proyecto": r.Proyecto,
                "tracto": r.Tracto,
                "cliente": r.Cliente
            })
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === MRP / ESTADO DE CUENTA DE MATERIALES ===

@app.get("/api/mrp/revisiones")
def get_mrp_revisiones():
    """Lista DISTINCT de revisiones para el selector del MRPII.
    Usa subconsulta con STRING_AGG para obtener los clientes afectados
    sin multiplicar filas por el JOIN a Tbl_Clientes_Configuracion."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                R.ID_Revision,
                TR.Nombre_Tracto,
                TP.Nombre_Tipo,
                V.Nombre_Version,
                R.Numero_Revision,
                ISNULL(R.Estado, '') AS Estado,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = V.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Versiones_Ingenieria V  ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto      TP  ON V.ID_Tipo    = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto    TR  ON TP.ID_Tracto = TR.ID_Tracto
            -- Solo revisiones Aprobadas en el selector MRPII.
            -- Las OBSOLETAS y Borradores no deben usarse para cálculo de materiales.
            WHERE R.Estado = 'Aprobada'
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """)
        return [
            {
                "id_revision":         int(r.ID_Revision),
                "nombre_tracto":       r.Nombre_Tracto       or "",
                "nombre_tipo":         r.Nombre_Tipo         or "",
                "nombre_version":      r.Nombre_Version      or "",
                "numero_revision":     r.Numero_Revision,
                "estado":              r.Estado              or "",
                "clientes_afectados":  r.Clientes_Afectados  or "Ingeniería Base (Sin clientes)",
            }
            for r in cursor.fetchall()
        ]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@app.get("/api/mrp/calculate/{id_revision}")
def calculate_mrp(id_revision: int):
    """Calcula la consolidación de compras (MRP) con filtrado estricto y diagnóstico de huérfanos.
    Separa los Componentes Comerciales del cálculo de placas/perfiles."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # ── CTE base compartida (reutilizada en las tres queries) ─────────────
        _cte_base = """
        WITH PiezasBase AS (
            SELECT
                E.Codigo_Pieza,
                ISNULL(LTRIM(RTRIM(M.Descripcion)), '')  AS Descripcion,
                COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''),
                         NULLIF(LTRIM(RTRIM(M.Descripcion)), ''),
                         'FALTA ASIGNAR EN CAD')          AS MaterialLimpio,
                M.Espesor_Perfil_CAD,
                E.Cantidad,
                TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD,' mm',''),',',''),' ',''),'-','') AS FLOAT) AS LargoLimpio,
                TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD,' mm',''),',',''),' ',''),'-','') AS FLOAT) AS AnchoLimpio,
                TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD,' mm^2',''),',',''),' ',''),'-','') AS FLOAT) AS AreaLimpia
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles   EN ON E.ID_Ensamble  = EN.ID_Ensamble
            JOIN Tbl_Estaciones  ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            WHERE ES.ID_Revision = ?
        )
        """

        # ── 1. Materia Prima / Placas (excluye COMERCIAL) ────────────────────
        query_mrp = _cte_base + """
        SELECT
            MaterialLimpio  AS Material,
            ISNULL(CAST(Espesor_Perfil_CAD AS VARCHAR(50)), 'N/A') AS Calibre_Espesor,
            SUM(Cantidad)   AS Cantidad_Total_Piezas,
            SUM(Cantidad * ISNULL(LargoLimpio, 0.0)) AS Requerimiento_Longitud_mm,
            SUM(Cantidad * ISNULL(NULLIF(AreaLimpia, 0),
                (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)))) AS Requerimiento_Area_mm2
        FROM PiezasBase
        WHERE (ISNULL(AreaLimpia, 0) > 0
            OR ISNULL(LargoLimpio, 0) > 0
            OR (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) > 0)
          AND MaterialLimpio != 'FALTA ASIGNAR EN CAD'
          AND UPPER(MaterialLimpio) NOT LIKE '%COMERCIAL%'
          AND UPPER(Descripcion)    NOT LIKE '%COMERCIAL%'
        GROUP BY MaterialLimpio, Espesor_Perfil_CAD
        ORDER BY MaterialLimpio, Espesor_Perfil_CAD
        """
        cursor.execute(query_mrp, (id_revision,))
        rows_mrp = cursor.fetchall()

        mrp_calculado = []
        for r in rows_mrp:
            material_upper = r.Material.upper()
            req_area_mm2   = float(r.Requerimiento_Area_mm2)
            req_long_mm    = float(r.Requerimiento_Longitud_mm)

            sugerencia   = "N/A"
            scrap_factor = 1.15

            if any(x in material_upper for x in ['PERFIL', 'TUBO', 'BARRA', 'SOLERA', 'ANGULO', 'CANAL', 'HSS']):
                metros_totales = req_long_mm / 1000.0
                tramos_std = 12.0 if 'HSS' in material_upper else 6.0
                cantidad_tramos = math.ceil((metros_totales / tramos_std) * scrap_factor)
                sugerencia = f"Comprar {cantidad_tramos} Tramos de {int(tramos_std)} MT"
            else:
                m2_totales   = req_area_mm2 / 1_000_000.0
                area_placa_m2 = 3.72
                t_str         = "4'X10'"
                if   "8'X20'" in material_upper: area_placa_m2, t_str = 14.86, "8'X20'"
                elif "8'X30'" in material_upper: area_placa_m2, t_str = 22.30, "8'X30'"
                elif "5'X24'" in material_upper: area_placa_m2, t_str = 11.15, "5'X24'"
                cantidad_placas = math.ceil((m2_totales / area_placa_m2) * scrap_factor)
                sugerencia = f"Comprar {cantidad_placas} Placas de {t_str}"

            mrp_calculado.append({
                "Material":              r.Material,
                "Calibre_Espesor":       r.Calibre_Espesor,
                "Cantidad_Total_Piezas": float(r.Cantidad_Total_Piezas),
                "Requerimiento_Area_mm2":    req_area_mm2,
                "Requerimiento_Longitud_mm": req_long_mm,
                "Sugerencia_Compra":     sugerencia,
            })

        # ── 2. Componentes Comerciales (solo cantidad, sin placas) ────────────
        query_comerciales = _cte_base + """
        SELECT
            Codigo_Pieza,
            Descripcion,
            SUM(Cantidad) AS Cantidad_Total
        FROM PiezasBase
        WHERE UPPER(MaterialLimpio) LIKE '%COMERCIAL%'
           OR UPPER(Descripcion)    LIKE '%COMERCIAL%'
        GROUP BY Codigo_Pieza, Descripcion
        ORDER BY Descripcion, Codigo_Pieza
        """
        cursor.execute(query_comerciales, (id_revision,))
        rows_com = cursor.fetchall()

        componentes_comerciales = [
            {
                "Codigo_Pieza":  r.Codigo_Pieza,
                "Descripcion":   r.Descripcion,
                "Cantidad_Total": float(r.Cantidad_Total),
            }
            for r in rows_com
        ]

        # ── 3. Piezas sin medidas / sin material (huérfanas) ─────────────────
        query_orphans = _cte_base + """
        SELECT
            Codigo_Pieza,
            ISNULL((SELECT TOP 1 Nombre_Ensamble
                    FROM Tbl_Ensambles EN2
                    JOIN Tbl_BOM_Estructura E2 ON E2.ID_Ensamble = EN2.ID_Ensamble
                    WHERE E2.Codigo_Pieza = PiezasBase.Codigo_Pieza), 'N/A') AS Nombre_Ensamble,
            MaterialLimpio AS Material,
            Cantidad,
            CASE
                WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD'
                     AND (ISNULL(AreaLimpia,0)=0 AND ISNULL(LargoLimpio,0)=0
                          AND (ISNULL(LargoLimpio,0)*ISNULL(AnchoLimpio,0))=0)
                     THEN 'Sin Material ni Dimensiones'
                WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD' THEN 'Falta Asignar Material'
                ELSE 'Sin Dimensiones CAD'
            END AS Motivo_Rechazo
        FROM PiezasBase
        WHERE (ISNULL(AreaLimpia, 0) = 0
           AND ISNULL(LargoLimpio, 0) = 0
           AND (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) = 0)
           OR MaterialLimpio = 'FALTA ASIGNAR EN CAD'
        """
        cursor.execute(query_orphans, (id_revision,))
        rows_orphans = cursor.fetchall()

        piezas_sin_medidas = [
            {
                "Codigo_Pieza":   r.Codigo_Pieza,
                "Nombre_Ensamble": r.Nombre_Ensamble,
                "Material":        r.Material,
                "Cantidad":        float(r.Cantidad),
                "Motivo_Rechazo":  r.Motivo_Rechazo,
            }
            for r in rows_orphans
        ]

        return {
            "mrp_calculado":          mrp_calculado,
            "componentes_comerciales": componentes_comerciales,
            "piezas_sin_medidas":     piezas_sin_medidas,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.get("/api/analytics/dashboard/{id_revision}")
def get_analytics_dashboard(id_revision: str, exclude_ids: Optional[str] = None):
    """Obtiene métricas clave para el Dashboard de Analytics (Soporta 'global' o ID numérico).
    exclude_ids: cadena CSV de IDs de revisión a excluir del cálculo global.
    AUDITADO (sin riesgo de producto cartesiano): las 4 sub-consultas (top_piezas,
    distribucion_material, salud_cad, distribucion_ensambles) sólo cruzan
    BOM_Estructura → Ensambles → Estaciones → Maestro_Piezas.
    No hay JOIN a Tbl_Clientes_Configuracion en ninguna de ellas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Parsear lista de exclusión (CSV de enteros)
        excl_list: list[int] = []
        if exclude_ids:
            try:
                excl_list = [int(x.strip()) for x in exclude_ids.split(',') if x.strip()]
            except ValueError:
                pass  # IDs malformados → se ignoran silenciosamente
        excl_clause = (
            f"AND ES.ID_Revision NOT IN ({','.join(str(i) for i in excl_list)})"
            if excl_list else ""
        )

        # Lógica dinámica: Si es 'global' se saltan los filtros de revisión
        where_clause = ""
        where_clause_salud = ""
        if id_revision != 'global':
            try:
                id_int = int(id_revision)
                # Filtro para omitir piezas incompletas en métricas a nivel proyecto
                where_clause = f"""WHERE ES.ID_Revision = {id_int} 
                    AND (
                        COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), 'FALTA ASIGNAR EN CAD') != 'FALTA ASIGNAR EN CAD' 
                        AND (
                            TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) > 0 
                            OR TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) > 0 
                            OR (TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) * TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT)) > 0
                        )
                    ) {excl_clause}"""
                where_clause_salud = f"WHERE ES.ID_Revision = {id_int} {excl_clause}"
            except ValueError:
                raise HTTPException(status_code=400, detail="ID de revisión inválido")
        else:
            # Modo global: solo aplicar exclusiones si hay alguna
            if excl_list:
                where_clause      = f"WHERE 1=1 {excl_clause}"
                where_clause_salud = f"WHERE 1=1 {excl_clause}"

        # 1. Top 10 Piezas
        cursor.execute(f"""
            SELECT TOP 10 E.Codigo_Pieza, ISNULL(SUM(E.Cantidad), 0) AS Total_Piezas
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            {where_clause}
            GROUP BY E.Codigo_Pieza
            ORDER BY Total_Piezas DESC
        """)
        top_piezas = [{"Codigo_Pieza": r.Codigo_Pieza, "Total_Piezas": float(r.Total_Piezas or 0)} for r in cursor.fetchall()]

        # 2. Distribución de Materiales (m2)
        cursor.execute(f"""
            WITH PiezasBase AS (
                SELECT 
                    COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                    E.Cantidad,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause_salud if id_revision != 'global' else ""}
            )
            SELECT 
                MaterialLimpio AS Material,
                ISNULL(SUM(Cantidad * ISNULL(NULLIF(AreaLimpia, 0), (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)))) / 1000000.0, 0) AS Total_m2
            FROM PiezasBase
            WHERE MaterialLimpio != 'FALTA ASIGNAR EN CAD'
            GROUP BY MaterialLimpio
            ORDER BY Total_m2 DESC
        """)
        distribucion = [{"Material": r.Material, "Total_m2": float(r.Total_m2 or 0)} for r in cursor.fetchall()]

        # 3. Salud CAD (Valid vs Orphan)
        cursor.execute(f"""
            WITH PiezasBase AS (
                SELECT 
                    COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause_salud if id_revision != 'global' else ""}
            )
            SELECT 
                SUM(CASE WHEN MaterialLimpio != 'FALTA ASIGNAR EN CAD' AND (ISNULL(AreaLimpia, 0) > 0 OR ISNULL(LargoLimpio, 0) > 0 OR (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) > 0) THEN 1 ELSE 0 END) AS Piezas_Validas,
                SUM(CASE WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD' OR (ISNULL(AreaLimpia, 0) = 0 AND ISNULL(LargoLimpio, 0) = 0 AND (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) = 0) THEN 1 ELSE 0 END) AS Piezas_Huerfanas
            FROM PiezasBase
        """)
        salud = cursor.fetchone()
        salud_cad = {
            "Validas": int(salud.Piezas_Validas or 0) if salud else 0,
            "Huerfanas": int(salud.Piezas_Huerfanas or 0) if salud else 0
        }

        # 4. Distribución por Ensamble (Complejidad por Concentración de Piezas)
        # Si es global, usamos LEFT JOIN para no perder ensambles sin estación
        estaciones_join = "JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion" if id_revision != 'global' else "LEFT JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion"
        
        cursor.execute(f"""
            SELECT TOP 5 EN.Nombre_Ensamble, ISNULL(SUM(E.Cantidad), 0) AS Total_Piezas
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            {estaciones_join}
            JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            {where_clause}
            GROUP BY EN.Nombre_Ensamble
            ORDER BY Total_Piezas DESC
        """)
        rows_ens = cursor.fetchall()
        
        # Procesar para agrupar en "Otros" los que no son Top 5
        ensambles = []
        top_ids = [r.Nombre_Ensamble for r in rows_ens]
        for r in rows_ens:
            ensambles.append({"Ensamble": r.Nombre_Ensamble, "Total_Piezas": float(r.Total_Piezas or 0)})
            
        if top_ids:
            # Calcular "Otros"
            cursor.execute(f"""
                SELECT ISNULL(SUM(E.Cantidad), 0) AS Otros_Total
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                {estaciones_join}
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause}
                {"AND" if where_clause else "WHERE"} EN.Nombre_Ensamble NOT IN ({','.join(['?' for _ in top_ids])})
            """, top_ids)
            row_otros = cursor.fetchone()
            if row_otros and row_otros.Otros_Total and row_otros.Otros_Total > 0:
                ensambles.append({"Ensamble": "OTROS", "Total_Piezas": float(row_otros.Otros_Total)})

        sugerencia_texto = ""
        if rows_ens and rows_ens[0].Nombre_Ensamble:
            sugerencia_texto = f"Sugerencia: El ensamble '{rows_ens[0].Nombre_Ensamble}' concentra la mayoría de piezas"

        # 5. Conteo de listas de ingeniería únicas (por versión, no por cliente)
        cursor.execute(
            "SELECT COUNT(DISTINCT ID_Version) AS Total FROM Tbl_BOM_Revisiones"
        )
        row_v2 = cursor.fetchone()
        total_versiones = int(row_v2.Total or 0) if row_v2 else 0

        # 6. Conteo de unidades (VINs) — global o por revisión
        if id_revision == 'global':
            if excl_list:
                excl_ph = ','.join(str(i) for i in excl_list)
                cursor.execute(
                    f"SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas "
                    f"WHERE ID_Revision NOT IN ({excl_ph}) OR ID_Revision IS NULL"
                )
            else:
                cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas")
        else:
            cursor.execute(
                "SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?",
                (id_int,),
            )
        row_u2 = cursor.fetchone()
        total_unidades = int(row_u2.Total or 0) if row_u2 else 0

        return {
            "top_piezas":            top_piezas,
            "distribucion_material": distribucion,
            "salud_cad":             salud_cad,
            "distribucion_ensambles": ensambles,
            "sugerencia":            sugerencia_texto,
            "total_versiones":       total_versiones,
            "total_unidades":        total_unidades,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === NUBE DE ARCHIVOS VIN ===
VIN_FILES_BASE = r"C:\BDIV_Archivos\VINs"

@app.get("/api/vins/{id_vin}/archivos")
def get_archivos_vin(id_vin: int):
    """Lista archivos adjuntos de un VIN."""
    folder = os.path.join(VIN_FILES_BASE, str(id_vin))
    if not os.path.exists(folder):
        return []
    archivos = []
    for fname in os.listdir(folder):
        fpath = os.path.join(folder, fname)
        if os.path.isfile(fpath):
            archivos.append({
                "nombre": fname,
                "tamano_kb": round(os.path.getsize(fpath) / 1024, 1),
                "es_pdf": fname.lower().endswith(".pdf")
            })
    return archivos

@app.post("/api/vins/{id_vin}/subir_archivo")
async def subir_archivo_vin(id_vin: int, file: UploadFile = File(...), x_usuario: Optional[str] = Header(None)):
    """Sube y guarda un archivo en la carpeta del VIN en el servidor."""
    folder = os.path.join(VIN_FILES_BASE, str(id_vin))
    os.makedirs(folder, exist_ok=True)
    # Sanitizar nombre de archivo
    safe_name = re.sub(r"[^\w\.\-]", "_", file.filename or "archivo")
    dest = os.path.join(folder, safe_name)
    try:
        content = await file.read()
        with open(dest, "wb") as f:
            f.write(content)
        # === Auditoría de subida de archivo (columnas reales) ===
        try:
            usuario_log = x_usuario if x_usuario else "SISTEMA_VIN"
            conn_log = get_db_connection()
            cursor_log = conn_log.cursor()
            cursor_log.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_vin}", 'Subir Archivo', None, f"Archivo '{safe_name}' subido ({round(len(content)/1024,1)} KB)", usuario_log)
            )
            conn_log.commit()
            conn_log.close()
        except Exception:
            pass  # No interrumpir operación principal si falla el log
        return {"status": "success", "nombre": safe_name, "tamano_kb": round(len(content) / 1024, 1)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al guardar archivo: {str(e)}")

@app.get("/api/vins/{id_vin}/archivos/{nombre_archivo}")
async def descargar_archivo_vin(id_vin: int, nombre_archivo: str):
    """Descarga/abre un archivo adjunto del VIN."""
    safe_name = re.sub(r"[^\w\.\-]", "_", nombre_archivo)
    fpath = os.path.join(VIN_FILES_BASE, str(id_vin), safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(status_code=404, detail="Archivo no encontrado")
    def iterfile():
        with open(fpath, "rb") as f:
            yield from f
    media_type = "application/pdf" if safe_name.lower().endswith(".pdf") else "application/octet-stream"
    return StreamingResponse(iterfile(), media_type=media_type,
        headers={"Content-Disposition": f"inline; filename={safe_name}"})


# === HELPER: Registro de Auditoría ===
def registrar_log(cursor, id_revision: int, accion: str, detalle: str, motivo: str = ""):
    """Inserta un registro en Tbl_Log_Cambios_Ingenieria. Llamar dentro de una transacción abierta."""
    try:
        cursor.execute(
            "INSERT INTO Tbl_Log_Cambios_Ingenieria (ID_Revision, Accion, Detalle_Cambio, Motivo) VALUES (?, ?, ?, ?)",
            (id_revision, accion, detalle[:500], motivo[:300] if motivo else "")
        )
    except Exception:
        pass  # No interrumpir operación principal si falla el log

# === MODULO: BOM (Gestor de Listas) ===
@app.get("/api/bom/estaciones/{id_revision}")
def get_estaciones(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Estacion, ID_Revision, Nombre_Estacion, Orden FROM Tbl_Estaciones WHERE ID_Revision = ? ORDER BY Orden", (id_revision,))
        rows = cursor.fetchall()
        return [{"id": r.ID_Estacion, "id_revision": r.ID_Revision, "nombre": r.Nombre_Estacion, "orden": r.Orden} for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al obtener estaciones: {str(e)}")
    finally:
        conn.close()

@app.post("/api/bom/estaciones")
# Endpoints Revisiones
# --- Endpoints Revisiones (v60.0: agrupados por ID_Version, no por cliente) ---
@app.get("/api/bom/revisiones/version/{id_version}")
def get_revisiones_por_version(id_version: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT
                R.ID_Revision,
                R.ID_Version,
                R.Numero_Revision,
                R.Estado,
                R.Fecha_Creacion,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = R.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Revisiones R
            WHERE R.ID_Version = ?
            ORDER BY R.Numero_Revision
            """,
            (id_version,)
        )
        rows = cursor.fetchall()
        return [
            {
                "id_revision":        r.ID_Revision,
                "id_version":         r.ID_Version,
                "numero_revision":    r.Numero_Revision,
                "estado":             r.Estado,
                "fecha_creacion":     r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None,
                "clientes_afectados": r.Clientes_Afectados or "Ingeniería Base (Sin clientes)",
            }
            for r in rows
        ]
    finally:
        conn.close()

@app.post("/api/bom/revisiones/version/{id_version}")
def add_revision_version(id_version: int, payload: RevisionPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])
        # Nombre auto-generado "Revisión N"; notas se preservan en el log.
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        id_rev = cursor.fetchone()[0]
        notas_txt = f' | Anotaciones: "{payload.notas}"' if payload.notas else ""
        registrar_log(
            cursor, id_rev, "Creación",
            f"Revisión {siguiente_rev} creada para Versión ID {id_version}{notas_txt}",
        )
        conn.commit()
        return {"status": "success", "id_revision": id_rev, "numero_revision": siguiente_rev}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error creando revisión: {str(e)}")
    finally:
        conn.close()

# --- Compatibilidad legacy: revisiones por cliente (redirige a versión) ---
@app.get("/api/bom/revisiones/{id_cliente}")
def get_revisiones(id_cliente: int):
    """Legacy endpoint - mantiene compatibilidad con pantallas antiguas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Buscar revisiones cuya versión corresponde al cliente
        cursor.execute(
            """
            SELECT R.ID_Revision, R.Numero_Revision, R.Estado, R.Fecha_Creacion
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Clientes_Configuracion CC ON CC.ID_Version = R.ID_Version
            WHERE CC.ID_Config_Cliente = ?
            ORDER BY R.Numero_Revision
            """,
            (id_cliente,)
        )
        rows = cursor.fetchall()
        return [{"id_revision": r.ID_Revision, "numero_revision": r.Numero_Revision, "estado": r.Estado, "fecha_creacion": r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None} for r in rows]
    finally:
        conn.close()

@app.post("/api/bom/revisiones/{id_cliente}")
def add_revision(id_cliente: int, payload: RevisionPayload):
    """Legacy endpoint."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Version FROM Tbl_Clientes_Configuracion WHERE ID_Config_Cliente = ?", (id_cliente,))
        ver_row = cursor.fetchone()
        if not ver_row:
            raise HTTPException(status_code=404, detail="Cliente no encontrado")
        id_version = ver_row[0]
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        id_rev = cursor.fetchone()[0]
        notas_txt = f' | Anotaciones: "{payload.notas}"' if payload.notas else ""
        registrar_log(
            cursor, id_rev, "Creación",
            f"Revisión {siguiente_rev}{notas_txt} (vía cliente {id_cliente})",
        )
        conn.commit()
        return {"status": "success", "id_revision": id_rev}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error creando revisión: {str(e)}")
    finally:
        conn.close()

@app.put("/api/bom/revisiones/{id_revision}/aprobar")
def aprobar_revision(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Obtener la versión para marcar las demás revisiones como OBSOLETO
        cursor.execute(
            "SELECT ID_Version, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
        id_version = row.ID_Version

        # PASO 1: Primero desalojar cualquier revisión actualmente Aprobada
        #         (garantiza exclusividad antes de crear el nuevo "verde")
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'OBSOLETO' "
            "WHERE ID_Version = ? AND ID_Revision != ? AND Estado = 'Aprobada'",
            (id_version, id_revision),
        )
        prev_aprobadas = cursor.rowcount

        # PASO 2: Marcar todo lo demás también como OBSOLETO (Borradores huérfanos, etc.)
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'OBSOLETO' "
            "WHERE ID_Version = ? AND ID_Revision != ? AND Estado != 'OBSOLETO'",
            (id_version, id_revision),
        )
        obsoletas = prev_aprobadas + cursor.rowcount

        # PASO 3: Aprobar — ahora sí, sin riesgo de dos verdes simultáneos
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'Aprobada' WHERE ID_Revision = ?",
            (id_revision,),
        )
        registrar_log(
            cursor, id_revision, "APROBAR_REVISION",
            f"Revisión {id_revision} aprobada. {obsoletas} revisión(es) anterior(es) marcadas como OBSOLETO.",
        )
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()

# ── NUEVO v60.1: Borrado de Revisión (con protección para Aprobadas) ──────────
class EliminarRevisionPayload(BaseModel):
    password: str = ""
    motivo: str = ""

ADMIN_PASSWORD_INGENIERIA = "ADMIN_ING_2024"

@app.delete("/api/bom/revisiones/{id_revision}")
def eliminar_revision(id_revision: int, payload: EliminarRevisionPayload):
    """
    Borra una revisión y toda su estructura en cascada.
    - Borradores: no requieren contraseña.
    - Aprobadas: requieren la contraseña maestra de ingeniería.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Verificar existencia y estado
        cursor.execute(
            "SELECT Estado, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,)
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")

        estado = row.Estado
        numero_revision = row.Numero_Revision

        # 2. Regla de Negocio:
        #    - Borradores/PENDIENTE: se borran sin contraseña.
        #    - Aprobada/OBSOLETO   : solo con contraseña correcta.
        ESTADOS_EDITABLES = {"Borrador", "PENDIENTE"}
        if estado not in ESTADOS_EDITABLES:
            if payload.password != "ADMIN_ING_2024":
                raise HTTPException(status_code=401, detail="Clave incorrecta. Operación denegada.")

        # 3. Registrar en auditoría ANTES de borrar (sobrevive al borrado en cascada)
        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (
            f"REV-{numero_revision}",
            "ELIMINAR_REVISION",
            f"ID_Revision: {id_revision}, Estado: {estado}",
            f"Motivo: {payload.motivo or 'N/A'}",
            "SISTEMA_BOM"
        ))
        conn.commit()  # Asegurar que el log quede persistido

        # 4. Borrado en cascada manual (más seguro que CASCADE en FK)
        # 4a. Borrar piezas de todos los ensambles de todas las estaciones de esta revisión
        cursor.execute("""
            DELETE E FROM Tbl_BOM_Estructura E
            INNER JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            WHERE ES.ID_Revision = ?
        """, (id_revision,))

        # 4b. Borrar ensambles
        cursor.execute("""
            DELETE EN FROM Tbl_Ensambles EN
            INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            WHERE ES.ID_Revision = ?
        """, (id_revision,))

        # 4c. Borrar estaciones
        cursor.execute("DELETE FROM Tbl_Estaciones WHERE ID_Revision = ?", (id_revision,))

        # 4d. Borrar VINs ligados a la revisión
        cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?", (id_revision,))

        # 4e. Borrar la revisión
        cursor.execute("DELETE FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?", (id_revision,))

        conn.commit()
        return {"status": "success", "message": f"Revisión {numero_revision} eliminada correctamente."}

    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al eliminar revisión: {str(e)}")
    finally:
        conn.close()


# Endpoints VINs (Unidades Físicas)
@app.get("/api/bom/revisiones/{id_revision}/vins")
def get_vins(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Unidad, Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?", (id_revision,))
        rows = cursor.fetchall()
        return [{"id_unidad": r.ID_Unidad, "vin": r.VIN} for r in rows]
    finally:
        conn.close()

@app.get("/api/bom/buscar_pieza_jerarquia/{codigo_pieza}")
def buscar_pieza_jerarquia(codigo_pieza: str, exclude_rev: Optional[int] = None):
    """Búsqueda ascendente para el diálogo 'Propagar Cambios'.
    CORREGIDO: GROUP BY revision + STRING_AGG para clientes.
    Sin LEFT JOIN a Tbl_Clientes_Configuracion en el FROM → cero duplicados
    cuando una versión tiene múltiples clientes asociados."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # La subconsulta STRING_AGG reemplaza el LEFT JOIN directo que
        # producía N filas por revisión (una por cada cliente de la versión).
        base_query = """
            SELECT
                R.ID_Revision,
                TR.Nombre_Tracto,
                TP.Nombre_Tipo,
                V.Nombre_Version,
                V.ID_Version,
                R.Numero_Revision,
                R.Estado,
                SUM(E.Cantidad) AS Cantidad,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = V.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles           EN ON E.ID_Ensamble   = EN.ID_Ensamble
            JOIN Tbl_Estaciones          ES ON EN.ID_Estacion  = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones       R ON ES.ID_Revision  = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version    = V.ID_Version
            JOIN Tbl_Tipos_Proyecto      TP ON V.ID_Tipo       = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto    TR ON TP.ID_Tracto    = TR.ID_Tracto
            WHERE E.Codigo_Pieza = ?
        """
        params: list = [codigo_pieza]

        if exclude_rev:
            base_query += " AND R.ID_Revision != ?"
            params.append(exclude_rev)

        base_query += """
            GROUP BY
                R.ID_Revision, TR.Nombre_Tracto, TP.Nombre_Tipo,
                V.Nombre_Version, V.ID_Version,
                R.Numero_Revision, R.Estado
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """
        cursor.execute(base_query, params)
        return [
            {
                "id_revision":        r.ID_Revision,
                "tracto":             r.Nombre_Tracto,
                "tipo":               r.Nombre_Tipo,
                "version":            r.Nombre_Version,
                "clientes_afectados": r.Clientes_Afectados,
                "numero_revision":    r.Numero_Revision,
                "estado":             r.Estado,
                "cantidad":           float(r.Cantidad),
            }
            for r in cursor.fetchall()
        ]
    finally:
        conn.close()

@app.get("/api/bom/exportar/{id_revision}")
def exportar_bom(id_revision: int):
    """Exportación Pro: BOM + Historial de Auditoría en 2 pestañas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Pestaña 1: BOM
        cursor.execute(
            """
            SELECT ES.Nombre_Estacion, EN.Nombre_Ensamble, E.Codigo_Pieza,
                   M.Descripcion as Descripcion_Oficial, M.Medida, E.Cantidad,
                   M.Simetria, M.Proceso_Primario, M.Proceso_1, M.Proceso_2, M.Proceso_3, M.Link_Drive, E.Observaciones_Proceso
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            LEFT JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            WHERE ES.ID_Revision = ?
            ORDER BY ES.Orden, EN.Nombre_Ensamble
            """, (id_revision,)
        )
        bom_rows = cursor.fetchall()

        # Pestaña 2: Historial de Auditoría
        try:
            cursor.execute(
                "SELECT Usuario, Fecha_Hora, Accion, Detalle_Cambio, Motivo FROM Tbl_Log_Cambios_Ingenieria WHERE ID_Revision = ? ORDER BY Fecha_Hora DESC",
                (id_revision,)
            )
            log_rows = cursor.fetchall()
        except Exception:
            log_rows = []

        output = io.BytesIO()
        workbook = openpyxl.Workbook()

        # --- Pestaña 1: BOM (formato cliente: cabecera fila 5, datos desde fila 6) ---
        sheet_bom = workbook.active
        sheet_bom.title = "BOM"
        hdr_fill = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid") # Azul Industrial
        hdr_font = Font(bold=True, color="FFFFFF")
        hdr_align = Alignment(horizontal="center")

        COL_ESTACION  = 2  # B
        COL_ENSAMBLE  = 3  # C
        COL_CODIGO    = 4  # D
        COL_DESC      = 5  # E
        COL_MEDIDA    = 6  # F
        COL_CANTIDAD  = 7  # G
        COL_SIMETRIA  = 8  # H
        COL_PROC_PRI  = 9  # I
        COL_PROC_1    = 10 # J
        COL_PROC_2    = 11 # K
        COL_PROC_3    = 12 # L
        COL_LINK      = 13 # M
        COL_OBS       = 14 # N
        HDR_ROW = 5
        DATA_ROW_START = 6

        headers = {
            COL_ESTACION: "Estación", COL_ENSAMBLE: "Ensamble",
            COL_CODIGO: "Código Pieza", COL_DESC: "Descripción",
            COL_MEDIDA: "Medida", COL_CANTIDAD: "Cantidad",
            COL_SIMETRIA: "Simetría", COL_PROC_PRI: "Proceso Primario",
            COL_PROC_1: "Proceso 1", COL_PROC_2: "Proceso 2", COL_PROC_3: "Proceso 3",
            COL_LINK: "Link Plano", COL_OBS: "Observaciones"
        }
        for col_idx, text in headers.items():
            cell = sheet_bom.cell(row=HDR_ROW, column=col_idx, value=text)
            cell.font = hdr_font
            cell.fill = hdr_fill
            cell.alignment = hdr_align

        for row_offset, r in enumerate(bom_rows):
            row_num = DATA_ROW_START + row_offset
            sheet_bom.cell(row=row_num, column=COL_ESTACION,  value=str(r.Nombre_Estacion))
            sheet_bom.cell(row=row_num, column=COL_ENSAMBLE,  value=str(r.Nombre_Ensamble))
            sheet_bom.cell(row=row_num, column=COL_CODIGO,    value=str(r.Codigo_Pieza))
            sheet_bom.cell(row=row_num, column=COL_DESC,      value=str(r.Descripcion_Oficial))
            sheet_bom.cell(row=row_num, column=COL_MEDIDA,    value=str(r.Medida))
            # CANTIDAD COMO NÚMERO PURO (float)
            try:
                cant_val = float(r.Cantidad)
            except:
                cant_val = 0.0
            sheet_bom.cell(row=row_num, column=COL_CANTIDAD,  value=cant_val)

            sheet_bom.cell(row=row_num, column=COL_SIMETRIA,  value=str(r.Simetria))
            sheet_bom.cell(row=row_num, column=COL_PROC_PRI,  value=str(r.Proceso_Primario))
            sheet_bom.cell(row=row_num, column=COL_PROC_1,    value=str(r.Proceso_1))
            sheet_bom.cell(row=row_num, column=COL_PROC_2,    value=str(r.Proceso_2))
            sheet_bom.cell(row=row_num, column=COL_PROC_3,    value=str(r.Proceso_3))
            sheet_bom.cell(row=row_num, column=COL_LINK,      value=str(r.Link_Drive))
            sheet_bom.cell(row=row_num, column=COL_OBS,       value=str(r.Observaciones_Proceso))

        # Auto-fit simple
        for col in sheet_bom.columns:
            max_length = 0
            column = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except:
                    pass
            adjusted_width = (max_length + 2) * 1.2
            sheet_bom.column_dimensions[column].width = min(adjusted_width, 50)

        # Ancho de columnas usadas
        anchos = [
            (COL_ESTACION, 22), (COL_ENSAMBLE, 28), (COL_CODIGO, 18),
            (COL_DESC, 30), (COL_MEDIDA, 15), (COL_CANTIDAD, 10),
            (COL_SIMETRIA, 15), (COL_PROC_PRI, 18), (COL_PROC_1, 15),
            (COL_PROC_2, 15), (COL_PROC_3, 15), (COL_LINK, 25), (COL_OBS, 25)
        ]
        for col_idx, ancho in anchos:
            col_letter = sheet_bom.cell(row=1, column=col_idx).column_letter
            sheet_bom.column_dimensions[col_letter].width = ancho

        # --- Pestaña 2: Historial ---
        sheet_log = workbook.create_sheet(title="Historial de Cambios")
        log_fill = PatternFill(start_color="2E7D32", end_color="2E7D32", fill_type="solid")
        log_headers = ["Usuario", "Fecha / Hora", "Acción", "Detalle", "Motivo"]
        sheet_log.append(log_headers)
        for cell in sheet_log[1]:
            cell.font = hdr_font; cell.fill = log_fill; cell.alignment = hdr_align
        for r in log_rows:
            sheet_log.append([
                r.Usuario,
                r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else '',
                r.Accion, r.Detalle_Cambio, r.Motivo or ''
            ])

        workbook.save(output)
        output.seek(0)

        return StreamingResponse(
            output,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={"Content-Disposition": f"attachment; filename=BOM_Rev{id_revision}_v60.xlsx"}
        )
    finally:
        conn.close()

@app.get("/api/bom/log/{id_revision}")
def get_log_auditoria(id_revision: int):
    """ADN de Ingeniería: historial completo de cambios de una revisión."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT ID_Log, Usuario, Fecha_Hora, Accion, Detalle_Cambio, Motivo FROM Tbl_Log_Cambios_Ingenieria WHERE ID_Revision = ? ORDER BY Fecha_Hora DESC",
            (id_revision,)
        )
        rows = cursor.fetchall()
        return [{
            "id_log": r.ID_Log,
            "usuario": r.Usuario,
            "fecha_hora": r.Fecha_Hora.isoformat() if r.Fecha_Hora else None,
            "accion": r.Accion,
            "detalle": r.Detalle_Cambio,
            "motivo": r.Motivo or ""
        } for r in rows]
    except Exception:
        return []  # Si la tabla aún no existe, retorna lista vacía
    finally:
        conn.close()

@app.put("/api/proyectos/clientes/{id_cliente}/asignar_revision")
def asignar_revision_cliente(id_cliente: int, payload: AsignarRevisionPayload):
    """Vincula un cliente a una revisión maestra específica."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "UPDATE Tbl_Clientes_Configuracion SET ID_Revision_Asignada = ? WHERE ID_Config_Cliente = ?",
            (payload.id_revision_asignada, id_cliente)
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Cliente no encontrado")
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.post("/api/bom/revisiones/{id_revision}/vins")
def add_vin(id_revision: int, payload: VINPayload, x_usuario: Optional[str] = Header(None)):
    conn = get_db_connection()
    cursor = conn.cursor()
    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    try:
        val = payload.observaciones if payload.observaciones is not None else payload.notas
        cursor.execute(
            "INSERT INTO Tbl_Unidades_Fisicas (ID_Revision, Serie, Observaciones) OUTPUT INSERTED.ID_Unidad VALUES (?, ?, ?)", 
            (id_revision, payload.vin.upper(), val or "")
        )
        id_gen = cursor.fetchone()[0]

        # Log assignment
        cursor.execute("""
            SELECT R.Numero_Revision, V.Nombre_Version, TR.Nombre_Tracto
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            WHERE R.ID_Revision = ?
        """, (id_revision,))
        rev_info = cursor.fetchone()
        proyecto = f"{rev_info.Nombre_Tracto} - {rev_info.Nombre_Version} (Rev {rev_info.Numero_Revision})" if rev_info else str(id_revision)

        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (
            f"VIN-{payload.vin.upper()}",
            "VIN ASIGNADO",
            "N/A",
            f"Serie {payload.vin.upper()} vinculada a {proyecto}",
            usuario_real  # === TAREA 2: usuario real en lugar de string quemado ===
        ))

        # We also can log it in Tbl_Log_Cambios_Ingenieria if it's for the revision, but user says Tbl_Auditoria_Cambios
        registrar_log(cursor, id_revision, "VIN_CREADO", f"VIN {payload.vin.upper()} registrado a la revisión.")
        
        conn.commit()
        return {"status": "success", "id_unidad": id_gen}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al agregar VIN: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/bom/vins/{id_unidad}")
def delete_vin_simple(id_unidad: int, x_usuario: Optional[str] = Header(None)):
    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Log de auditoría antes de eliminar
        cursor.execute("SELECT Serie FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        row = cursor.fetchone()
        if row:
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, 'ELIMINAR_VIN', ?, ?, ?, GETDATE())",
                (f"VIN-{row.Serie}", row.Serie, "Eliminado desde gestor BOM", usuario_real)
            )
        cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()

# --- FUNCIONALIDADES AVANZADAS (FASE 8) ---

@app.get("/api/vins/buscar")
def buscar_vin(q: str):
    """Búsqueda de VINs por serie.
    CORREGIDO: subconsulta STRING_AGG para clientes en lugar de LEFT JOIN directo.
    El JOIN directo producía N copias del mismo VIN si su versión tenía N clientes."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = """
            SELECT
                u.ID_Unidad,
                u.Serie               AS VIN,
                u.Observaciones       AS Notas,
                u.ID_VIN_Asociado,
                r.ID_Revision,
                r.Numero_Revision,
                v.ID_Version,
                v.Nombre_Version,
                t.Nombre_Tipo,
                tr.Nombre_Tracto,
                socio.Serie           AS VIN_Asociado_Nombre,
                ISNULL(
                    (SELECT STRING_AGG(c2.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion c2
                     WHERE c2.ID_Version = v.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Nombre_Cliente
            FROM Tbl_Unidades_Fisicas u
            LEFT JOIN Tbl_BOM_Revisiones       r    ON u.ID_Revision      = r.ID_Revision
            LEFT JOIN Tbl_Versiones_Ingenieria v    ON r.ID_Version       = v.ID_Version
            LEFT JOIN Tbl_Tipos_Proyecto       t    ON v.ID_Tipo          = t.ID_Tipo
            LEFT JOIN Tbl_Proyectos_Tracto     tr   ON t.ID_Tracto        = tr.ID_Tracto
            LEFT JOIN Tbl_Unidades_Fisicas     socio ON u.ID_VIN_Asociado = socio.ID_Unidad
            WHERE u.Serie LIKE ?
        """
        cursor.execute(query, (f"%{q}%",))
        rows = cursor.fetchall()
        return [
            {
                "id_unidad":      r.ID_Unidad,
                "vin":            r.VIN,
                "notas":          r.Notas,
                "id_revision":    r.ID_Revision,
                "numero_revision": r.Numero_Revision,
                "cliente":        r.Nombre_Cliente,
                "version":        r.Nombre_Version,
                "tipo":           r.Nombre_Tipo,
                "tracto":         r.Nombre_Tracto,
                "id_socio":       r.ID_VIN_Asociado,
                "vin_socio":      r.VIN_Asociado_Nombre,
            }
            for r in rows
        ]
    finally:
        conn.close()

@app.get("/api/vins/{id_unidad}/adn")
def get_vin_adn(id_unidad: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT Serie as VIN, ID_Revision FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="VIN no encontrado")
        vin_str = row.VIN
        id_revision = row.ID_Revision

        eventos = []

        # 1. Movimientos propios del VIN desde Tbl_Auditoria_Cambios
        prefix = f"VIN-{vin_str}"
        cursor.execute("""
            SELECT Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora
            FROM Tbl_Auditoria_Cambios
            WHERE Codigo_Pieza = ?
        """, (prefix,))
        for ev in cursor.fetchall():
            eventos.append({
                "fecha": ev.Fecha_Hora.isoformat() if ev.Fecha_Hora else None,
                "titulo": ev.Accion,
                "detalle": ev.Valor_Nuevo,
                "usuario": ev.Usuario,
                "tipo": "VIN"
            })

        # 2. Movimientos de la revisión de Tbl_Log_Cambios_Ingenieria
        try:
            cursor.execute("""
                SELECT Accion, Detalle_Cambio, Usuario, Fecha_Hora
                FROM Tbl_Log_Cambios_Ingenieria
                WHERE ID_Revision = ?
            """, (id_revision,))
            for lr in cursor.fetchall():
                eventos.append({
                    "fecha": lr.Fecha_Hora.isoformat() if lr.Fecha_Hora else None,
                    "titulo": lr.Accion,
                    "detalle": lr.Detalle_Cambio,
                    "usuario": lr.Usuario,
                    "tipo": "REVISION"
                })
        except:
            pass # Si Tbl_Log_Cambios_Ingenieria doesn't exist yet, ignore
            
        # Ordenar cronológicamente descendente
        eventos.sort(key=lambda x: x['fecha'] or "", reverse=True)
        return eventos
    finally:
        conn.close()

@app.post("/api/vins/{id_unidad}/vincular/{id_socio}")
def vincular_vin(id_unidad: int, id_socio: int, x_usuario: Optional[str] = Header(None)):
    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        u1 = cursor.fetchone()
        if not u1:
            raise HTTPException(status_code=404, detail="Unidad no encontrada")

        if id_socio == 0:
            # Desvincular
            cursor.execute("SELECT ID_VIN_Asociado FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
            socio = cursor.fetchone()
            if socio and socio.ID_VIN_Asociado:
                cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_Unidad = ?", (socio.ID_VIN_Asociado,))
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_Unidad = ?", (id_unidad,))
            
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u1.VIN}", "VIN DESVINCULADO", "Combo disuelto", "Regresó a individual", usuario_real)  # === TAREA 2 ===
            )
            
        else:
            # Vincular (Bidireccional)
            cursor.execute("SELECT Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_socio,))
            u2 = cursor.fetchone()
            if not u2:
                raise HTTPException(status_code=404, detail="Socio no encontrado")
                
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = ? WHERE ID_Unidad = ?", (id_socio, id_unidad))
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = ? WHERE ID_Unidad = ?", (id_unidad, id_socio))
            
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u1.VIN}", "COMBO C3 CREADO", "Individual", f"Vinculado con VIN: {u2.VIN}", usuario_real)  # === TAREA 2 ===
            )
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u2.VIN}", "COMBO C3 CREADO", "Individual", f"Vinculado con VIN: {u1.VIN}", usuario_real)  # === TAREA 2 ===
            )

        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.put("/api/vins/{id_unidad}/notas")
def update_vin_notas(id_unidad: int, payload: VINPayload, x_usuario: Optional[str] = Header(None)):
    # === TAREA 2: Historial acumulativo – concatenar, no sobrescribir ===
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        nueva_nota = payload.observaciones if payload.observaciones is not None else (payload.notas or "")
        if not nueva_nota.strip():
            return {"status": "no_change"}

        usuario_real = x_usuario if x_usuario else "Operador"
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        entrada = f"[{timestamp}] {usuario_real}: {nueva_nota.strip()}"

        # Concatenar con separador de línea, no reemplazar
        cursor.execute("""
            UPDATE Tbl_Unidades_Fisicas
            SET Observaciones = CASE
                WHEN ISNULL(Observaciones, '') = '' THEN ?
                ELSE Observaciones + CHAR(13) + CHAR(10) + ?
            END
            WHERE ID_Unidad = ?
        """, (entrada, entrada, id_unidad))
        conn.commit()
        # === TAREA 3: Auditoría con conexión fresca (columnas reales de la tabla) ===
        try:
            conn2 = get_db_connection()
            cur2 = conn2.cursor()
            cur2.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_unidad}", 'Agregar Nota', None, entrada, usuario_real)
            )
            conn2.commit()
            conn2.close()
        except Exception:
            pass  # No interrumpir si falla el log
        return {"status": "success", "entrada": entrada}
    finally:
        conn.close()

# === Endpoint para REEMPLAZAR notas completas (usado al borrar una nota) ===
@app.put("/api/vins/{id_unidad}/notas_reemplazar")
def replace_vin_notas(id_unidad: int, payload: NotasReplacePayload, x_usuario: Optional[str] = Header(None)):
    """Sobrescribe Observaciones de la unidad indicada estrictamente por PK (ID_Unidad)."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        texto_completo = payload.observaciones if payload.observaciones is not None else (payload.notas or "")
        usuario_real = x_usuario if x_usuario else "Operador"

        # Obtener Serie antes del UPDATE para usar en auditoría
        cursor.execute("SELECT Serie FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        vin_row = cursor.fetchone()
        serie_label = f"VIN-{vin_row.Serie}" if vin_row else f"VIN-ID{id_unidad}"

        # Aislamiento estricto: WHERE por PK, nunca por Serie para evitar cruces
        cursor.execute(
            "UPDATE Tbl_Unidades_Fisicas SET Observaciones = ? WHERE ID_Unidad = ?",
            (texto_completo, id_unidad),
        )
        conn.commit()

        try:
            conn2 = get_db_connection()
            cur2 = conn2.cursor()
            cur2.execute(
                "INSERT INTO Tbl_Auditoria_Cambios "
                "(Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (serie_label, "Borrar Nota", None,
                 f"Nota eliminada del historial {serie_label}", usuario_real),
            )
            cur2.execute(
                "SELECT ID_Revision FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?",
                (id_unidad,),
            )
            rev_row = cur2.fetchone()
            if rev_row:
                registrar_log(cur2, rev_row.ID_Revision, "VIN_NOTA_BORRADA",
                              f"{serie_label}: nota eliminada.")
            conn2.commit()
            conn2.close()
        except Exception:
            pass
        return {"status": "success"}
    finally:
        conn.close()

# === TAREA 4: Borrar archivo físico de la Nube VIN ===
@app.delete("/api/vins/{id_vin}/archivos/{nombre_archivo}")
async def eliminar_archivo_vin(id_vin: int, nombre_archivo: str, x_usuario: Optional[str] = Header(None)):
    """Elimina físicamente un archivo adjunto del VIN del servidor."""
    safe_name = re.sub(r"[^\w\.\-]", "_", nombre_archivo)
    fpath = os.path.join(VIN_FILES_BASE, str(id_vin), safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(status_code=404, detail="Archivo no encontrado")
    try:
        os.remove(fpath)
        # === Auditoría de borrado de archivo (columnas reales) ===
        try:
            usuario_log = x_usuario if x_usuario else "SISTEMA_VIN"
            conn_log = get_db_connection()
            cur_log = conn_log.cursor()
            cur_log.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_vin}", 'Borrar Archivo', None, f"Archivo '{safe_name}' eliminado", usuario_log)
            )
            conn_log.commit()
            conn_log.close()
        except Exception:
            pass
        return {"status": "success", "eliminado": safe_name}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al eliminar: {str(e)}")

@app.delete("/api/vins/{serie}")
def delete_vin(serie: str, payload: DeleteVinPayload, x_usuario: Optional[str] = Header(None)):
    if payload.password != "ADMIN_ING_2024":
        raise HTTPException(status_code=401, detail="Contraseña incorrecta")

    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Check if VIN exists and get ID_Unidad and ID_Revision (for logging context)
        cursor.execute("SELECT ID_Unidad FROM Tbl_Unidades_Fisicas WHERE Serie = ?", (serie,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="VIN no encontrado")
        id_unidad = row.ID_Unidad

        # 1. Unlink from C3 if associated
        cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_VIN_Asociado = ?", (id_unidad,))

        # 2. Add audit log
        motivo_str = payload.motivo if payload.motivo else "Eliminación autorizada por administrador"
        cursor.execute(
            "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, 'ELIMINAR_VIN', ?, ?, ?, GETDATE())",
            (f"VIN-{serie}", serie, motivo_str, usuario_real)  # === TAREA 2: usuario real ===
        )

        # 3. Delete Physical record
        cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        conn.commit()
        
        # 4. Delete files related to this VIN
        try:
            folder_path = os.path.join(VIN_FILES_BASE, str(id_unidad))
            if os.path.exists(folder_path):
                shutil.rmtree(folder_path, ignore_errors=True)
        except Exception as e:
            pass # No bloqueamos si falla el borrado de archivos.

        return {"status": "success", "message": f"VIN {serie} eliminado correctamente"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"No se puede eliminar por restricciones de BD: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

def _next_codigo_ensamble_seq(cursor) -> list:
    """
    Devuelve una función generadora de códigos E-NNNN únicos.
    Lee el MAX actual una sola vez y entrega un callable que incrementa.
    """
    cursor.execute(
        "SELECT MAX(Codigo_Ensamble) FROM Tbl_Ensambles WHERE Codigo_Ensamble LIKE 'E-%'"
    )
    row = cursor.fetchone()
    seq = 0
    if row and row[0]:
        try:
            seq = int(row[0].split("-")[1]) + 1
        except (ValueError, IndexError):
            pass
    counter = [seq]

    def _next():
        code = f"E-{counter[0]:04d}"
        counter[0] += 1
        return code

    return _next


@app.post("/api/bom/clonar")
def clonar_bom(payload: ClonarPayload):
    """Copia la estructura de una revisión origen EN una revisión destino ya existente."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        next_code = _next_codigo_ensamble_seq(cursor)

        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones WHERE ID_Revision = ?",
            (payload.id_revision_origen,),
        )
        estaciones = cursor.fetchall()

        for est_orig in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (payload.id_revision_destino, est_orig.Nombre_Estacion, est_orig.Orden),
            )
            id_est_dest = cursor.fetchone()[0]

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?",
                (est_orig.ID_Estacion,),
            )
            for ens_orig in cursor.fetchall():
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (id_est_dest, next_code(), ens_orig.Nombre_Ensamble),
                )
                id_ens_dest = cursor.fetchone()[0]

                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens_orig.ID_Ensamble,),
                )
                for p in cursor.fetchall():
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (id_ens_dest, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )

        conn.commit()
        return {"status": "success", "detalle": f"Clonadas {len(estaciones)} estaciones."}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al clonar: {str(e)}")
    finally:
        conn.close()


@app.post("/api/bom/clonar/{id_revision_origen}")
def deep_copy_bom(id_revision_origen: int):
    """
    Deep Copy: crea una revisión nueva completa (Borrador) copiando toda la
    jerarquía Estaciones → Ensambles → BOM_Estructura del origen.
    Devuelve el nuevo ID_Revision y su Numero_Revision.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Verificar origen y obtener ID_Version
        cursor.execute(
            "SELECT ID_Version, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision_origen,),
        )
        origen = cursor.fetchone()
        if not origen:
            raise HTTPException(status_code=404, detail="Revisión origen no encontrada")
        id_version = origen.ID_Version
        num_rev_origen = origen.Numero_Revision

        # 2. Calcular el siguiente número de revisión para esta versión
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])

        # 3. Insertar nueva revisión en estado Borrador
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        nuevo_id_revision = cursor.fetchone()[0]

        # 4. Obtener generador de códigos únicos ANTES del loop
        next_code = _next_codigo_ensamble_seq(cursor)

        # 5. Clonar Estaciones con mapeo de IDs
        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones "
            "WHERE ID_Revision = ? ORDER BY Orden",
            (id_revision_origen,),
        )
        estaciones = cursor.fetchall()
        total_piezas = 0

        for est in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (nuevo_id_revision, est.Nombre_Estacion, est.Orden),
            )
            nuevo_id_estacion = cursor.fetchone()[0]

            # 6. Clonar Ensambles de esta estación
            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?",
                (est.ID_Estacion,),
            )
            ensambles = cursor.fetchall()

            for ens in ensambles:
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (nuevo_id_estacion, next_code(), ens.Nombre_Ensamble),
                )
                nuevo_id_ensamble = cursor.fetchone()[0]

                # 6. Clonar piezas del ensamble
                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens.ID_Ensamble,),
                )
                piezas = cursor.fetchall()
                total_piezas += len(piezas)

                for p in piezas:
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (nuevo_id_ensamble, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )

        registrar_log(
            cursor,
            nuevo_id_revision,
            "CLONAR_BOM",
            f"Deep copy desde Rev {num_rev_origen} (ID {id_revision_origen}). "
            f"{len(estaciones)} estaciones, {total_piezas} piezas.",
        )
        conn.commit()
        return {
            "nuevo_id_revision": nuevo_id_revision,
            "numero_revision": siguiente_rev,
            "estaciones_clonadas": len(estaciones),
            "piezas_clonadas": total_piezas,
        }
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al clonar BOM: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al clonar BOM: {str(e)}")
    finally:
        conn.close()


# ── Control de Cambios (ECR) ──────────────────────────────────────────────────
@app.post("/api/bom/branching")
def branching_ecr(payload: BranchingPayload):
    """
    Gatillo de Edición — PLM Change Control.

    GLOBAL   : Crea Rev N+1 en la misma versión clonando toda la BOM. Estado: Borrador.
    ESPECIFICO: Crea una nueva Versión de Ingeniería, mueve los clientes indicados
                y clona la BOM como Revisión 0. Estado: Borrador.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # ── 1. Verificar origen ───────────────────────────────────────────────
        cursor.execute(
            "SELECT ID_Version, Numero_Revision, Estado "
            "FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (payload.id_revision_origen,),
        )
        origen = cursor.fetchone()
        if not origen:
            raise HTTPException(status_code=404, detail="Revisión origen no encontrada.")
        id_version_origen = origen.ID_Version
        num_rev_origen    = origen.Numero_Revision

        # ── 2. Crear la nueva revisión según tipo ─────────────────────────────
        if payload.tipo_cambio == "GLOBAL":
            cursor.execute(
                "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones "
                "WHERE ID_Version = ?",
                (id_version_origen,),
            )
            siguiente_rev = int(cursor.fetchone()[0])
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
                (id_version_origen, siguiente_rev),
            )
            nuevo_id_revision = cursor.fetchone()[0]
            id_version_nueva  = id_version_origen

        elif payload.tipo_cambio == "ESPECIFICO":
            # Permitir ESPECIFICO sin clientes iniciales; el usuario los asigna luego.
            clientes_a_mover = payload.lista_clientes or []
            # Obtener ID_Tipo y nombre base de la versión origen
            cursor.execute(
                "SELECT ID_Tipo, Nombre_Version FROM Tbl_Versiones_Ingenieria "
                "WHERE ID_Version = ?",
                (id_version_origen,),
            )
            ver_orig = cursor.fetchone()
            if not ver_orig:
                raise HTTPException(status_code=404, detail="Versión origen no encontrada.")
            id_tipo     = ver_orig.ID_Tipo

            # Lógica secuencial pura PLM (V1, V2, V3...)
            cursor.execute(
                "SELECT Nombre_Version FROM Tbl_Versiones_Ingenieria WHERE ID_Tipo = ?",
                (id_tipo,),
            )
            nombres_existentes = [row[0] for row in cursor.fetchall()]
            max_v = 0
            for n in nombres_existentes:
                try:
                    if n.upper().startswith('V'):
                        num = int(n[1:])
                        if num > max_v:
                            max_v = num
                except ValueError:
                    pass

            nuevo_num = max_v + 1 if max_v > 0 else len(nombres_existentes) + 1
            nombre_fork = f"V{nuevo_num}"

            cursor.execute(
                "INSERT INTO Tbl_Versiones_Ingenieria (ID_Tipo, Nombre_Version) "
                "OUTPUT INSERTED.ID_Version VALUES (?, ?)",
                (id_tipo, nombre_fork),
            )
            id_version_nueva = cursor.fetchone()[0]

            # Mover clientes seleccionados a la nueva versión
            for id_cli in clientes_a_mover:
                cursor.execute(
                    "UPDATE Tbl_Clientes_Configuracion SET ID_Version = ? "
                    "WHERE ID_Config_Cliente = ?",
                    (id_version_nueva, id_cli),
                )

            # Crear Revisión 0 en la nueva versión
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, 0, 'Borrador')",
                (id_version_nueva,),
            )
            nuevo_id_revision = cursor.fetchone()[0]

            # Historial Global: Registrar derivación V1 -> V2
            registrar_log(
                cursor,
                nuevo_id_revision,
                'DERIVACION',
                f"Creada {nombre_fork} desde V1 original.",
                'Cambio Específico de Clientes',
            )
            siguiente_rev     = 0

        else:
            raise HTTPException(
                status_code=400,
                detail="tipo_cambio debe ser 'GLOBAL' o 'ESPECIFICO'.",
            )

        # ── 3. Clonar estructura BOM ──────────────────────────────────────────
        next_code = _next_codigo_ensamble_seq(cursor)

        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones "
            "WHERE ID_Revision = ? ORDER BY Orden",
            (payload.id_revision_origen,),
        )
        estaciones  = cursor.fetchall()
        total_piezas = 0

        for est in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (nuevo_id_revision, est.Nombre_Estacion, est.Orden),
            )
            nuevo_id_est = cursor.fetchone()[0]

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles "
                "WHERE ID_Estacion = ?",
                (est.ID_Estacion,),
            )
            for ens in cursor.fetchall():
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (nuevo_id_est, next_code(), ens.Nombre_Ensamble),
                )
                nuevo_id_ens = cursor.fetchone()[0]

                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens.ID_Ensamble,),
                )
                for p in cursor.fetchall():
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (nuevo_id_ens, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )
                    total_piezas += 1

        registrar_log(
            cursor, nuevo_id_revision, "ECR_BRANCHING",
            f"Rama {payload.tipo_cambio} desde Rev {num_rev_origen} (ID {payload.id_revision_origen}). "
            f"{len(estaciones)} estaciones, {total_piezas} piezas clonadas.",
        )
        conn.commit()
        return {
            "nuevo_id_revision": nuevo_id_revision,
            "numero_revision":   siguiente_rev,
            "id_version_nueva":  id_version_nueva,
            "tipo_cambio":       payload.tipo_cambio,
            "estaciones":        len(estaciones),
            "piezas":            total_piezas,
        }

    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en branching ECR: {str(e)}")
    finally:
        conn.close()


# === BLOQUE 3: BUSCADOR DE PLANOS DXF/PDF ===
RUTA_PLANOS = r"C:\Planos_Temporales"

# Palabras clave (en minúsculas) en el nombre de una carpeta que la marcan como basura.
# Se usa coincidencia de subcadena: si alguna de estas aparece en el nombre, se omite.
_CARPETAS_BASURA = {"obsoleto", "0-obsoleto", "soleto", "el soleto"}
_EXTENSIONES_PLANO = {".dxf", ".pdf"}

class BuscarPlanosPayload(BaseModel):
    codigos: List[str]
    ruta_base: str = ""   # Si se envía, tiene prioridad sobre RUTA_PLANOS

@app.post("/api/bom/buscar_planos")
def buscar_planos(payload: BuscarPlanosPayload):
    """
    Auditoría de planos: búsqueda RECURSIVA de archivos .dxf/.pdf.

    - Ignora carpetas cuyo nombre (en minúsculas) contenga palabras de _CARPETAS_BASURA.
    - Si un código aparece en varios archivos, conserva el de fecha de modificación
      más reciente (resolución de duplicados).
    - BLINDADO: nunca lanza HTTP 500 por problemas de ruta o permisos.
    """
    _safe_faltantes = [c.strip().upper() for c in payload.codigos if c.strip()]

    ruta_str = payload.ruta_base.strip() if payload.ruta_base.strip() else RUTA_PLANOS

    # ── Verificación defensiva de la ruta ────────────────────────────────────
    if not os.path.exists(ruta_str):
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Ruta no encontrada o inaccesible: {ruta_str}",
        }

    # ── Escaneo recursivo (una sola pasada) ───────────────────────────────────
    # Construimos: lista de tuplas (nombre_upper, nombre_original, mtime)
    # Modificar dirnames[:] en-lugar impide que os.walk descienda a carpetas basura.
    archivos_en_disco: list = []   # (nombre_upper, nombre_original, mtime)
    try:
        for dirpath, dirnames, filenames in os.walk(ruta_str):
            # Filtrar subcarpetas basura IN-PLACE ──────────────────────────────
            dirnames[:] = [
                d for d in dirnames
                if not any(kw in d.lower() for kw in _CARPETAS_BASURA)
            ]
            for fname in filenames:
                if os.path.splitext(fname)[1].lower() not in _EXTENSIONES_PLANO:
                    continue
                fpath = os.path.join(dirpath, fname)
                try:
                    mtime = os.path.getmtime(fpath)
                except OSError:
                    mtime = 0.0
                archivos_en_disco.append((fname.upper(), fname, mtime))
    except PermissionError:
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Sin permisos para leer la ruta: {ruta_str}",
        }
    except OSError as exc:
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Error de sistema al leer la ruta ({exc}): {ruta_str}",
        }

    # ── Matching de códigos con resolución de duplicados ─────────────────────
    encontrados: list = []
    faltantes: list = []

    for codigo in payload.codigos:
        codigo_limpio = codigo.strip().upper()
        if not codigo_limpio:
            continue

        # Recoger TODAS las coincidencias (puede haber el mismo código en varias carpetas)
        coincidencias = [
            (nombre_orig, mtime)
            for nombre_upper, nombre_orig, mtime in archivos_en_disco
            if codigo_limpio in nombre_upper
        ]

        if coincidencias:
            # Quedarse únicamente con el archivo más reciente
            mejor_archivo, _ = max(coincidencias, key=lambda x: x[1])
            encontrados.append({"codigo": codigo_limpio, "archivo": mejor_archivo})
        else:
            faltantes.append(codigo_limpio)

    return {"encontrados": encontrados, "faltantes": faltantes, "advertencia": None}


@app.post("/api/bom/propagar")
def propagar_cambios(payload: PropagarPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if not payload.id_revisiones:
            return {"status": "ignored", "mensaje": "No se seleccionaron revisiones"}
            
        # Generar placeholders para la lista de IDs
        placeholders = ",".join(["?"] * len(payload.id_revisiones))
        query = f"""
            UPDATE be
            SET be.Cantidad = ?
            FROM Tbl_BOM_Estructura be
            JOIN Tbl_Ensambles en ON be.ID_Ensamble = en.ID_Ensamble
            JOIN Tbl_Estaciones es ON en.ID_Estacion = es.ID_Estacion
            WHERE be.Codigo_Pieza = ? AND es.ID_Revision IN ({placeholders})
        """
        params = [payload.nueva_cantidad, payload.codigo_pieza] + payload.id_revisiones
        cursor.execute(query, params)
        affected = cursor.rowcount
        conn.commit()
        return {"status": "success", "afectados": affected}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en propagación: {str(e)}")
    finally:
        conn.close()

@app.get("/api/bom/estaciones/{id_revision}")
def get_estaciones(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Estacion, ID_Revision, Nombre_Estacion, Orden FROM Tbl_Estaciones WHERE ID_Revision = ? ORDER BY Orden", (id_revision,))
        rows = cursor.fetchall()
        return [{"id": r.ID_Estacion, "id_revision": r.ID_Revision, "nombre": r.Nombre_Estacion, "orden": r.Orden} for r in rows]
    finally:
        conn.close()

@app.post("/api/bom/estaciones")
def add_estacion(payload: EstacionPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) VALUES (?, ?, ?)", (payload.id_revision, payload.nombre.upper(), 0))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error al agregar Estación. Asegúrate de que no exista duplicada. Detalle: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL interno en Estación: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/bom/estaciones/{id_estacion}")
def delete_estacion(id_estacion: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Borrar piezas de sus ensambles
        cursor.execute("SELECT ID_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?", (id_estacion,))
        ensambles = cursor.fetchall()
        for ens in ensambles:
            cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?", (ens.ID_Ensamble,))
        
        # Borrar los ensambles
        cursor.execute("DELETE FROM Tbl_Ensambles WHERE ID_Estacion = ?", (id_estacion,))
        
        # Borrar la estacion
        cursor.execute("DELETE FROM Tbl_Estaciones WHERE ID_Estacion = ?", (id_estacion,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar estación: {str(e)}")
    finally:
        conn.close()

@app.get("/api/bom/ensambles/{id_estacion}")
def get_ensambles(id_estacion: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Ensamble, ID_Estacion, Codigo_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ? ORDER BY Nombre_Ensamble", (id_estacion,))
        rows = cursor.fetchall()
        return [{"id": r.ID_Ensamble, "id_estacion": r.ID_Estacion, "codigo_ensamble": r.Codigo_Ensamble, "nombre": r.Nombre_Ensamble} for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al obtener ensambles: {str(e)}")
    finally:
        conn.close()

@app.post("/api/bom/ensambles")
def add_ensamble(payload: EnsamblePayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Insertar ensamble
        cursor.execute(
            "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) VALUES (?, ?, ?)",
            (payload.id_estacion, "N/A", payload.nombre.upper())
        )
        # Recuperar ID_Revision para el log (via Tbl_Estaciones)
        cursor.execute("SELECT ID_Revision FROM Tbl_Estaciones WHERE ID_Estacion = ?", (payload.id_estacion,))
        rev_row = cursor.fetchone()
        if rev_row:
            registrar_log(cursor, rev_row.ID_Revision, "AGREGAR_ENSAMBLE",
                          f"Nuevo ensamble '{payload.nombre.upper()}' en estación {payload.id_estacion}.")
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error de integridad en Ensamble. Detalle: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL en Ensamble: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@app.get("/api/bom/{id_revision}/calcular_placas")
def calcular_placas(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT m.Material, m.Largo_CAD, m.Ancho_CAD, e.Cantidad,
                   ISNULL(m.Descripcion, '') AS Descripcion,
                   ISNULL(m.Codigo_Pieza, '') AS Codigo_Pieza
            FROM Tbl_BOM_Estructura e
            INNER JOIN Tbl_Maestro_Piezas m ON e.Codigo_Pieza = m.Codigo_Pieza
            INNER JOIN Tbl_Ensambles en ON e.ID_Ensamble = en.ID_Ensamble
            INNER JOIN Tbl_Estaciones es ON en.ID_Estacion = es.ID_Estacion
            WHERE es.ID_Revision = ? AND m.Largo_CAD > 0 AND m.Ancho_CAD > 0
              AND m.Material IS NOT NULL AND m.Material != ''
        """, (id_revision,))

        placas = {}
        compra_directa = {}

        for row in cursor.fetchall():
            material    = str(row.Material).strip()    if row.Material    else "Sin Especificar"
            descripcion = str(row.Descripcion).strip() if row.Descripcion else ""
            codigo      = str(row.Codigo_Pieza).strip() if row.Codigo_Pieza else ""
            cantidad    = float(row.Cantidad)

            # Piezas COMERCIALES → compra directa, sin cálculo de placas
            es_comercial = (
                "COMERCIAL" in material.upper() or
                "COMERCIAL" in descripcion.upper()
            )
            if es_comercial:
                clave = descripcion or codigo or material
                if clave not in compra_directa:
                    compra_directa[clave] = {"cantidad_total": 0, "codigo": codigo}
                compra_directa[clave]["cantidad_total"] += int(cantidad)
                continue

            largo  = float(row.Largo_CAD)
            ancho  = float(row.Ancho_CAD)
            area_pieza = largo * ancho
            area_total = area_pieza * cantidad

            if material not in placas:
                placas[material] = {"area_total_mm2": 0.0, "piezas_involucradas": 0}
            placas[material]["area_total_mm2"]    += area_total
            placas[material]["piezas_involucradas"] += int(cantidad)

        return {"placas": placas, "compra_directa": compra_directa}
    except pyodbc.Error as e:
        raise HTTPException(status_code=500, detail=f"Error SQL en cálculo de placas: {str(e)}")
    finally:
        conn.close()

@app.delete("/api/bom/ensambles/{id_ensamble}")
def delete_ensamble(id_ensamble: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Borrar piezas
        cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?", (id_ensamble,))
        
        # Borrar ensamble
        cursor.execute("DELETE FROM Tbl_Ensambles WHERE ID_Ensamble = ?", (id_ensamble,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar ensamble: {str(e)}")
    finally:
        conn.close()

@app.get("/api/bom/estructura/{id_ensamble}")
def get_bom_estructura(id_ensamble: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT e.ID_BOM, e.Codigo_Pieza, m.Descripcion, e.Cantidad, e.Observaciones_Proceso
            FROM Tbl_BOM_Estructura e
            LEFT JOIN Tbl_Maestro_Piezas m ON e.Codigo_Pieza = m.Codigo_Pieza
            WHERE e.ID_Ensamble = ?
        """, (id_ensamble,))
        rows = cursor.fetchall()
        return [{
            "id": r.ID_BOM,
            "codigo": r.Codigo_Pieza,
            "descripcion": getattr(r, 'Descripcion', 'Descripción no encontrada') if getattr(r, 'Descripcion', None) else "Descripción no encontrada",
            "cantidad": r.Cantidad,
            "observaciones": r.Observaciones_Proceso or ""
        } for r in rows]
    except pyodbc.Error as e:
        raise HTTPException(status_code=500, detail=f"Error SQL al obtener estructura: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error interno al obtener estructura: {str(e)}")
    finally:
        conn.close()

@app.post("/api/bom/estructura")
def add_bom_estructura(payload: BOMPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            INSERT INTO Tbl_BOM_Estructura (ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso)
            VALUES (?, ?, ?, ?)
        """, (payload.id_ensamble, payload.codigo_pieza, payload.cantidad, payload.observaciones))
        # Recuperar ID_Revision para el log
        cursor.execute("""
            SELECT ES.ID_Revision FROM Tbl_Ensambles EN
            INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            WHERE EN.ID_Ensamble = ?
        """, (payload.id_ensamble,))
        rev_row = cursor.fetchone()
        if rev_row:
            registrar_log(cursor, rev_row.ID_Revision, "AGREGAR_PIEZA",
                          f"Pieza '{payload.codigo_pieza}' x{payload.cantidad} agregada al ensamble {payload.id_ensamble}.")
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error de integridad en BOM. Verifica Código existete: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL en BOM_Estructura: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.delete("/api/bom/estructura/{id_bom}")
def delete_bom_estructura(id_bom: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_BOM = ?", (id_bom,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar BOM_Estructura: {str(e)}")
    finally:
        conn.close()

class BOMPiezaUpdate(BaseModel):
    cantidad: float


# ─── Modelos de respuesta BOM (todos los campos Optional para evitar validación rígida) ───
class PiezaArbolItem(BaseModel):
    """Pieza dentro del árbol BOM (estación → ensamble → pieza)."""
    model_config = ConfigDict(extra="allow")  # Permite campos extra sin fallar
    id: int
    id_estructura: Optional[int] = None   # Alias explícito del PK de Tbl_BOM_Estructura
    codigo: str
    descripcion: Optional[str] = ""
    cantidad: float
    observaciones: Optional[str] = ""
    simetria: Optional[str] = ""
    material: Optional[str] = ""
    medida: Optional[str] = ""
    proceso_primario: Optional[str] = ""
    proceso_1: Optional[str] = ""
    proceso_2: Optional[str] = ""
    proceso_3: Optional[str] = ""
    link_drive: Optional[str] = ""
    largo_cad: Optional[str] = ""
    ancho_cad: Optional[str] = ""
    espesor_cad: Optional[str] = ""
    tiene_dxf: Optional[str] = "No"


class PiezaPlanaItem(BaseModel):
    """Fila de la vista plana BOM (explosión jerárquica)."""
    model_config = ConfigDict(extra="allow")
    nivel: int
    codigo_padre: Optional[str] = ""
    codigo_pieza: Optional[str] = ""
    descripcion: Optional[str] = ""
    cantidad: Optional[float] = None
    material: Optional[str] = ""
    medida: Optional[str] = ""
    proceso_primario: Optional[str] = ""
    proceso_1: Optional[str] = ""
    proceso_2: Optional[str] = ""
    proceso_3: Optional[str] = ""
    largo_cad: Optional[str] = ""
    ancho_cad: Optional[str] = ""
    espesor_cad: Optional[str] = ""
    tiene_dxf: Optional[str] = "No"
    nombre_estacion: Optional[str] = ""
    nombre_ensamble: Optional[str] = ""
    id_bom: Optional[int] = None
    id_estructura: Optional[int] = None   # Alias explícito del PK de Tbl_BOM_Estructura


# ─── Schema-adaptive helpers ────────────────────────────────────────────────

# Caché a nivel de módulo: se llena la primera vez que se llama a
# _get_maestro_cols() y se reutiliza en todas las requests siguientes.
# Elimina la necesidad de abrir un cursor extra por cada request de árbol/plana.
_MAESTRO_COLS_CACHE: set = set()


def _get_maestro_cols() -> set:
    """
    Devuelve el conjunto (mayúsculas) de columnas de Tbl_Maestro_Piezas.

    Abre su PROPIA conexión privada (no comparte nada con el caller),
    la cierra antes de regresar y cachea el resultado para requests futuras.
    Esto elimina el error "Connection is busy" de ODBC Driver 17/18 que
    ocurría al abrir un segundo cursor sobre la misma conexión que ya
    tiene otro cursor abierto.
    """
    global _MAESTRO_COLS_CACHE
    if _MAESTRO_COLS_CACHE:            # ya inicializado → devolver caché
        return _MAESTRO_COLS_CACHE
    conn2 = None
    try:
        conn2 = get_db_connection()
        cur   = conn2.cursor()
        cur.execute("SELECT TOP 0 * FROM Tbl_Maestro_Piezas")
        _MAESTRO_COLS_CACHE = {col[0].upper() for col in cur.description}
        return _MAESTRO_COLS_CACHE
    except Exception:
        return set()           # fallback: expresiones usarán literales '' / 0
    finally:
        if conn2:
            conn2.close()


def _build_maestro_exprs(avail: set) -> dict:
    """
    Dada la lista de columnas disponibles en Tbl_Maestro_Piezas,
    devuelve un dict con las expresiones SQL listas para inyectar en
    el SELECT de piezas.  Se llama UNA VEZ y el resultado se reutiliza
    en todos los ensambles del árbol.
    """
    def _safe_str(col: str, width: int = 200) -> str:
        return (f"ISNULL(m.{col}, '')" if col.upper() in avail else "''")

    def _safe_num_str(col: str) -> str:
        return (f"ISNULL(TRY_CAST(m.{col} AS NVARCHAR(50)), '')"
                if col.upper() in avail else "''")

    if 'TIENE_DXF' in avail:
        dxf = "CAST(ISNULL(m.Tiene_DXF, 0) AS INT)"
    elif 'LINK_DRIVE' in avail:
        dxf = ("CASE WHEN m.Link_Drive IS NOT NULL "
               "AND LEN(ISNULL(m.Link_Drive,'')) > 0 THEN 1 ELSE 0 END")
    else:
        dxf = "0"

    return {
        "material":        _safe_str("Material"),
        "medida":          _safe_str("Medida"),
        "simetria":        _safe_str("Simetria"),
        "descripcion":     (_safe_str("Descripcion") if "DESCRIPCION" in avail
                            else "''"),
        "proc_prim":       _safe_str("Proceso_Primario"),
        "proc1":           _safe_str("Proceso_1"),
        "proc2":           _safe_str("Proceso_2"),
        "proc3":           _safe_str("Proceso_3"),
        "link_drive":      _safe_str("Link_Drive"),
        "largo_cad":       _safe_num_str("Largo_CAD"),
        "ancho_cad":       _safe_num_str("Ancho_CAD"),
        "espesor_cad":     _safe_num_str("Espesor_Perfil_CAD"),
        "tiene_dxf":       dxf,
    }

def _get_estado_revision_for_bom(cursor, id_bom: int) -> str:
    """Devuelve el Estado de la revisión a la que pertenece un registro BOM."""
    cursor.execute("""
        SELECT R.Estado
        FROM Tbl_BOM_Estructura E
        JOIN Tbl_Ensambles     EN ON E.ID_Ensamble  = EN.ID_Ensamble
        JOIN Tbl_Estaciones    ES ON EN.ID_Estacion = ES.ID_Estacion
        JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
        WHERE E.ID_BOM = ?
    """, (id_bom,))
    row = cursor.fetchone()
    return row.Estado if row else ""

def _assert_bom_editable(cursor, id_bom: int):
    """Lanza 403 si la revisión está bloqueada (Aprobada u OBSOLETO)."""
    estado = _get_estado_revision_for_bom(cursor, id_bom)
    if estado in ("Aprobada", "OBSOLETO"):
        raise HTTPException(
            status_code=403,
            detail="No se puede editar una ingeniería bloqueada. Inicia un cambio ECR.",
        )

# Endpoint canónico utilizado por el frontend (alias del anterior)
@app.put("/api/bom/estructura/cantidad/{id_bom}")
def update_bom_cantidad(id_bom: int, payload: BOMPiezaUpdate):
    """PUT canónico para actualizar cantidad de una pieza BOM.
    Incluye verificación de estado: rechaza edición si la revisión está bloqueada."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if payload.cantidad <= 0:
            raise HTTPException(status_code=400, detail="La cantidad debe ser mayor a 0.")
        _assert_bom_editable(cursor, id_bom)
        cursor.execute(
            "UPDATE Tbl_BOM_Estructura SET Cantidad = ? WHERE ID_BOM = ?",
            (payload.cantidad, id_bom),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Pieza de BOM no encontrada.")
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al actualizar cantidad: {str(e)}")
    finally:
        conn.close()

# Alias legacy — conserva compatibilidad si algo llama al endpoint antiguo
@app.put("/api/bom/piezas/{id_bom}")
def update_bom_pieza(id_bom: int, payload: BOMPiezaUpdate):
    """Legacy: redirige a la misma lógica que update_bom_cantidad."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if payload.cantidad <= 0:
            raise HTTPException(status_code=400, detail="La cantidad debe ser mayor a 0.")
        _assert_bom_editable(cursor, id_bom)
        cursor.execute(
            "UPDATE Tbl_BOM_Estructura SET Cantidad = ? WHERE ID_BOM = ?",
            (payload.cantidad, id_bom),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Pieza de BOM no encontrada.")
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al actualizar la pieza: {str(e)}")
    finally:
        conn.close()

@app.get("/api/bom/arbol/{id_revision}")
def get_bom_arbol(id_revision: int):
    """
    Árbol BOM de 3 niveles: Estación → Ensamble → Pieza.

    Usa UN SOLO cursor para todas las queries (patrón secuencial original).
    LEFT JOIN a Tbl_Maestro_Piezas con ISNULL para evitar nulos de BD.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # SQL de piezas: LEFT JOIN + ISNULL explícitos (sincronizado con esquema Pydantic)
        pieza_sql = """
            SELECT
                e.ID_BOM,
                e.Codigo_Pieza,
                e.Cantidad,
                ISNULL(e.Observaciones_Proceso, '') AS Observaciones_Proceso,
                ISNULL(M.Descripcion, '') AS Descripcion,
                ISNULL(M.Simetria, '') AS Simetria,
                ISNULL(M.Material, '') AS Material,
                ISNULL(M.Medida, '') AS Medida,
                ISNULL(M.Proceso_Primario, '') AS Proceso_Primario,
                ISNULL(M.Proceso_1, '') AS Proceso_1,
                ISNULL(M.Proceso_2, '') AS Proceso_2,
                ISNULL(M.Proceso_3, '') AS Proceso_3,
                ISNULL(M.Link_Drive, '') AS Link_Drive,
                ISNULL(TRY_CAST(M.Largo_CAD AS NVARCHAR(50)), '') AS Largo_CAD,
                ISNULL(TRY_CAST(M.Ancho_CAD AS NVARCHAR(50)), '') AS Ancho_CAD,
                ISNULL(TRY_CAST(M.Espesor_Perfil_CAD AS NVARCHAR(50)), '') AS Espesor_CAD,
                ISNULL(M.Tiene_DXF, 'No') AS Tiene_DXF
            FROM Tbl_BOM_Estructura e
            LEFT JOIN Tbl_Maestro_Piezas M ON e.Codigo_Pieza = M.Codigo_Pieza
            WHERE e.ID_Ensamble = ?
        """

        # ── 2. Árbol con cursor único, acceso secuencial (fetchall completo
        #       antes de la siguiente execute — sin resultados pendientes) ──
        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden "
            "FROM Tbl_Estaciones WHERE ID_Revision = ? ORDER BY Orden",
            (id_revision,)
        )
        estaciones = cursor.fetchall()   # completo → cursor libre

        arbol = []
        for est in estaciones:
            est_dict = {
                "id":        est.ID_Estacion,
                "nombre":    est.Nombre_Estacion or "",
                "ensambles": [],
            }

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble "
                "FROM Tbl_Ensambles WHERE ID_Estacion = ? ORDER BY Nombre_Ensamble",
                (est.ID_Estacion,)
            )
            ensambles = cursor.fetchall()   # completo → cursor libre

            for ens in ensambles:
                ens_dict = {
                    "id":     ens.ID_Ensamble,
                    "nombre": ens.Nombre_Ensamble or "",
                    "piezas": [],
                }

                cursor.execute(pieza_sql, (ens.ID_Ensamble,))
                piezas_rows = cursor.fetchall()   # completo → cursor libre

                for p in piezas_rows:
                    id_bom_val = int(p.ID_BOM) if p.ID_BOM is not None else None
                    ens_dict["piezas"].append({
                        "id":               id_bom_val,
                        "id_estructura":    id_bom_val,  # alias explícito para actualizar cantidades
                        "codigo":           str(p.Codigo_Pieza or ''),
                        "descripcion":      str(getattr(p, 'Descripcion',    None) or '') or 'N/A',
                        "cantidad":         float(p.Cantidad) if p.Cantidad is not None else 0.0,
                        "observaciones":    str(getattr(p, 'Observaciones_Proceso', None) or ''),
                        "simetria":         str(getattr(p, 'Simetria',         None) or ''),
                        "material":         str(getattr(p, 'Material',          None) or ''),
                        "medida":           str(getattr(p, 'Medida',            None) or ''),
                        "proceso_primario": str(getattr(p, 'Proceso_Primario',  None) or ''),
                        "proceso_1":        str(getattr(p, 'Proceso_1',         None) or ''),
                        "proceso_2":        str(getattr(p, 'Proceso_2',         None) or ''),
                        "proceso_3":        str(getattr(p, 'Proceso_3',         None) or ''),
                        "link_drive":       str(getattr(p, 'Link_Drive',        None) or ''),
                        "largo_cad":        str(getattr(p, 'Largo_CAD',         None) or ''),
                        "ancho_cad":        str(getattr(p, 'Ancho_CAD',         None) or ''),
                        "espesor_cad":      str(getattr(p, 'Espesor_CAD',       None) or ''),
                        "tiene_dxf":        str(getattr(p, 'Tiene_DXF', 'No') or 'No'),
                    })

                est_dict["ensambles"].append(ens_dict)

            arbol.append(est_dict)

        return arbol

    except pyodbc.Error as e:
        print(f"Error en arbol [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"SQL error en Árbol BOM [rev={id_revision}]: {str(e)}"
        )
    except Exception as e:
        print(f"Error en arbol [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"Error interno en Árbol BOM [rev={id_revision}]: {str(e)}"
        )
    finally:
        cursor.close()
        conn.close()



@app.get("/api/bom/plana/{id_revision}")
def get_bom_plana(id_revision: int):
    """
    Vista Plana HD: explosión jerárquica mediante CTE de 3 niveles.
    LEFT JOIN a Tbl_Maestro_Piezas con ISNULL para evitar nulos de BD.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        sql = """
            WITH Estaciones AS (
                SELECT ID_Estacion, Nombre_Estacion, Orden
                FROM   Tbl_Estaciones
                WHERE  ID_Revision = ?
            ),
            Explosion AS (
                -- Nivel 1: Estaciones (agrupador)
                SELECT
                    1                                         AS Nivel,
                    CAST(NULL AS NVARCHAR(200))               AS Codigo_Padre,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)) AS Codigo_Pieza,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(500)) AS Descripcion,
                    CAST(NULL AS FLOAT)                       AS Cantidad,
                    ''  AS Material,    ''  AS Medida,
                    ''  AS Proceso_Primario,
                    ''  AS Proceso_1,   ''  AS Proceso_2,   ''  AS Proceso_3,
                    ''  AS Largo_CAD,   ''  AS Ancho_CAD,   ''  AS Espesor_CAD,
                    'No' AS Tiene_DXF,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)) AS Nombre_Estacion,
                    CAST(NULL AS NVARCHAR(200))               AS Nombre_Ensamble,
                    CAST(NULL AS INT)                         AS ID_BOM,
                    ES.Orden AS Sort1, 0 AS Sort2, 0 AS Sort3
                FROM Estaciones ES

                UNION ALL

                -- Nivel 2: Ensambles (sub-agrupador)
                SELECT
                    2,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(500)),
                    CAST(NULL AS FLOAT),
                    '', '', '', '', '', '',
                    '', '', '', 'No',
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(NULL AS INT),
                    ES.Orden, EN.ID_Ensamble, 0
                FROM Tbl_Ensambles EN
                JOIN Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion

                UNION ALL

                -- Nivel 3: Piezas. LEFT JOIN + ISNULL (sincronizado con esquema Pydantic)
                SELECT
                    3,
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(E.Codigo_Pieza     AS NVARCHAR(200)),
                    ISNULL(CAST(M.Descripcion AS NVARCHAR(500)), ''),
                    CAST(E.Cantidad AS FLOAT),
                    ISNULL(M.Material, ''),
                    ISNULL(M.Medida, ''),
                    ISNULL(M.Proceso_Primario, ''),
                    ISNULL(M.Proceso_1, ''),
                    ISNULL(M.Proceso_2, ''),
                    ISNULL(M.Proceso_3, ''),
                    ISNULL(TRY_CAST(M.Largo_CAD AS NVARCHAR(50)), ''),
                    ISNULL(TRY_CAST(M.Ancho_CAD AS NVARCHAR(50)), ''),
                    ISNULL(TRY_CAST(M.Espesor_Perfil_CAD AS NVARCHAR(50)), ''),
                    ISNULL(M.Tiene_DXF, 'No'),
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    E.ID_BOM,
                    ES.Orden, EN.ID_Ensamble, E.ID_BOM
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles           EN ON E.ID_Ensamble  = EN.ID_Ensamble
                JOIN Estaciones              ES ON EN.ID_Estacion = ES.ID_Estacion
                LEFT JOIN Tbl_Maestro_Piezas M  ON E.Codigo_Pieza = M.Codigo_Pieza
            )
            SELECT Nivel, Codigo_Padre, Codigo_Pieza, Descripcion, Cantidad,
                   Material, Medida, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3,
                   Largo_CAD, Ancho_CAD, Espesor_CAD, Tiene_DXF,
                   Nombre_Estacion, Nombre_Ensamble, ID_BOM
            FROM   Explosion
            ORDER BY Sort1, Sort2, Nivel, Sort3
        """
        cursor.execute(sql, (id_revision,))
        rows = cursor.fetchall()

        def _gs(r, col: str, default: str = "") -> str:
            return str(getattr(r, col, default) or default)

        return [
            {
                "nivel":            int(getattr(r, 'Nivel', 0)),
                "codigo_padre":     _gs(r, 'Codigo_Padre'),
                "codigo_pieza":     _gs(r, 'Codigo_Pieza'),
                "descripcion":      _gs(r, 'Descripcion'),
                "cantidad":         (float(r.Cantidad) if r.Cantidad is not None else None),
                "material":         _gs(r, 'Material'),
                "medida":           _gs(r, 'Medida'),
                "proceso_primario": _gs(r, 'Proceso_Primario'),
                "proceso_1":        _gs(r, 'Proceso_1'),
                "proceso_2":        _gs(r, 'Proceso_2'),
                "proceso_3":        _gs(r, 'Proceso_3'),
                "largo_cad":        _gs(r, 'Largo_CAD'),
                "ancho_cad":        _gs(r, 'Ancho_CAD'),
                "espesor_cad":      _gs(r, 'Espesor_CAD'),
                "tiene_dxf":        str(getattr(r, 'Tiene_DXF', 'No') or 'No'),
                "nombre_estacion":  _gs(r, 'Nombre_Estacion'),
                "nombre_ensamble":  _gs(r, 'Nombre_Ensamble'),
                "id_bom":           (int(r.ID_BOM) if r.ID_BOM is not None else None),
                "id_estructura":    (int(r.ID_BOM) if r.ID_BOM is not None else None),  # alias explícito
            }
            for r in rows
        ]
    except pyodbc.Error as e:
        print(f"Error en plana [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"SQL error en Vista Plana [rev={id_revision}]: {str(e)}"
        )
    except Exception as e:
        print(f"Error en plana [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"Error interno en Vista Plana [rev={id_revision}]: {str(e)}"
        )
    finally:
        cursor.close()
        conn.close()


@app.get("/api/bom/delta/{id_revision}")
def get_bom_delta(id_revision: int):
    """
    Modo Delta: compara la revisión actual con la inmediatamente anterior
    en la misma versión de ingeniería.
    Devuelve conjuntos de piezas nuevas, eliminadas y con cantidad modificada.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Buscar la revisión anterior en la misma versión
        cursor.execute("""
            SELECT TOP 1 R2.ID_Revision
            FROM Tbl_BOM_Revisiones R1
            JOIN Tbl_BOM_Revisiones R2 ON R1.ID_Version = R2.ID_Version
            WHERE R1.ID_Revision = ?
              AND R2.Numero_Revision < R1.Numero_Revision
            ORDER BY R2.Numero_Revision DESC
        """, (id_revision,))
        row = cursor.fetchone()
        if not row:
            return {
                "tiene_anterior":     False,
                "id_rev_anterior":    None,
                "codigos_nuevos":     [],
                "codigos_eliminados": [],
                "modificados":        {},
            }
        id_rev_anterior = int(row[0])

        # Helper: sumar cantidades por código en una revisión
        def piezas_por_codigo(rev_id: int) -> dict:
            cursor.execute("""
                SELECT E.Codigo_Pieza, SUM(E.Cantidad)
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles  EN ON E.ID_Ensamble  = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                WHERE ES.ID_Revision = ?
                GROUP BY E.Codigo_Pieza
            """, (rev_id,))
            return {str(r[0]): float(r[1] or 0) for r in cursor.fetchall()}

        curr = piezas_por_codigo(id_revision)
        prev = piezas_por_codigo(id_rev_anterior)

        codigos_nuevos     = [c for c in curr if c not in prev]
        codigos_eliminados = [c for c in prev if c not in curr]
        modificados        = {
            c: {"prev_qty": prev[c], "curr_qty": curr[c]}
            for c in curr
            if c in prev and curr[c] != prev[c]
        }

        return {
            "tiene_anterior":     True,
            "id_rev_anterior":    id_rev_anterior,
            "codigos_nuevos":     codigos_nuevos,
            "codigos_eliminados": codigos_eliminados,
            "modificados":        modificados,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error en Delta BOM: {str(e)}")
    finally:
        conn.close()


@app.post("/api/bom/importar/{id_revision}")
async def importar_bom(id_revision: int, file: UploadFile = File(...)):
    if not file.filename.endswith(('.xls', '.xlsx')):
        raise HTTPException(status_code=400, detail="El archivo debe ser un Excel (.xlsx, .xls)")

    try:
        content = await file.read()
        df = pd.read_excel(io.BytesIO(content), header=None)
    except Exception as e:
        if isinstance(e, HTTPException): raise e
        raise HTTPException(status_code=400, detail=f"Error al analizar el Excel: {str(e)}")

    # ── Motor dinámico de cabeceras ───────────────────────────────────────────
    # Glosario de sinónimos por campo (normalizado a mayúsculas).
    _COL_MAP = {
        'estacion':  {'ESTACION', 'ESTACIÓN', 'UBICACION', 'UBICACIÓN', 'STATION'},
        'ensamble':  {'ENSAMBLE', 'GRUPO', 'SUBENSAMBLE', 'SUBGRUPO', 'ASSEMBLY'},
        'codigo':    {'CODIGO', 'CÓDIGO', 'PARTE', 'NO. PARTE', 'NO.PARTE',
                      'CODIGO PIEZA', 'CÓDIGO PIEZA', 'PART NO', 'PART NUMBER'},
        'cantidad':  {'CANTIDAD', 'CANT', 'CANT.', 'QTY', 'QUANTITY'},
    }
    # Índices por defecto (compatibilidad con plantillas sin fila de cabecera)
    idx = {'estacion': 1, 'ensamble': 2, 'codigo': 3, 'cantidad': 6}

    header_row_found = None
    for r_idx, row_scan in df.iterrows():
        if r_idx >= 10:            # sólo escanear las primeras 10 filas
            break
        row_vals = [str(v).strip().upper() if not pd.isna(v) else '' for v in row_scan]
        matched = 0
        tmp = {}
        for campo, sinonimos in _COL_MAP.items():
            for c_idx, val in enumerate(row_vals):
                if val in sinonimos:
                    tmp[campo] = c_idx
                    matched += 1
                    break
        # Si se detectaron al menos 3 campos → fila de cabecera válida
        if matched >= 3:
            idx.update(tmp)
            header_row_found = r_idx
            break

    # Si se encontró cabecera, ignorar esa fila y las anteriores en la iteración
    data_start = (header_row_found + 1) if header_row_found is not None else 0

    conn = get_db_connection()
    cursor = conn.cursor()

    total_leidos = 0
    insertados = 0
    errores_mapeo = []

    try:
        # Pre-cargar catálogo maestro para validación rápida
        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas")
        codigos_buscar = {str(row[0]).strip().upper() for row in cursor.fetchall() if row[0]}

        acumulados = {}

        # Lógica de Secuencia Inicial (Ensambles)
        cursor.execute(
            "SELECT MAX(Codigo_Ensamble) FROM Tbl_Ensambles "
            "WHERE Codigo_Ensamble LIKE 'E-%'"
        )
        max_code_row = cursor.fetchone()
        secuencia_ensamble = 0
        if max_code_row and max_code_row[0]:
            try:
                secuencia_ensamble = int(max_code_row[0].split('-')[1])
            except (ValueError, IndexError):
                pass

        # Forward-fill para Estacion y Ensamble (celdas combinadas en Excel)
        last_estacion = None
        last_ensamble = None

        for index, row in df.iterrows():
            if index < data_start:
                continue

            def _safe(col_idx):
                try:
                    v = row[col_idx]
                    return None if pd.isna(v) else str(v).strip()
                except (KeyError, IndexError):
                    return None

            estacion_raw = _safe(idx['estacion'])
            ensamble_raw = _safe(idx['ensamble'])
            codigo_raw   = _safe(idx['codigo'])
            cantidad_raw = _safe(idx['cantidad'])

            # Forward-fill
            if estacion_raw: last_estacion = estacion_raw
            if ensamble_raw: last_ensamble = ensamble_raw
            estacion_val = last_estacion
            ensamble_val = last_ensamble

            # Validar que hay código de pieza
            if not codigo_raw:
                continue
            skip_values = {'codigo', 'código', 'codigo pieza', 'código pieza',
                           'codigo_pieza', 'no. parte', 'part no', 'none', ''}
            if codigo_raw.lower() in skip_values:
                continue
            if not estacion_val or not ensamble_val:
                continue

            total_leidos += 1
            codigo = codigo_raw.upper()

            # Validación de existencia en catálogo maestro
            if codigo not in codigos_buscar:
                if codigo not in errores_mapeo:
                    errores_mapeo.append(codigo)
                continue

            try:
                cantidad = 1 if not cantidad_raw else int(float(cantidad_raw))
            except (ValueError, TypeError):
                cantidad = 1

            # Acumulación (une duplicados de la misma clave en el mismo archivo)
            llave = (estacion_val, ensamble_val, codigo)
            acumulados[llave] = acumulados.get(llave, 0) + cantidad
            
        # Inserción final con Caché para velocidad
        cache_estaciones = {}
        cache_ensambles = {}
        
        for (estacion_nombre, ensamble_nombre, codigo), cantidad in acumulados.items():
            # 1. Buscar o Crear ESTACION
            if estacion_nombre not in cache_estaciones:
                cursor.execute("SELECT ID_Estacion FROM Tbl_Estaciones WHERE ID_Revision = ? AND Nombre_Estacion = ?", (id_revision, estacion_nombre))
                est_row = cursor.fetchone()
                if est_row:
                    id_estacion = est_row[0]
                else:
                    cursor.execute("SELECT ISNULL(MAX(Orden), 0) + 1 FROM Tbl_Estaciones WHERE ID_Revision = ?", (id_revision,))
                    nuevo_orden = cursor.fetchone()[0]
                    cursor.execute(
                        "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)", 
                        (id_revision, estacion_nombre, nuevo_orden)
                    )
                    id_estacion = int(cursor.fetchone()[0])
                cache_estaciones[estacion_nombre] = id_estacion
            else:
                id_estacion = cache_estaciones[estacion_nombre]
                
            # 2. Buscar o Crear ENSAMBLE
            ensamble_key = (id_estacion, ensamble_nombre)
            if ensamble_key not in cache_ensambles:
                cursor.execute("SELECT ID_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ? AND Nombre_Ensamble = ?", (id_estacion, ensamble_nombre))
                ens_row = cursor.fetchone()
                if ens_row:
                    id_ensamble = ens_row[0]
                else:
                    secuencia_ensamble += 1
                    codigo_ensamble_generado = f"E-{secuencia_ensamble:04d}"
                    cursor.execute(
                        "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)", 
                        (id_estacion, codigo_ensamble_generado, ensamble_nombre)
                    )
                    id_ensamble = int(cursor.fetchone()[0])
                cache_ensambles[ensamble_key] = id_ensamble
            else:
                id_ensamble = cache_ensambles[ensamble_key]
                
            # 3. Insertar PIEZA (BOM)
            cursor.execute("INSERT INTO Tbl_BOM_Estructura (ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) VALUES (?, ?, ?, ?)", (id_ensamble, codigo, cantidad, ""))
            insertados += 1
            
        conn.commit()
        return {"status": "success", "total_leidos": total_leidos, "insertados": insertados, "errores": errores_mapeo}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL durante importación, transacción revertida: {str(e)}")
    finally:
        conn.close()

# === FIN BOM ===

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

import hashlib

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()

def init_auth_db():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Recrear tabla para ajustar nombres de columnas según fase 3
        cursor.execute("""
            IF OBJECT_ID('Tbl_Usuarios', 'U') IS NOT NULL DROP TABLE Tbl_Usuarios;
            CREATE TABLE Tbl_Usuarios (
                id INT PRIMARY KEY IDENTITY(1,1),
                username NVARCHAR(50) UNIQUE NOT NULL,
                password_hash NVARCHAR(255) NOT NULL,
                rol NVARCHAR(20) DEFAULT 'USER'
            )
        """)
        conn.commit()
        
        users_to_seed = [
            ("jaes_admin", "Industrial.2026", "ADMIN"),
            ("ing_01", "Ing.2026", "USER"),
            ("ing_02", "Ing.2026", "USER"),
        ]
        
        for user, password, role in users_to_seed:
            hashed = hash_password(password)
            cursor.execute("INSERT INTO Tbl_Usuarios (username, password_hash, rol) VALUES (?, ?, ?)", (user, hashed, role))
        
        conn.commit()
    finally:
        conn.close()

@app.post("/api/login")
def login(request: LoginRequest):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        hashed_password = hash_password(request.password)
        cursor.execute("SELECT rol FROM Tbl_Usuarios WHERE username = ? AND password_hash = ?", (request.username, hashed_password))
        user = cursor.fetchone()
        
        conn.close()
        
        if user:
            return {"success": True, "rol": user[0]}
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

        # --- TABLAS DE JERARQUÍA DE PROYECTOS ---
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Proyectos_Tracto')
            BEGIN
                CREATE TABLE Tbl_Proyectos_Tracto (
                    ID_Tracto INT IDENTITY(1,1) PRIMARY KEY,
                    Nombre_Tracto VARCHAR(200) UNIQUE NOT NULL
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Tipos_Proyecto')
            BEGIN
                CREATE TABLE Tbl_Tipos_Proyecto (
                    ID_Tipo INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Tracto INT NOT NULL,
                    Nombre_Tipo VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Tipo_Tracto FOREIGN KEY (ID_Tracto) REFERENCES Tbl_Proyectos_Tracto(ID_Tracto) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Versiones_Ingenieria')
            BEGIN
                CREATE TABLE Tbl_Versiones_Ingenieria (
                    ID_Version INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Tipo INT NOT NULL,
                    Nombre_Version VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Version_Tipo FOREIGN KEY (ID_Tipo) REFERENCES Tbl_Tipos_Proyecto(ID_Tipo) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Clientes_Configuracion')
            BEGIN
                CREATE TABLE Tbl_Clientes_Configuracion (
                    ID_Config_Cliente INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Version INT NOT NULL,
                    Nombre_Cliente VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Cliente_Version FOREIGN KEY (ID_Version) REFERENCES Tbl_Versiones_Ingenieria(ID_Version) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_BOM_Revisiones')
            BEGIN
                CREATE TABLE Tbl_BOM_Revisiones (
                    ID_Revision INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Version INT NOT NULL,
                    Numero_Revision INT NOT NULL,
                    Estado VARCHAR(200) NOT NULL,
                    Fecha_Creacion DATETIME DEFAULT GETDATE(),
                    CONSTRAINT FK_Revision_Version2 FOREIGN KEY (ID_Version) REFERENCES Tbl_Versiones_Ingenieria(ID_Version) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Estaciones')
            BEGIN
                CREATE TABLE Tbl_Estaciones (
                    ID_Estacion INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Revision INT NOT NULL,
                    Nombre_Estacion VARCHAR(200) NOT NULL,
                    Orden INT NOT NULL DEFAULT 0,
                    CONSTRAINT FK_Estacion_Revision FOREIGN KEY (ID_Revision) REFERENCES Tbl_BOM_Revisiones(ID_Revision) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Ensambles')
            BEGIN
                CREATE TABLE Tbl_Ensambles (
                    ID_Ensamble INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Estacion INT NOT NULL,
                    Nombre_Ensamble VARCHAR(200) NOT NULL,
                    CONSTRAINT FK_Ensamble_Estacion FOREIGN KEY (ID_Estacion) REFERENCES Tbl_Estaciones(ID_Estacion) ON DELETE CASCADE
                );
            END
        """)
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_BOM_Estructura')
            BEGIN
                CREATE TABLE Tbl_BOM_Estructura (
                    ID_BOM INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Ensamble INT NOT NULL,
                    Codigo_Pieza VARCHAR(50) NOT NULL,
                    Cantidad FLOAT NOT NULL,
                    Observaciones VARCHAR(500),
                    CONSTRAINT FK_BOM_Ensamble FOREIGN KEY (ID_Ensamble) REFERENCES Tbl_Ensambles(ID_Ensamble) ON DELETE CASCADE
                );
            END
        """)
        
        cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Unidades_Fisicas')
            BEGIN
                CREATE TABLE Tbl_Unidades_Fisicas (
                    ID_Unidad INT IDENTITY(1,1) PRIMARY KEY,
                    ID_Revision INT NOT NULL,
                    Serie VARCHAR(50) NOT NULL,
                    Observaciones VARCHAR(MAX),
                    ID_VIN_Asociado INT NULL,
                    CONSTRAINT FK_Unidad_Revision FOREIGN KEY (ID_Revision) REFERENCES Tbl_BOM_Revisiones(ID_Revision) ON DELETE CASCADE
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

@app.delete("/api/catalog/{codigo}")
async def delete_material_catalog(codigo: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Check existence first
        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="Pieza no encontrada en el catálogo")
            
        cursor.execute("DELETE FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
        conn.commit()
        return {"status": "success", "message": f"Pieza {codigo} eliminada correctamente"}
    except HTTPException as he:
        conn.rollback()
        raise he
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

DIRECTORIO_MAESTRO_DXF = os.environ.get("DIRECTORIO_MAESTRO_DXF", r"Y:\2026")

@app.get("/api/dxf/search/{codigo}")
async def search_dxf_catalog(codigo: str, base_path: str):
    try:
        clean_base_path = base_path.strip('"').strip("'")
        target_dir = Path(clean_base_path)
        if not target_dir.exists() or not target_dir.is_dir():
             raise HTTPException(status_code=500, detail=f"Ruta maestra no encontrada o no es un directorio: {clean_base_path}")
             
        # Búsqueda global con comodines
        archivos_encontrados = list(target_dir.rglob(f"*{codigo}*.*"))
        
        # Filtrar solo archivos con extensiones dxf o dwg
        valid_files = [
            p for p in archivos_encontrados
            if p.is_file() and p.suffix.lower() in ['.dxf', '.dwg']
        ]
        
        if not valid_files:
             raise HTTPException(status_code=404, detail=f"No se encontraron archivos .dxf o .dwg válidos para '{codigo}' dentro de {clean_base_path}")

        # Manejo de Duplicados/Revisiones: Obtener el archivo más reciente (última modificación)
        newest_file = max(valid_files, key=lambda f: os.path.getmtime(f))

        return {"status": "success", "codigo": codigo, "dxf_path": str(newest_file.resolve())}
    except HTTPException as he:
        raise he
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

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
    
    # REGLA ESPEJO ELIMINADA: Descripcion y Material son campos independientes.
    # Cada campo recibe sólo su propio valor del frontend.

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
        
        # ── 2. Detección dinámica de columnas desde cabeceras (filas 1-5) ─────
        # Soporta múltiples sinónimos para mayor compatibilidad con plantillas
        # antiguas y de terceros. Material siempre se trata de forma independiente;
        # si no se encuentra su columna, se guarda vacío (sin copiar Descripcion).
        SINONIMOS_DESC = {
            'DESCRIPCION', 'DESCRIPCIÓN', 'DESC', 'DETALLE', 'NOMBRE',
            'DESCRIPTION', 'NOMBRE PIEZA', 'NOMBRE_PIEZA',
        }
        SINONIMOS_MAT = {
            'MATERIAL', 'MAT', 'MATERIA', 'COMPOSICION', 'COMPOSICIÓN',
            'TIPO MATERIAL', 'TIPO_MATERIAL', 'MATERIAL BASE',
        }

        idx_descripcion = 4        # fallback seguro: Col E
        idx_material    = None     # None = columna no encontrada → campo vacío

        for r_idx in range(1, 6):
            if r_idx > ws.max_row:
                break
            for c_idx, cell in enumerate(ws[r_idx]):
                val = str(cell.value or '').strip().upper()
                if val in SINONIMOS_DESC:
                    idx_descripcion = c_idx
                elif val in SINONIMOS_MAT:
                    idx_material = c_idx

        # Mapeo de columnas (0-based) — valores de fallback para plantillas sin cabecera:
        # D (3): CODIGO_PIEZA
        # E (4): DESCRIPCION
        # F (5): MEDIDA
        # G (6): MATERIAL (si no se detecta cabecera, queda None → vacío)
        # H (7): SIMETRIA  |  I (8): PROCESO PRIMARIO  |  J-L (9-11): PROCESO 1-3
        start_row = 6
        for row in ws.iter_rows(min_row=start_row, values_only=True):
            
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

            # Material: sólo leer si se detectó su columna; de lo contrario vacío.
            # Nunca copiar Descripcion → Material (regla espejo eliminada).
            material_excel = get_val(idx_material) if idx_material is not None else ""

            scan_data.append({
                'Estacion':          last_estacion,
                'Ensamble':          last_ensamble,
                'Codigo_Pieza':      codigo_pieza,
                'Cantidad':          0,
                'Descripcion_Excel': get_val(idx_descripcion),
                'Medida_Excel':      get_val(5),
                'Material_Excel':    material_excel,
                'Simetria':          get_val(7),
                'Proceso_Primario':  get_val(8),
                'Proceso_1':         get_val(9),
                'Proceso_2':         get_val(10),
                'Proceso_3':         get_val(11),
                'Link_Drive':        "",
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
async def sincronizar_excel(items: List[SincronizacionItem], x_usuario: Optional[str] = Header(None)):
    # === TAREA 1: Escudo de Sincronización - Validación de seguridad ===
    conflictos_sin_resolver = [item for item in items if item.Estado == 'CONFLICTO']
    if conflictos_sin_resolver:
        raise HTTPException(
            status_code=400,
            detail=f"Hay {len(conflictos_sin_resolver)} conflicto(s) sin resolver. Resuélvelos antes de sincronizar."
        )
    # === FIN Escudo ===

    conn = get_db_connection()
    cursor = conn.cursor()
    
    procesados = 0
    errores = 0
    
    try:
        for item in items:
            # REGLA ESPEJO ELIMINADA: Material y Descripcion son independientes.
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
            usuario = item.Modificado_Por if item.Modificado_Por else (x_usuario if x_usuario else "Importador Excel")

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
        header_fill = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid") # Azul Industrial
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
            adjusted_width = (max_length + 2) * 1.1
            ws.column_dimensions[column].width = min(adjusted_width, 60)

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
            # Busca en código, usuario Y acción para que eventos VIN aparezcan
            query += " WHERE Codigo_Pieza LIKE ? OR Usuario LIKE ? OR Accion LIKE ? "
            search_term = f"%{busqueda}%"
            params.extend([search_term, search_term, search_term])

        query += " ORDER BY Fecha_Hora DESC"
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        
        historial = []
        for row in rows:
            val_ant = row[3]
            val_nue = row[4]
            
            # Intentar parsear Valor_Anterior
            if val_ant and isinstance(val_ant, str):
                val_ant_s = val_ant.strip()
                try:
                    if val_ant_s.startswith('{') or val_ant_s.startswith('['):
                         val_ant = json.loads(val_ant.replace("'", '"')) # Attempt JSON fix or standard load
                    elif val_ant_s.startswith('('):
                         val_ant = ast.literal_eval(val_ant)
                    # NOTA: evitamos evaluar incondicionalmente con ast.literal_eval
                    # porque si val_ant es un string numérico con ceros a la izq ("002")
                    # Python lanza SyntaxWarning: invalid decimal literal
                except:
                    pass # Keep as string if fail

            # Intentar parsear Valor_Nuevo
            if val_nue and isinstance(val_nue, str):
                val_nue_s = val_nue.strip()
                try:
                    if val_nue_s.startswith('{') or val_nue_s.startswith('['):
                         val_nue = json.loads(val_nue.replace("'", '"'))
                    elif val_nue_s.startswith('('):
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
            
            # REGLA ESPEJO ELIMINADA: el renombre masivo sólo toca Descripcion.
            # Material se mantiene intacto.
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

# === BUG TRACKER ===
@app.post("/api/reportes/nuevo")
def nuevo_reporte(payload: BugReportPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            INSERT INTO Tbl_Reportes_Beta (Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado, Captura_Base64)
            VALUES (?, GETDATE(), ?, ?, ?, 'Abierto', ?)
        """, (payload.usuario, payload.modulo, payload.descripcion, payload.gravedad, payload.captura))
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.get("/api/reportes/exportar_gemini")
def exportar_reportes():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Modulo, Descripcion, Gravedad, Captura_Base64 FROM Tbl_Reportes_Beta WHERE Estado = 'Abierto'")
        rows = cursor.fetchall()
        reportes = []
        for r in rows:
            reportes.append({
                "id": r.ID_Reporte,
                "modulo": r.Modulo,
                "error": r.Descripcion,
                "severidad": r.Gravedad,
                "captura_base64": r.Captura_Base64
            })
        return reportes
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.get("/api/reportes")
def listar_reportes():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado, Captura_Base64 FROM Tbl_Reportes_Beta WHERE Estado = 'Abierto' ORDER BY Fecha_Hora DESC")
        rows = cursor.fetchall()
        reportes = []
        for r in rows:
            reportes.append({
                "id": r.ID_Reporte,
                "usuario": r.Usuario,
                "fecha": r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else None,
                "modulo": r.Modulo,
                "descripcion": r.Descripcion,
                "gravedad": r.Gravedad,
                "estado": r.Estado,
                "captura_base64": r.Captura_Base64
            })
        return reportes
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.get("/api/reportes/exportar")
def exportar_reportes_excel():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado FROM Tbl_Reportes_Beta ORDER BY Fecha_Hora DESC")
        rows = cursor.fetchall()
        
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "Reportes Beta"
        
        headers = ["ID", "Usuario", "Fecha", "Módulo", "Gravedad", "Estado", "Descripción"]
        for col_idx, text in enumerate(headers, 1):
            cell = ws.cell(row=1, column=col_idx, value=text)
            cell.font = Font(bold=True, color="FFFFFF")
            cell.fill = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid")
            cell.alignment = Alignment(horizontal="center")
            
        for row_idx, r in enumerate(rows, 2):
            fecha_str = r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else "Sin fecha"
            ws.cell(row=row_idx, column=1, value=int(r.ID_Reporte))
            ws.cell(row=row_idx, column=2, value=str(r.Usuario))
            ws.cell(row=row_idx, column=3, value=fecha_str)
            ws.cell(row=row_idx, column=4, value=str(r.Modulo))
            ws.cell(row=row_idx, column=5, value=str(r.Gravedad))
            ws.cell(row=row_idx, column=6, value=str(r.Estado))
            ws.cell(row=row_idx, column=7, value=str(r.Descripcion))

        # Auto-fit columns
        for col in ws.columns:
            max_length = 0
            column = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except: pass
            ws.column_dimensions[column].width = min((max_length + 2) * 1.1, 60)
            
        stream = io.BytesIO()
        wb.save(stream)
        stream.seek(0)
        
        return StreamingResponse(
            stream,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": "attachment; filename=Reportes_Beta.xlsx"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@app.put("/api/reportes/{id_reporte}/resolver")
def resolver_reporte(id_reporte: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("UPDATE Tbl_Reportes_Beta SET Estado = 'Cerrado' WHERE ID_Reporte = ?", (id_reporte,))
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === MÓDULO: ESCÁNER CAD (Fase 1) ===

try:
    import ezdxf
    import win32com.client
    import pythoncom
    print("Módulos CAD asíncronos (ezdxf, win32com, pythoncom) importados exitosamente.")
except ImportError as e:
    raise RuntimeError(f"LIBRERÍA FALTANTE: Asegúrate de correr 'pip install ezdxf pywin32'. Error: {e}")


class ScanCADPayload(BaseModel):
    root_path: str

scan_status = {
    "progress": 0,
    "total": 0,
    "status": "idle",
    "excel_path": "",
    "error": ""
}
abortar_escaneo_cad = False

@app.post("/api/cad/abort")
def abort_cad():
    global abortar_escaneo_cad, scan_status
    abortar_escaneo_cad = True
    scan_status["status"] = "cancelled"
    flag_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "abortar_cad.flag")
    with open(flag_path, "w") as f:
        f.write("abort")
    return {"status": "aborting"}

def bg_scan_cad_task(root_path: str):
    global scan_status, abortar_escaneo_cad
    import datetime
    try:
        import pythoncom
        import logging
        pythoncom.CoInitialize()
    except Exception:
        pass
    
    scan_status["status"] = "scanning"
    scan_status["progress"] = 0
    scan_status["total"] = 0
    scan_status["excel_path"] = ""
    scan_status["error"] = ""
    
    # Búsqueda de archivos
    cad_files = {} # Key: filename without extension, Value: dict of details
    
    extensions_to_look = {".sldprt"}
    
    try:
        processed_count = 0
        for dirpath, _, filenames in os.walk(root_path):
            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                break
            
            for f in filenames:
                if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                    break
                    
                if f.startswith("~$"):
                    continue
                    
                ext = os.path.splitext(f)[1].lower()
                if ext in extensions_to_look:
                    codigo_pieza = os.path.splitext(f)[0]
                    abspath = os.path.join(dirpath, f)
                    
                    try:
                        mtime = os.path.getmtime(abspath)
                        if codigo_pieza in cad_files:
                            if mtime > cad_files[codigo_pieza]["mtime"]:
                                cad_files[codigo_pieza] = {
                                    "mtime": mtime,
                                    "abspath": abspath,
                                    "ext": ext,
                                    "codigo": codigo_pieza
                                }
                        else:
                            cad_files[codigo_pieza] = {
                                "mtime": mtime,
                                "abspath": abspath,
                                "ext": ext,
                                "codigo": codigo_pieza
                            }
                    except OSError:
                        pass # Ignore restricted or missing files
                
                processed_count += 1
                if processed_count % 50 == 0: # Update progress every 50 files
                    scan_status["progress"] = processed_count
                    
        scan_status["progress"] = processed_count
        
        if scan_status["status"] == "cancelled":
            scan_status["status"] = "idle"
            return
            
        scan_status["status"] = "generating_excel"
        
        # Generar Excel y extraer metadata CAD
        data = []
        try:
            import ezdxf
            from ezdxf import bbox
        except ImportError:
            pass
            
        try:
            import win32com.client
            import pythoncom
        except ImportError:
            pass
            
        def _apply_silent_mode(app):
            """Fuerza el modo silencioso completo en la instancia SW para evitar
            que el proceso intente renderizar diálogos UI en segundo plano."""
            try:
                app.Visible = False
            except Exception:
                pass
            try:
                # Desconecta la instancia del control de usuario (evita diálogos interactivos)
                app.UserControl = False
            except Exception:
                pass
            try:
                # swUserPreferenceToggle_e.swSuppressDialogs = 11
                # Suprime todos los mensajes emergentes y confirmaciones
                app.SetUserPreferenceToggle(11, True)
            except Exception:
                pass
            try:
                # swUserPreferenceToggle_e.swSuppressWarnings = 262
                # Suprime advertencias de reconstrucción y referencias rotas
                app.SetUserPreferenceToggle(262, True)
            except Exception:
                pass

        def get_sw_app():
            try:
                app = win32com.client.Dispatch("SldWorks.Application")
                _apply_silent_mode(app)
                print("[SW] Instancia COM inicializada en modo silencioso.")
                return app
            except Exception as e:
                print(f"ADVERTENCIA: Motor SolidWorks inaccesible: {e}")
                return None
                
        def get_acad_app():
            try:
                app = win32com.client.Dispatch("AutoCAD.Application")
                # app.Visible = False # AutoCAD usually resists being hidden natively sometimes, but we can try if needed
                return app
            except Exception as e:
                print(f"ADVERTENCIA: Motor AutoCAD inaccesible: {e}")
                return None

        has_sldprt = any(info["ext"] == ".sldprt" for info in cad_files.values())
        sw_app = get_sw_app() if has_sldprt else None
        
        has_dwg = any(info["ext"] == ".dwg" for info in cad_files.values())
        acad_app = get_acad_app() if has_dwg else None
                
        total_a_extraer = len(cad_files)
        extraidos = 0
        scan_status["total"] = total_a_extraer
        
        print(f"=== INICIANDO EXTRACCIÓN CAD ({total_a_extraer} archivos únicos) ===")

        for info in cad_files.values():
            if abortar_escaneo_cad or scan_status["status"] == "cancelled":
                import logging
                logging.info("Escaneo abortado por el usuario.")
                if sw_app: 
                    try: sw_app.ExitApp()
                    except: pass
                if acad_app:
                    try: acad_app.Quit()
                    except: pass
                scan_status["status"] = "cancelled"
                break

            dt = datetime.datetime.fromtimestamp(info["mtime"]).strftime("%Y-%m-%d %H:%M:%S")
            ext = info["ext"]
            abspath = info["abspath"]
            codigo = info["codigo"]
            
            # FIX: Inicializar TODAS las variables antes del try para evitar UnboundLocalError
            largo_cad = 0.0
            ancho_cad = 0.0
            espesor_cad = 0.0
            observacion = ""
            tiene_dxf = "No"
            largo_dxf = ""
            ancho_dxf = ""
            
            try:
                if ext == ".dxf":
                    doc = ezdxf.readfile(abspath)
                    msp = doc.modelspace()
                    extents = bbox.extents(msp)
                    if extents.has_data:
                        dx = extents.extmax.x - extents.extmin.x
                        dy = extents.extmax.y - extents.extmin.y
                        largo_cad = max(dx, dy)
                        ancho_cad = min(dx, dy)
                        observacion = "OK"
                        
                elif ext == ".dwg" and acad_app:
                    try:
                        doc = acad_app.Documents.Open(abspath, True) # True for ReadOnly
                        extmin = doc.GetVariable("EXTMIN")
                        extmax = doc.GetVariable("EXTMAX")
                        
                        dx = abs(extmax[0] - extmin[0])
                        dy = abs(extmax[1] - extmin[1])
                        
                        largo_cad = max(dx, dy)
                        ancho_cad = min(dx, dy)
                        observacion = "OK (AutoCAD EXTENTS)"
                    except Exception as acad_err:
                        print(f"Error procesando {codigo} con AutoCAD: {acad_err}")
                        observacion = "No extraído (Error AutoCAD COM)"
                    finally:
                        try:
                            doc.Close(False)
                        except: pass
                        
                elif ext == ".dwg" and not acad_app:
                    observacion = "Requiere AutoCAD Instalado"
                    print(f"⚠️ DWG omitido: Sin conexión a AutoCAD COM -> {abspath}")

                elif ext == ".sldprt" and sw_app:
                    # FIX: Inicializar flags COM fuera de ramas para evitar NameError
                    _rpc_crash = False
                    swModel = None
                    # FIX: Filtro estricto — solo procesar archivos .SLDPRT reales
                    ruta_abs = os.path.abspath(abspath)
                    if not ruta_abs.upper().endswith(".SLDPRT"):
                        observacion = "Omitido (no es .SLDPRT)"
                        print(f"[SW] Omitido por filtro: {ruta_abs}")
                    else:
                        # ---- Apertura Silenciosa y Segura con OpenDoc6 ----
                        # Flags de la API de SolidWorks:
                        #   swDocPART               = 1  (tipo de documento: Part)
                        #   swOpenDocOptions_Silent  = 1  (sin diálogos)
                        #   swOpenDocOptions_ReadOnly= 2  (solo lectura)
                        #   silentMode = 1 | 2 = 3
                        swDocPART = 1
                        swSilentReadOnly = 1 | 2

                        # FIX TYPE MISMATCH: Usar VARIANTs tipados (VT_BYREF|VT_I4)
                        # para evitar com_error(-2147352571, 'Los tipos no coinciden').
                        # pywin32 requiere que los parámetros ByRef sean Variant explícitos.
                        arg_errors   = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)
                        arg_warnings = win32com.client.VARIANT(pythoncom.VT_BYREF | pythoncom.VT_I4, 0)

                        _rpc_crash = False
                        swModel = None
                        try:
                            # OpenDoc6(FileName, Type, Options, Configuration, Errors, Warnings)
                            swModel = sw_app.OpenDoc6(
                                ruta_abs,
                                swDocPART,
                                swSilentReadOnly,  # Options: Silent + ReadOnly
                                "",               # Configuration (vacío = default)
                                arg_errors,        # Errors  (ByRef VARIANT I4)
                                arg_warnings       # Warnings (ByRef VARIANT I4)
                            )
                        except Exception as try_open_err:
                            err_str = repr(try_open_err)
                            err_code = getattr(try_open_err, 'hresult', None)

                            # ---- Auto-Resurrección COM (RPC Crash -2147023170) ----
                            is_rpc_crash = (
                                "-2147023170" in err_str
                                or (err_code is not None and err_code == -2147023170)
                            )

                            if is_rpc_crash:
                                print(f"[SW-RPC] ⚡ Crash RPC detectado en '{codigo}'. Iniciando resurrección COM...")
                                import logging as _logging
                                _logging.error(f"[SW-RPC] Crash en '{ruta_abs}': {err_str}")

                                # 1. Asesinar el proceso SW muerto
                                try:
                                    os.system("taskkill /F /IM SLDWORKS.exe 2>nul")
                                except Exception:
                                    pass

                                # 2. Liberar referencia COM muerta
                                sw_app = None

                                # 3. Pequeña pausa para que el SO libere el puerto RPC
                                import time as _time
                                _time.sleep(3)

                                # 4. Re-inicializar COM y reconectar a SolidWorks
                                try:
                                    pythoncom.CoUninitialize()
                                except Exception:
                                    pass
                                try:
                                    pythoncom.CoInitialize()
                                except Exception:
                                    pass
                                sw_app = get_sw_app()  # get_sw_app ya aplica _apply_silent_mode

                                if sw_app:
                                    print("[SW-RPC] ✅ Resurrección COM exitosa. Continuando con el siguiente archivo.")
                                else:
                                    print("[SW-RPC] ❌ No se pudo reconectar a SolidWorks. El escáner continuará sin motor SW.")

                                observacion = "Error/Saltado (RPC Crash - COM Reiniciado)"
                                _rpc_crash = True
                            else:
                                # Error de apertura no-RPC (archivo corrupto, falta de permiso, etc.)
                                print(f"[SW] Error abriendo '{codigo}': {err_str}")
                                observacion = f"Error apertura: {str(try_open_err)[:60]}"
                                swModel = None

                    if not _rpc_crash:
                        # Solo procesamos si NO hubo crash RPC
                        if swModel is None:
                            observacion = "No se pudo abrir el archivo"
                            # No lanzamos excepción para que permita llenar el DataFrame en blanco
                        else:
                            try:
                                prop_mgr = swModel.Extension.CustomPropertyManager("")
                                
                                def safe_get_prop(prop_val):
                                    if not prop_val: return ""
                                    if isinstance(prop_val, str): return prop_val
                                    if isinstance(prop_val, (tuple, list)):
                                        if len(prop_val) > 1 and prop_val[1]: return str(prop_val[1])
                                        if len(prop_val) > 0 and prop_val[0]: return str(prop_val[0])
                                    return str(prop_val)

                                # Intentar sobrescribir codigo pieza si está en custom properties
                                get_codigo = prop_mgr.Get("CODIGO_PIEZA")
                                codigo_val = safe_get_prop(get_codigo).strip()
                                if codigo_val:
                                    codigo = codigo_val

                                get_largo = prop_mgr.Get("Largo_CAD")
                                get_ancho = prop_mgr.Get("Ancho_CAD")
                                get_espesor = prop_mgr.Get("Espesor_Perfil_CAD")
                                
                                largo_val = safe_get_prop(get_largo)
                                ancho_val = safe_get_prop(get_ancho)
                                espesor_val = safe_get_prop(get_espesor)

                                if largo_val and ancho_val:
                                    import re
                                    try:
                                        l_clean = str(largo_val).lower().replace("mm", "").strip().replace(',', '.')
                                        a_clean = str(ancho_val).lower().replace("mm", "").strip().replace(',', '.')
                                        l_str = re.sub(r'[^\d.]', '', l_clean)
                                        a_str = re.sub(r'[^\d.]', '', a_clean)
                                        
                                        largo = float(l_str) if l_str and l_str != '.' else 0.0
                                        ancho = float(a_str) if a_str and a_str != '.' else 0.0
                                        
                                        largo_cad = max(largo, ancho)
                                        ancho_cad = min(largo, ancho)
                                        
                                        espesor_cad = 0.0
                                        if espesor_val:
                                            e_clean = str(espesor_val).lower().replace("mm", "").strip().replace(',', '.')
                                            e_str = re.sub(r'[^\d.]', '', e_clean)
                                            espesor_cad = float(e_str) if e_str and e_str != '.' else 0.0
                                        
                                        if largo_cad > 0 and ancho_cad > 0:
                                            observacion = "OK"
                                        else:
                                            observacion = "No detectado (valores incompletos)"
                                    except ValueError as ve:
                                        observacion = f"Error métrico: {ve}"
                                else:
                                    observacion = "No detectado (faltan propiedades)"
                                    
                            except Exception as math_err:
                                observacion = f"Error matemático: {str(math_err)[:50]}"
                                print(f"Error matemático extrayendo {codigo}: {math_err}")
                            finally:
                                try:
                                    sw_app.CloseDoc(abspath)
                                except: pass
                        
            except Exception as extract_err:
                import traceback
                if not observacion:
                    observacion = f"Error: {str(extract_err)[:50]}"
                print(f"❌ Error leyendo {abspath}: {str(extract_err)}")
                traceback.print_exc()

            # Lógica de DXF (Auditoría Cruzada 2D)
            dxf_path = os.path.join(root_path, "BIBLIOTECA_DXF", f'{info["codigo"]}.dxf')
            if not os.path.exists(dxf_path) and codigo != info["codigo"]:
                dxf_path_alt = os.path.join(root_path, "BIBLIOTECA_DXF", f'{codigo}.dxf')
                if os.path.exists(dxf_path_alt):
                    dxf_path = dxf_path_alt

            if os.path.exists(dxf_path):
                tiene_dxf = "Sí"
                try:
                    import ezdxf
                    from ezdxf import bbox
                    dxf_doc = ezdxf.readfile(dxf_path)
                    msp = dxf_doc.modelspace()
                    extents = bbox.extents(msp)
                    if extents.has_data:
                        dx = extents.extmax.x - extents.extmin.x
                        dy = extents.extmax.y - extents.extmin.y
                        lx = max(dx, dy)
                        ax = min(dx, dy)
                        largo_dxf = round(lx, 2)
                        ancho_dxf = round(ax, 2)
                except Exception as dxf_err:
                    print(f"Error parseando DXF {dxf_path}: {dxf_err}")

            data.append({
                "Codigo_Pieza": codigo,
                "Extension": ext,
                "Largo_CAD": round(largo_cad, 2) if largo_cad > 0 else "",
                "Ancho_CAD": round(ancho_cad, 2) if ancho_cad > 0 else "",
                "Espesor_Perfil_CAD": round(espesor_cad, 2) if espesor_cad > 0 else "",
                "Material": "",
                "Observaciones": observacion if observacion else "No detectado",
                "Tiene_DXF": tiene_dxf,
                "Largo_DXF": largo_dxf,
                "Ancho_DXF": ancho_dxf,
                "Ruta_Archivo": abspath
            })
            extraidos += 1
            scan_status["progress"] = extraidos
            
        print("=== EXTRACCIÓN CAD FINALIZADA ===")
        if sw_app:
            try: sw_app.ExitApp()
            except: pass
        if acad_app:
            try: acad_app.Quit()
            except: pass
            
        df = pd.DataFrame(data)
        if df.empty:
            df = pd.DataFrame(columns=["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"])
        else:
             df = df[["Codigo_Pieza", "Extension", "Largo_CAD", "Ancho_CAD", "Espesor_Perfil_CAD", "Material", "Observaciones", "Tiene_DXF", "Largo_DXF", "Ancho_DXF", "Ruta_Archivo"]]
            
        reports_dir = os.path.join(os.getcwd(), "reportes")
        os.makedirs(reports_dir, exist_ok=True)
        report_filename = f"Reporte_CAD.xlsx"
        report_path = os.path.join(reports_dir, report_filename)
        
        df.to_excel(report_path, index=False)
        
        scan_status["status"] = "completed"
        scan_status["excel_path"] = report_path
        
    except Exception as e:
        scan_status["status"] = "error"
        scan_status["error"] = str(e)


@app.post("/api/cad/scan")
def start_cad_scan(payload: ScanCADPayload, background_tasks: BackgroundTasks):
    global scan_status, abortar_escaneo_cad
    
    abortar_escaneo_cad = False
    flag_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "abortar_cad.flag")
    if os.path.exists(flag_path):
        try: os.remove(flag_path)
        except: pass
    
    if payload.root_path == "cancel":
        scan_status["status"] = "cancelled"
        abortar_escaneo_cad = True
        return {"message": "Cancelado"}

    if scan_status["status"] == "scanning":
         return {"message": "Ya hay un escaneo en curso"}
         
    background_tasks.add_task(bg_scan_cad_task, payload.root_path)
    return {"message": "Escaneo iniciado en segundo plano"}

import subprocess
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

cad_execution_logs = []
cad_procesar_status = "idle"

def bg_procesar_cad_task(ruta_raiz: str):
    global cad_execution_logs, cad_procesar_status
    cad_execution_logs.clear()
    cad_procesar_status = "processing"
    
    def log_and_append(msg: str):
        logging.info(msg)
        cad_execution_logs.append(msg)
        
    log_and_append(f"Iniciando procesamiento CAD masivo en: {ruta_raiz}")
    base_dir = os.path.dirname(os.path.abspath(__file__))
    script_dwg = os.path.join(base_dir, "tools", "convertir_dwg.py")
    script_sw = os.path.join(base_dir, "tools", "preparar_solidworks.py")
    
    if not os.path.exists(script_dwg):
        log_and_append(f"Error: No se encontró el script DWG en la ruta absoluta: {script_dwg}")
    else:
        try:
            log_and_append("Ejecutando convertir_dwg.py...")
            process = subprocess.Popen(
                [sys.executable, script_dwg, ruta_raiz],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='cp1252',
                errors='replace'
            )
            for line in iter(process.stdout.readline, ''):
                if line:
                    log_and_append(line.strip())
            process.stdout.close()
            process.wait()
            log_and_append(f"convertir_dwg.py terminó (código {process.returncode})")
        except Exception as e:
            log_and_append(f"Error al ejecutar convertir_dwg.py: {e}")
            
    if not os.path.exists(script_sw):
        log_and_append(f"Error: No se encontró el script SolidWorks en la ruta absoluta: {script_sw}")
    else:
        try:
            log_and_append("Ejecutando preparar_solidworks.py...")
            process = subprocess.Popen(
                [sys.executable, script_sw, ruta_raiz],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='cp1252',
                errors='replace'
            )
            for line in iter(process.stdout.readline, ''):
                if line:
                    log_and_append(line.strip())
            process.stdout.close()
            process.wait()
            log_and_append(f"preparar_solidworks.py terminó (código {process.returncode})")
        except Exception as e:
            log_and_append(f"Error al ejecutar preparar_solidworks.py: {e}")
            
    log_and_append("Procesamiento CAD completado")
    cad_procesar_status = "completed"

@app.post("/api/cad/procesar-directorio")
def procesar_directorio_cad(payload: ScanCADPayload, background_tasks: BackgroundTasks):
    global abortar_escaneo_cad
    abortar_escaneo_cad = False
    flag_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "abortar_cad.flag")
    if os.path.exists(flag_path):
        try: os.remove(flag_path)
        except: pass
    
    background_tasks.add_task(bg_procesar_cad_task, payload.root_path)
    return {
        "success": True, 
        "message": f"Procesamiento CAD iniciado en segundo plano para: {payload.root_path}"
    }


@app.get("/api/cad/status")
def get_cad_status():
    global scan_status, cad_procesar_status, cad_execution_logs
    status_response = scan_status.copy() if scan_status else {}
    status_response["procesar_status"] = cad_procesar_status
    status_response["logs"] = cad_execution_logs
    return status_response

from fastapi.responses import FileResponse
import math

@app.get("/api/cad/download")
def download_cad_report():
    global scan_status
    excel_path = scan_status.get("excel_path", "")
    if not excel_path or not os.path.exists(excel_path):
        raise HTTPException(status_code=404, detail="Archivo Excel no encontrado.")
    return FileResponse(excel_path, media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", filename="Reporte_CAD.xlsx")

@app.post("/api/cad/upload")
async def upload_cad_modifications(file: UploadFile = File(...), x_usuario: Optional[str] = Header(None)):
    if not file.filename.endswith('.xlsx'):
         raise HTTPException(status_code=400, detail="Formato no admitido. Debe ser un archivo .xlsx")
         
    try:
        contents = await file.read()
        df = pd.read_excel(io.BytesIO(contents))
        
        # Validación robusta de NaN de Pandas
        df = df.fillna('')
        
        # Validar que tenga las columnas requeridas
        required_cols = ["Codigo_Pieza", "Largo_CAD", "Ancho_CAD"]
        for col in required_cols:
            if col not in df.columns:
                print(f"ERROR: Falta columna {col}")
                raise HTTPException(status_code=400, detail=f"Falta la columna requerida: {col}")
                
        actualizadas = 0
        ignoradas = 0
        no_encontradas = 0
        
        conn = get_db_connection()
        cursor = conn.cursor()
        
        print(f"=== INICIANDO LECTURA DE {len(df)} FILAS DEL EXCEL ===")
        
        try:
            for index, row in df.iterrows():
                codigo = str(row["Codigo_Pieza"]).strip()
                if not codigo:
                     ignoradas += 1
                     continue
                     
                largo = str(row.get("Largo_CAD", "")).strip()
                ancho = str(row.get("Ancho_CAD", "")).strip()
                espesor = str(row.get("Espesor_Perfil_CAD", "")).strip()
                material_str = str(row.get("Material", "")).strip()
                ruta_str = str(row.get("Ruta_Archivo", "")).strip()
                
                tiene_dxf = str(row.get("Tiene_DXF", "No")).strip()
                largo_dxf_str = str(row.get("Largo_DXF", "")).strip()
                ancho_dxf_str = str(row.get("Ancho_DXF", "")).strip()
                
                # Tratar vacíos
                if not largo or not ancho:
                    print(f"IGNORADA (Fila {index+2}): {codigo} - Medidas vacías")
                    ignoradas += 1
                    continue
                    
                try:
                    largo_float = float(largo)
                    ancho_float = float(ancho)
                    espesor_float = float(espesor) if espesor else None
                except ValueError:
                    print(f"IGNORADA (Fila {index+2}): {codigo} - No son números (L:{largo}, A:{ancho}, E:{espesor})")
                    ignoradas += 1
                    continue
                try:
                    largo_dxf_float = float(largo_dxf_str) if largo_dxf_str else None
                    ancho_dxf_float = float(ancho_dxf_str) if ancho_dxf_str else None
                except ValueError:
                    largo_dxf_float = None
                    ancho_dxf_float = None
                
                # Update Catalogo de piezas
                cursor.execute("""
                    UPDATE Tbl_Maestro_Piezas 
                    SET Largo_CAD = ?, Ancho_CAD = ?, Espesor_Perfil_CAD = ?, Material = ?, Ruta_Archivo = ?,
                        Tiene_DXF = ?, Largo_DXF = ?, Ancho_DXF = ?
                    WHERE Codigo_Pieza = ?
                """, (largo_float, ancho_float, espesor_float, material_str, ruta_str, tiene_dxf, largo_dxf_float, ancho_dxf_float, codigo))
                
                if cursor.rowcount > 0:
                    print(f"ACTUALIZADA: {codigo} (L:{largo_float}, A:{ancho_float})")
                    actualizadas += 1
                    # Opcional: Registrar en auditoria global
                    usr_log = f"SISTEMA_CAD (Operador: {x_usuario})" if x_usuario else "SISTEMA_CAD"
                    registrar_log_global(cursor, codigo, "UPDATE_MEDIDAS_CAD", "", f"L:{largo_float}, A:{ancho_float}", usr_log)
                else:
                    print(f"NO ENCONTRADA: {codigo} - No existe la llave en DB")
                    no_encontradas += 1
                    
            conn.commit()
            print("=== ESCRITURA FINALIZADA CON ÉXITO ===")
            
        except Exception as inner_e:
            conn.rollback()
            raise inner_e
        finally:
            conn.close()
            
        return {
            "status": "success",
            "actualizadas": actualizadas,
            "ignoradas": ignoradas,
            "no_encontradas": no_encontradas
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
        
class CollectRequest(BaseModel):
    source_folder: str

@app.post("/api/cad/collect-missing")
def collect_missing_cad(request: CollectRequest):
    try:
        # 1. Consulta SQL Blindada (Todo convertido a texto para evitar Crash 8114)
        query = """
            SELECT Codigo_Pieza 
            FROM Tbl_Maestro_Piezas 
            WHERE Largo_CAD IS NULL 
               OR CAST(Largo_CAD AS VARCHAR) = '' 
               OR CAST(Largo_CAD AS VARCHAR) = '-'
               OR CAST(Largo_CAD AS VARCHAR) = '0'
        """
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute(query)
        rows = cursor.fetchall()
        
        piezas_faltantes = set()
        for row in rows:
            if row[0]:
                piezas_faltantes.add(str(row[0]).strip().upper())
        
        cursor.close()
        conn.close()

        # 2. Preparar carpeta en el Escritorio
        desktop = os.path.join(os.environ['USERPROFILE'], 'Desktop')
        target_folder = os.path.join(desktop, 'CAD_PENDIENTES')
        if not os.path.exists(target_folder):
            os.makedirs(target_folder)

        # 3. Recorrer la red y copiar
        archivos_copiados = 0
        for root_dir, dirs, files in os.walk(request.source_folder):
            for file in files:
                ext = file.split('.')[-1].upper()
                if ext in ['SLDPRT', 'DWG', 'DXF']:
                    # Extraer el nombre base (sin extensión)
                    base_name = file[:-(len(ext)+1)].strip().upper()
                    # Limpiar prefijo de chapa por si acaso
                    base_name = base_name.replace("CHAPA DESPLEGADA - ", "").strip()
                    
                    if base_name in piezas_faltantes:
                        source_path = os.path.join(root_dir, file)
                        target_path = os.path.join(target_folder, file)
                        
                        # Copiar solo si no existe ya en el destino
                        if not os.path.exists(target_path):
                            shutil.copy2(source_path, target_path)
                            archivos_copiados += 1

        return {
            "piezas_faltantes_en_db": len(piezas_faltantes),
            "archivos_encontrados": archivos_copiados,
            "destino": target_folder
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error durante la recolección: {str(e)}")


def registrar_log_global(cursor, codigo_pieza, accion, anterior, nuevo, usuario):
    try:
        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (codigo_pieza, accion, anterior[:250], nuevo[:250], usuario))
    except Exception:
        pass

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)
