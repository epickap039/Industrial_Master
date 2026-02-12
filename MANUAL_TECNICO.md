# Manual Técnico: Sistema Industrial “Industrial Master”

Este manual describe la arquitectura, flujo y mantenimiento del sistema de gestión de materiales para el área industrial.

## 1. Arquitectura del Sistema
El sistema utiliza una arquitectura híbrida para maximizar la compatibilidad con SQL Server y ofrecer una interfaz moderna en Windows.

**Diagrama de Flujo:**
`Excel Source` -> `Python ETL (importador.py)` -> `SQL Server DB` <- `Python Bridge` <- `Flutter App`

1.  **Excel Source:** Archivos generados por ingeniería.
2.  **Python ETL:** Script `importador.py`. Lee los archivos, aplica reglas de limpieza y carga a SQL.
3.  **SQL Server:** Base de datos central `DB_Materiales_Industrial`.
4.  **Python Bridge:** Script `data_bridge.py`. Provee una interfaz JSON para la App.
5.  **Flutter App:** Interfaz de usuario (Desktop) para búsqueda, edición y captura.

## 2. Solución de Errores (Troubleshooting)

### Error: "Tabla de Materiales Vacía"
*   **Diagnóstico:** Si la App abre pero no muestra datos, el problema suele ser la comunicación con el "Bridge".
*   **Causa Detectada:** Los scripts de Python imprimían advertencias técnicas (Warnings) antes del JSON, lo cual rompía el parseo en Flutter.
*   **Solución:** Se agregó la supresión de warnings en `data_bridge.py` (`warnings.filterwarnings('ignore')`).
*   **Segunda Causa:** Falta de la carpeta `scripts/` al lado del ejecutable `.exe`.
*   **Solución:** Copiar siempre la carpeta `scripts` al mismo nivel que `industrial_manager.exe`.

### Error: "Datos no actualizados"
*   **Causa:** No se ejecutó el importador.
*   **Solución:** Ejecutar `python importador.py` cada vez que se agreguen nuevos Excels a la carpeta `C:\Sistema_Materiales\Excel_Entrada`.

## 3. Guía de Usuario y Carga de Datos

### Pasos para Cargar Materiales:
1.  Coloque los archivos `.xlsx` en `C:\Sistema_Materiales\Excel_Entrada`.
2.  Abra una terminal y ejecute:
    ```powershell
    python importador.py
    ```
3.  El script informará cuántas piezas se insertaron.
4.  Abra la App para ver y editar los datos.

### Pantalla "Nueva Lista":
*   Al ingresar un código existente, la App rellenará los campos automáticamente basándose en la configuración histórica de ingeniería.
*   Si el código es nuevo, la App le permitirá definirlo y guardarlo, creando un nuevo estándar.

---
*Manual versión 2.0. Generado para NotebookLM.*
