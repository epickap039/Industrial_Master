# Plan de Arquitectura: Industrial Master v5.0

Este documento detalla la reingeniería del sistema para alcanzar la versión 5.0, centrada en la **trazabilidad total** y **UX de ingeniería**.

## 1. Infraestructura de Datos (SQL Server)

Se realizarán cambios en el esquema para permitir el rastreo de filas exactas.

* **Tbl_Historial_Proyectos**:
  * Nueva columna: `Numero_Fila_Excel` (INT).
* **V_Auditoria_Conflictos**:
  * Se incluirá `Numero_Fila_Excel` en la vista para que el usuario sepa dónde buscar el error en el Excel físico.

## 2. Motor de Ingesta ETL (Python)

* **Normalización de Descripciones**: Se ajustará `carga_inicial.py` para leer exclusivamente la columna "DESCRIPCION" sin concatenaciones automáticas del código.
* **Captura de Fila**: Se utilizará el índice de iteración de Pandas (`df.iterrows()`) para guardar el número de fila real (Index + offset del header).

## 3. Interfaz de Usuario (Flutter Premium UI)

### 📊 Catálogo Maestro (DataGrid & Edición)

* **Nuevo Widget DataGrid**: Migración de la vista de lista a una tabla profesional con columnas fijas para los 4 Procesos.
* **Edición Inline**: Las celdas serán editables. Al confirmar (ENTER), se disparará un `UPDATE` a la base de datos a través del `data_bridge.py`.
* **Hipervínculos Inteligentes**: La columna "Medida" detectará rutas de red (`\\server\path`) o archivos `.pdf`/`.dwg` y permitirá abrirlos con un clic.

### ⚖️ Nuevo Árbitro de Conflictos

* **Diseño Split-Screen**: Modal rediseñado con comparación lado a lado.
* **Header de Trazabilidad**: Indicador destacado en rojo con: `Fuente: [Archivo.xlsx] | Fila: [N]`.
* **Resolución Triple**:
    1. **Mantener Maestro**: Ignorar el cambio.
    2. **Aplicar Excel**: Sobreescribir con los datos del archivo.
    3. **Corregir Manualmente**: Si ambos están mal, se habilitará un formulario de edición rápida en la misma ventana para guardar el dato correcto definitivo en la Base de Datos.

## 4. Dependencias a Incorporar

* `syncfusion_flutter_datagrid`: Para el manejo de tablas industriales con edición.
* `url_launcher`: Para la apertura de archivos y rutas de red.

---
**Espero su aprobación para proceder con la implementación de la Fase 1 y 2.**
