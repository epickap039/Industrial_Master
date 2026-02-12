# Industrial Master v4.0 - Premium Suite (Contexto Completo)

## 🚀 Estado de la Aplicación (Probado y Operativo)

### 1. Funcionalidad Core

* **Automatización (Ingesta):**
  * Lee archivos `.xlsx` de `C:\Sistema_Materiales\Excel_Entrada`.
  * Mapea 4 Procesos (Primario, 1, 2, 3) + Código, Descripción, Material.
  * **Probado:** El proceso soporta tildes y caracteres especiales sin cerrarse. Los logs son persistentes (no se borran al navegar).
* **Catálogo Maestro:**
  * Visualiza la tabla central de ingeniería.
  * **Probado:** Se corrigió un error que impedía mostrar los datos (nombre de función incorrecto en el puente de Python). Ahora muestra la lista completa.
  * Filtros inteligentes por cada columna de proceso.
* **Árbitro de Conflictos:**
  * Detecta discrepancias entre Excels cargados y la Base de Datos.
  * **Botón Resolver (Probado):** Abre una ventana comparativa y permite actualizar el Maestro con los datos del nuevo archivo con un clic.
* **Creador de Listas:**
  * Herramienta de entrada manual con autocompletado desde la DB al presionar 'Enter' en el código.

### 2. Correcciones de Ingeniería Aplicadas

* **Estabilidad de Texto (UTF-8):** Se implementó `allowMalformed: true` en el decodificador de Dart y se forzó `PYTHONIOENCODING=utf-8` para evitar crashes por caracteres en español.
* **Puente de Datos (data_bridge.py):** Se arregló el error `name 'get_all' is not defined` que causaba que el catálogo apareciera vacío.
* **Portabilidad (Rutas):** El sistema detecta su propia ruta de ejecución (`Platform.resolvedExecutable`) para encontrar la carpeta `scripts/`, funcionando en cualquier ubicación.
* **Persistencia UI:** Se añadió `AutomaticKeepAlive` en la vista de automatización para evitar interrupciones en procesos largos.

### 3. Información para Seguimiento

* **DB:** SQL Server (`DB_Materiales_Industrial`).
* **Backend:** Python 3.x (Pandas + SQLAlchemy).
* **Frontend:** Flutter (Fluent UI).
* **Build Actual:** Versión 4.0 Release (Windows x64).
