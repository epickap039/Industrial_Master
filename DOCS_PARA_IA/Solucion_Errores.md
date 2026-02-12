# Solución de Errores Comunes

## 1. No se conecta a la Base de Datos

- **Causa:** El servicio `MSSQL$SQLEXPRESS` está detenido.
- **Solución:** Abre "Servicios" en Windows, busca "SQL Server (SQLEXPRESS)" y dale a Iniciar.

## 2. Los datos de Excel no se cargan

- **Causa:** El Excel no tiene el formato esperado (Encabezado en fila 4).
- **Solución:** Asegúrate de que la palabra "CODIGO" o "CÓDIGO" aparezca en la fila 4. El script de Python busca palabras clave para identificar columnas.

## 3. Python 'pandas' o 'sqlalchemy' no encontrado

- **Solución:** Ejecuta en la terminal:
  `pip install pandas sqlalchemy pyodbc openpyxl`

## 4. La App muestra pantalla vacía

- **Causa:** No hay registros en `Tbl_Maestro_Piezas`.
- **Solución:** Ejecuta `python carga_inicial.py` para alimentar la base de datos por primera vez.
