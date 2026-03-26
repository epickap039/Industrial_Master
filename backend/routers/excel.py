"""API router: excel."""
import ast
import io
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import openpyxl
import pandas as pd
import pyodbc
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from database import get_db_connection, _int_from_count_row
from models import *
from audit_service import registrar_auditoria

router = APIRouter()

# ── HELPERS DE LIMPIEZA ──────────────────────────────────────────────────────

def _clean_str(value) -> str:
    """LTRIM/RTRIM seguro para cualquier valor (None, NaN, numeric)."""
    import math
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value).strip()


def _material_safe(value) -> str:
    """Devuelve el material limpio o 'POR DEFINIR' si está vacío/nulo.

    Regla de negocio: Material vacío, None, NaN o espacios en blanco
    SIEMPRE se reemplaza por el literal 'POR DEFINIR' antes de persistir
    en Tbl_Maestro_Piezas, para evitar filas huérfanas sin material.
    """
    cleaned = _clean_str(value)
    return cleaned if cleaned else "POR DEFINIR"


# 5. MOTOR DE ARBITRAJE EXCEL
@router.post("/api/excel/procesar")
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
        
        # ── 2. Mapeo fijo por coordenadas (sin detección de cabeceras) ─────────
        # Formato esperado:
        # B=1 Estacion, C=2 Ensamble, D=3 Codigo, E=4 Material, F=5 Medida,
        # G=6 Cantidad, H=7 Simetria, I=8 Proceso_Primario, J=9 Proceso_1,
        # K=10 Proceso_2, L=11 Proceso_3
        IDX_ESTACION = 1
        IDX_ENSAMBLE = 2
        IDX_CODIGO = 3
        IDX_MATERIAL = 4
        IDX_MEDIDA = 5
        IDX_CANTIDAD = 6
        IDX_SIMETRIA = 7
        IDX_PP = 8
        IDX_P1 = 9
        IDX_P2 = 10
        IDX_P3 = 11
        start_row = 6
        for row in ws.iter_rows(min_row=start_row, values_only=True):
            
            if not row: continue

            # Forward Fill Logic
            estacion = row[IDX_ESTACION] if len(row) > IDX_ESTACION and row[IDX_ESTACION] is not None else last_estacion
            ensamble = row[IDX_ENSAMBLE] if len(row) > IDX_ENSAMBLE and row[IDX_ENSAMBLE] is not None else last_ensamble
            
            if estacion: last_estacion = estacion
            if ensamble: last_ensamble = ensamble

            # Validar Codigo Pieza (Columna D - Index 3)
            if len(row) <= IDX_CODIGO: continue
            raw_codigo = row[IDX_CODIGO]
            codigo_pieza = str(raw_codigo).strip() if raw_codigo else None
            
            if not codigo_pieza or codigo_pieza.lower() in ['none', 'codigo', 'codigo_pieza', '']:
                continue

            # Extracción segura con manejo de nulos.
            def get_val(idx: int) -> str:
                if idx < len(row) and row[idx] is not None:
                    return _clean_str(row[idx])  # LTRIM/RTRIM universal
                return ""

            # El archivo no incluye columna de descripción; se fija valor estático.
            descripcion_excel = "N/A"
            # ── CANDADO ANTI-VACÍOS: Material saneado desde la lectura ────────
            material_excel = _material_safe(get_val(IDX_MATERIAL))

            scan_data.append({
                'Estacion':          last_estacion,
                'Ensamble':          last_ensamble,
                'Codigo_Pieza':      codigo_pieza,
                'Cantidad':          get_val(IDX_CANTIDAD),
                'descripcion':       descripcion_excel,
                'material':          material_excel,
                'Descripcion_Excel': descripcion_excel,
                'Medida_Excel':      get_val(IDX_MEDIDA),
                'Material_Excel':    material_excel,
                'Simetria':          get_val(IDX_SIMETRIA),
                'Proceso_Primario':  get_val(IDX_PP),
                'Proceso_1':         get_val(IDX_P1),
                'Proceso_2':         get_val(IDX_P2),
                'Proceso_3':         get_val(IDX_P3),
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

                if item['Material_Excel'].lower() != mat_sql.lower():
                     if item['Material_Excel']:
                        status = "CONFLICTO"
                        detalles.append(f"Mat: '{item['Material_Excel']}' vs SQL '{mat_sql}'")
                
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
@router.post("/api/excel/sincronizar")
async def sincronizar_excel(items: List[SincronizacionItem], x_usuario: Optional[str] = Header(None)):
    conn = get_db_connection()
    cursor = conn.cursor()
    
    procesados = 0
    errores = 0
    
    try:
        for item in items:
            # ── CANDADO ANTI-VACÍOS (última línea de defensa antes de SQL) ────
            # _clean_str aplica LTRIM/RTRIM a todos los campos; _material_safe
            # garantiza que Material nunca llega como NULL/vacío a la BD.
            desc      = _clean_str(item.Descripcion)
            medida    = _clean_str(item.Medida)
            material  = _material_safe(item.Material)  # ← "POR DEFINIR" si vacío
            link      = _clean_str(item.Link_Drive)
            simetria  = _clean_str(item.Simetria)
            proc_prim = _clean_str(item.Proceso_Primario)
            proc_1    = _clean_str(item.Proceso_1)
            proc_2    = _clean_str(item.Proceso_2)
            proc_3    = _clean_str(item.Proceso_3)
            
            # Auditoría
            usuario = item.Modificado_Por if item.Modificado_Por else (x_usuario if x_usuario else "Importador Excel")

            if item.Estado == "NUEVO":
                # INSERT: 1er ? = IF NOT EXISTS; luego (Codigo_Pieza, Descripcion, Medida, Material, ...).
                cursor.execute("""
                    IF NOT EXISTS (SELECT 1 FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?)
                    BEGIN
                        INSERT INTO Tbl_Maestro_Piezas 
                        (Codigo_Pieza, Descripcion, Medida, Material, Simetria, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3, Link_Drive, Ultima_Actualizacion, Modificado_Por)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, GETDATE(), ?)
                    END
                """, (
                    item.Codigo_Pieza,
                    item.Codigo_Pieza,
                    desc,
                    medida,
                    material,
                    simetria,
                    proc_prim,
                    proc_1,
                    proc_2,
                    proc_3,
                    link,
                    usuario,
                ))
                

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

                # UPDATE: orden de ? = Descripcion, Medida, Material, …, último ? = Codigo_Pieza (WHERE).
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
                """, (
                    desc,
                    medida,
                    material,
                    simetria,
                    proc_prim,
                    proc_1,
                    proc_2,
                    proc_3,
                    link,
                    usuario,
                    item.Codigo_Pieza,
                ))
                
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
@router.post("/api/config/update_links")
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

@router.post("/api/excel/actualizar_enlaces")
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

@router.post("/api/excel/auditar")
async def auditar_excel(file: UploadFile = File(...)):
    """
    Audita un archivo Excel comparando múltiples columnas con la BD.
    Retorna errores puntuales para UI y reporte detallado para Excel.
    """
    print(f"--- INICIANDO AUDITORÍA AVANZADA: {file.filename} ---")
    contents = await file.read()
    
    errores = []
    reporte_detallado = [] # Lista de objetos con contexto completo
    
    # Índices 0-based en fila Excel (col D=3 código; E=4 Desc; F=5 Medida; G=6 Material)
    field_map = {
        'Descripcion': 4,
        'Medida': 5,
        'Material': 6,
        'Simetria': 7,
        'Proceso_Primario': 8,
        'Proceso_1': 9,
        'Proceso_2': 10,
        'Proceso_3': 11,
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
                SELECT Descripcion, Medida, Material, Simetria, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3
                FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?
            """, (codigo_excel,))
            row_bd = cursor.fetchone()
            
            if row_bd:
                vals_bd = {
                    'Descripcion': str(row_bd[0] or "").strip(),
                    'Medida': str(row_bd[1] or "").strip(),
                    'Material': str(row_bd[2] or "").strip(),
                    'Simetria': str(row_bd[3] or "").strip(),
                    'Proceso_Primario': str(row_bd[4] or "").strip(),
                    'Proceso_1': str(row_bd[5] or "").strip(),
                    'Proceso_2': str(row_bd[6] or "").strip(),
                    'Proceso_3': str(row_bd[7] or "").strip(),
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

@router.post("/api/excel/corregir")
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

        
        # Mapeo Campo -> Columna Excel 1-based (plantilla maestra).
        # Descripcion → columna E (texto pieza) → SQL Descripcion.
        # Material → columna G → SQL Material.
        # D(4)=Codigo, E(5)=Desc, F(6)=Medida, G(7)=Material, H(8)=Simetria
        # I(9)=Primario, J(10)=Proc1, K(11)=Proc2, L(12)=Proc3
        col_map = {
            'Descripcion': 5,  # E → SQL Descripcion
            'Medida': 6,       # F
            'Material': 7,     # G → SQL Material
            'Simetria': 8,     # H
            'Proceso_Primario': 9,  # I
            'Proceso_1': 10,   # J
            'Proceso_2': 11,  # K
            'Proceso_3': 12,  # L
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

@router.post("/api/system/open_file")
async def open_file_endpoint(payload: Dict[str, str]):
    path = payload.get('path')
    if not path or not os.path.exists(path):
         raise HTTPException(status_code=404, detail="Archivo no encontrado")
    
    try:
        os.startfile(path)
        return {"status": "ok"}
    except Exception as e:
         raise HTTPException(status_code=500, detail=str(e))

@router.post("/api/excel/exportar_reporte")
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
        
        headers = [
            'Fila', 'Código', 'Fuente', 'Descripción', 'Medida', 'Material',
            'Simetría', 'Proceso Primario', 'Proceso 1', 'Proceso 2', 'Proceso 3',
        ]
        ws.append(headers)
        
        # Aplicar estilo headers
        for cell in ws[1]:
            cell.font = header_font
            cell.fill = header_fill
            cell.alignment = Alignment(horizontal="center")

        current_row = 2
        
        # Ordenar columnas para iteración
        col_keys = [
            'Descripcion', 'Medida', 'Material', 'Simetria',
            'Proceso_Primario', 'Proceso_1', 'Proceso_2', 'Proceso_3',
        ]

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

