# PROYECTO: INDUSTRIAL MASTER v2.0
> **Fecha:** 05 de Febrero, 2026
> **Estado:** Funcional / En producción
> **Tecnología:** Flutter (Windows) + Python Backend + SQL Server

## 1. Arquitectura de Datos

### Diagrama de Base de Datos
La base de datos `DB_Materiales_Industrial` es el corazón del sistema. Se diseñó para eliminar la ambigüedad de los procesos múltiples.

**Tabla Principal: `Tbl_DetalleMateriales`**
| Columna | Tipo | Descripción |
| :--- | :--- | :--- |
| `ID` | INT (PK) | Identificador único auto-incremental. |
| `Codigo_Pieza` | NVARCHAR(100) | Clave principal lógica (Pieza). Indexada. |
| `Descripcion` | NVARCHAR(MAX) | Descripción completa del material. |
| `Material` | NVARCHAR(100) | Tipo de materia prima (ej. ACERO A36). |
| `Proceso_Primario` | NVARCHAR(100) | Proceso principal (ej. LASER). |
| `Proceso_1` | NVARCHAR(100) | Proceso secundario (ej. DOBLEZ). |
| `Proceso_2` | NVARCHAR(100) | Proceso terciario. |
| `Proceso_3` | NVARCHAR(100) | Cuarto proceso (si aplica). |
| `Archivo_Origen` | NVARCHAR(255) | Nombre del Excel de donde salió el dato. |

**Vista de Auditoría: `Vista_Conflictos_Procesos`**
Esta vista es crítica. Agrupa por `Codigo_Pieza` y cuenta cuántas variantes de `Proceso_Primario` existen. Si el conteo es > 1, significa que Ingeniería ha definido la pieza de formas distintas en diferentes proyectos.

## 2. Lógica del Importador (ETL)

El script `importador_v3.py` realiza la magia de transformar Excels humanos en datos estructurados.

1.  **Lectura Inteligente:**
    *   Ignora las primeras 3 filas.
    *   Lee el encabezado en la **Fila 4**.
    *   Salta la fila 5 (espaciador vacío).
    *   Comienza a leer datos reales desde la **Fila 6**.

2.  **Normalización:**
    *   Rellena celdas vacías (`ffill`) en columnas agrupadoras como "Estación" o "Ensamble".
    *   Elimina filas basura que no tengan Código de Pieza.

3.  **Carga Atómica:**
    *   Al procesar un archivo, primero **borra** todos los registros previos de ese archivo específico en la DB.
    *   Luego inserta los nuevos. Esto permite re-importar un Excel corregido sin duplicar datos.

## 3. Guía de Solución de Errores (Troubleshooting)

### Caso: "La aplicación abre pero la tabla está en blanco"
**Causa Raíz:** El "puente" entre Flutter y Python está fallando al comunicarse.
1.  **Verificar JSON:** El script de Python puede estar imprimiendo advertencias (Warnings) de base de datos antes del JSON. Flutter no puede leer eso.
    *   *Solución:* Se ha parcheado `data_bridge.py` para suprimir warnings (`warnings.filterwarnings('ignore')`).
2.  **Verificar Ruta:** Si ejecutas el `.exe` fuera de su carpeta original, no encontrará la carpeta `scripts/`.
    *   *Solución:* Asegúrate de que la carpeta `scripts` esté siempre al lado de `industrial_manager.exe`.

### Caso: "Error de Conexión SQL"
1.  Verificar que `SQL Server (SQLEXPRESS)` esté en ejecución en Services.msc.
2.  Confirmar cadena: `Trusted_Connection=True` requiere que el usuario de Windows tenga permisos en SQL.

---
*Documento generado automáticamente por Antigravity Agent.*
