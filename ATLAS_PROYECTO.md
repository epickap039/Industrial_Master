# ATLAS DEL PROYECTO: Industrial Manager v15.5

## 1. Árbol de Directorios Principal

```text
/industrial_manager_v15_5/
│
├── backend/                        # Backend REST en FastAPI (Python)
│   ├── server.py                   # API Principal (Endpoints REST, WebSockets opcionales)
│   ├── requirements.txt            # Dependencias de Python (FastAPI, pyodbc, pandas, ezdxf, etc.)
│   └── tools/                      # Scripts de automatización y COM (CAD y externos)
│       ├── convertir_dwg.py        # Conversor con AutoCAD (pywin32) de DWG a DXF
│       └── preparar_solidworks.py  # Script base para interacción con SolidWorks
│
├── lib/                            # Frontend UI en Flutter (Dart)
│   ├── main.dart                   # Punto de entrada de la app, NavigationView principal, y URL del backend
│   ├── screens/                    # Pantallas de la aplicación
│   │   ├── arbitration.dart        # Motor de arbitraje y validaciones masivas (Regla de Oro/Espejo)
│   │   ├── auditor.dart            # Módulo de Auditoría de Excel/SQL
│   │   ├── bom_manager.dart        # Gestor de Listas de Materiales (BOM) por Folios y Nodos
│   │   ├── cad_scanner_screen.dart # Dashboard de escáner en lote para SolidWorks y AutoCAD
│   │   ├── catalog.dart            # Catálogo Maestro CRUD de piezas estándar y material CAD
│   │   ├── editor.dart             # Componente de edición básica (posible auxiliar)
│   │   ├── engineering_map.dart    # Mapa panorámico de ingenierías y flujos
│   │   ├── history.dart            # Log del Historial de Cambios (Audit Trail)
│   │   ├── home.dart               # Splash screen / Landing
│   │   ├── login.dart              # Gestor de sesiones e identidades de ingeniería
│   │   ├── materials_list.dart     # Lista base de metales e inputs de estandarización
│   │   ├── project_management.dart # Gestor de macroproyectos y dossiers
│   │   ├── qa_dashboard.dart       # Pantalla de aseguramiento de calidad (QA) e inspección de VINs
│   │   ├── settings.dart           # Configurador global de carpetas maestras
│   │   ├── standardization.dart    # Herramienta de normalización de cadenas y Nomenclaturas
│   │   └── vin_dossier.dart        # Pantalla detallada de cada Vehículo (VIN)
│   │
│   └── widgets/                    # Componentes modulares visuales
│       └── conflict_dialog.dart    # Renderizador del motor de arbitraje para resolver conflictos (Excel vs SQL)
│
├── windows/                        # Entorno nativo de Flutter para ejecutables Windows
└── BLUEPRINT_INTEGRAL_v15.5.md     # Manifiesto o documento de objetivos del usuario
```

---

## 2. Diccionario de Archivos Clave

### A. Backend (`backend/`)

- **`server.py`**: El cerebro del servidor. Utiliza `FastAPI` para exponer la comunicación hacia Flutter. Se conecta al SQL Server usando `pyodbc`. Alberga utilerías asíncronas de escaneo (`CoInitialize` para COM models) usando librerías como `ezdxf` o `win32com.client`.
- **`tools/convertir_dwg.py`**: Utilidad aislada de Python construida con `win32com.client`. Abre silenciosamente AutoCAD `acad.exe`, abre archivos `.dwg` problemáticos, los sanitiza y los guarda o exporta nativamente a `.dxf` para el escáner y cortadora láser.
- **`tools/preparar_solidworks.py`**: Interfaz similar (COM) pero con `SLDWORKS.exe`. Usado originalmente, pero la lógica fuerte y segura de SolidWorks ahora reside inyectada y multihilo en el `server.py` como `bg_scan_cad_task`.

### B. Frontend (`lib/`)

- **`main.dart`**: Renderiza la barra de navegación lateral `NavigationView` (estilo Fluent Design), declara el tema oscuro/claro de Windows y almacena el estado de las sesiones activas (`_currentUser`). Contiene la ruta del servidor API (ej. `192.168.1.73:8001`).
- **`screens/cad_scanner_screen.dart`**: Herramienta donde el usuario escanea carpetas de ingeniería. Tiene conexión bidireccional mediante *polling* a una variable `background_status` en el backend para mostrar progreso asíncrono. Soporta resiliencia de estado con `AutomaticKeepAliveClientMixin`.
- **`screens/catalog.dart`**: La base de datos viva. Tabla interactiva en FluentUI donde se presentan cientos/miles de registros. Permite Edición individual, Copiar la Macro VBA al Portapapeles, Borrar en caliente usando `DELETE`, u ocultar/mostrar atributos extraídos por AutoCAD y SolidWorks (`Tiene_DXF`, `Largo_CAD`, etc.).
- **`screens/bom_manager.dart`**: Control de ensamble por folios. Construye jerarquías visuales. Si una pieza se modifica aquí, se impactan revisiones.
- **`screens/arbitration.dart` y `widgets/conflict_dialog.dart`**: El motor comparador de matrices Excel (OpenPyxL transportado vía JSON). Evalúa lo subido contra lo existente en SQL Server. Detecta `UPDATE` y alerta visualmente al usuario si dos atributos están compitiendo por colisión, dejando el poder de decidir la fuente verdadera.

---

## 3. Mapa de Conexiones Críticas (El Sistema Circulatorio)

1. **Motor de Importación de Listas (`BOM / Excel`)**

- *Flujo:* `auditor.dart` envía `.xlsx` vía multipart/form-data.
- *Endpoint:* `POST /api/excel/procesar` en `server.py`.
- *Tablas Impactadas:* `Tbl_Maestro_Piezas`, `Tbl_Materiales_Aprobados`, `Tbl_Conflictos_Temporales`.

1. **Escáner Geométrico (CAD Pipeline)**

- *Flujo:* Usuario pulsa Búsqueda en `cad_scanner_screen.dart` enviando un path estático.
- *Endpoint:* `POST /api/cad/procesar-directorio` en `server.py` (Llama a `subprocess.run(["python",...])` a AutoCAD COM).
- *Endpoint Secundario:* `POST /api/cad/scan` en `server.py` (Usa SolidWorks COM y `ezdxf` multihilo).
- *Resultado:* Guarda Excel temporal de resultados (`Largo_CAD`, `Ancho_CAD`, `Tiene_DXF`). Este Excel luego pasa al flujo 1 para hacer la inyección base.

1. **Auditoria Log e Historial**

- *Motor Backend:* Cada función PUT o POST importante de `server.py` manda a llamar la función interna `log_audit()` del archivo Python.
- *Tablas Impactadas:* `Tbl_Historial_Cambios`. Se alimenta permanentemente de forma silenciosa para asegurar la trazabilidad ISO.

---

## 4. Variables de Entorno, Configuración y Base de Datos

- **Base de Datos:** SQL Server (Autenticación via `pyodbc` con `TrustServerCertificate`).
  - Modificada en la macro variable en `server.py`: `DB_DATABASE = 'DB_Materiales_Industrial'`.

- **Directorio de Convenciones:**
  - `BIBLIOTECA_DXF`: Regla estática del Backend. Los archivos `.dxf` a buscar para el `ezdxf_bounding_box` obligatoriamente deben estar guardados en una subcarpeta llamada estrictamente `BIBLIOTECA_DXF` dentro de la carpeta madre escaneada para inyectar correctamente la dualidad `(Tiene_DXF)`.
  - `CAD API Models`: SolidWorks exige rutas locales o de red (Z:\) en formato de ruta absoluta de Windows (`C:\...` ó `\\Servidor\...`).

- **Red (API URL):**
  - Se encuentra "hardcodeada" localmente en la PC Host o inicializada en `main.dart` bajo la constante dinámica: `API_URL = 'http://192.168.1.73:8001'`.
