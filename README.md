# 🏭 Industrial Master v60.0

> **Sistema integral de gestión, estandarización, trazabilidad y automatización CAD para operaciones industriales.**
>
> Plataforma Desktop (Windows) construida con Flutter + FastAPI para el control total del ciclo de vida de materiales, piezas mecánicas y ensambles.

---

## 📋 Tabla de Contenidos

- [Stack Tecnológico](#-stack-tecnológico)
- [Arquitectura del Sistema](#-arquitectura-del-sistema)
- [Módulos de la Aplicación](#-módulos-de-la-aplicación)
- [Backend API](#-backend-api-fastapi)
- [Herramientas CAD](#-herramientas-cad)
- [Base de Datos](#-base-de-datos-sql-server)
- [Temas Visuales](#-temas-visuales)
- [Instrucciones de Ejecución](#-instrucciones-de-ejecución)
- [Protocolo de Build Limpio](#-protocolo-de-build-limpio)
- [Infraestructura de Red](#-infraestructura-de-red)
- [Bitácora de Errores Críticos](#-bitácora-de-errores-críticos)
- [Industrial Master v15.5](#industrial-master-v155)

---

## Industrial Master v15.5

Rama de trabajo: **`v15.5_Clean_Rebuild`**. Incluye el **Centro de Monitoreo** (Comando Directivo), extensiones del **gestor de tareas**, **configuración de usuarios** del comando, bandeja de **notificaciones** en cliente y ajustes del **Radar de impacto** (simulación multi-pieza, presupuestos de tiempo).

### Documentación en el repositorio

| Documento | Contenido |
|-----------|-----------|
| [DOCUMENTACION_CENTRO_MONITOREO.md](DOCUMENTACION_CENTRO_MONITOREO.md) | Centro de Monitoreo / Comando Directivo: modelo de datos, API, UI y flujos Andon. |
| [DOCUMENTACION_PRESENTACION_DIRECTIVA.md](DOCUMENTACION_PRESENTACION_DIRECTIVA.md) | Enfoque de presentación para directivos (visión de producto y arquitectura). |
| [RADAR_IMPACTO_ANALISIS_Y_PROPUESTAS.md](RADAR_IMPACTO_ANALISIS_Y_PROPUESTAS.md) | Análisis y propuestas sobre el módulo Radar de impacto. |
| [RESUMEN_IA_CENTRO_MONITOREO_Y_RADAR.md](RESUMEN_IA_CENTRO_MONITOREO_Y_RADAR.md) | Resumen operativo entre Centro de Monitoreo y Radar. |

### Archivos y rutas nuevos o clave

- **Monitoreo:** `lib/screens/monitoreo_tareas_screen.dart`, `lib/screens/monitoreo/`
- **Usuarios (comando):** `lib/screens/configuracion_usuarios_screen.dart`, `backend/routers/usuarios.py`, script `backend/sql/create_tbl_comando_usuarios.sql`
- **Gestor de tareas / SQL:** `backend/routers/gestor_tareas.py` y migraciones `backend/sql/add_gestor_comando_directivo.sql`, `add_gestor_usuario_asignado.sql`, `add_gestor_checklist_meta_grupo.sql`, `add_gestor_tareas_motivo_cancelacion.sql`
- **Tiempos de simulación Radar:** `backend/data/radar_tiempos.json` (persistido vía API en `backend/routers/engineering.py`)
- **Notificaciones en app:** `lib/services/notification_inbox_service.dart`

---

## 🛠️ Stack Tecnológico

| Capa | Tecnología | Versión |
|---|---|---|
| **Frontend** | Flutter + Dart (`fluent_ui`) | SDK ^3.7.2 |
| **Backend** | Python + FastAPI + Uvicorn | FastAPI ≥ 0.95 |
| **Base de Datos** | Microsoft SQL Server | 2019+ |
| **CAD Integration** | SolidWorks COM / AutoCAD COM (`pywin32`) | — |
| **Análisis DXF** | `ezdxf` | — |
| **Planillas** | `pandas` + `openpyxl` | Pandas ≥ 2.0 |

### Dependencias Flutter (`pubspec.yaml`)

```yaml
fluent_ui: ^4.11.5    # UI estilo Windows 11 nativo
file_picker: ^10.3.10  # Selector de archivos nativo del SO
http: ^1.6.0           # Comunicación REST con el backend
shared_preferences:    # Persistencia de sesión y tema
url_launcher: ^6.3.2   # Apertura de planos y archivos
excel: ^4.0.6          # Generación de reportes Excel
fl_chart: ^0.70.2      # Gráficas en el Analytics Dashboard
intl: ^0.19.0          # Formateo de fechas y monedas
pasteboard: ^0.5.0     # Pegar capturas desde portapapeles
```

### Dependencias Python (`requirements.txt`)

```
fastapi>=0.95.0
uvicorn>=0.22.0
pyodbc>=4.0.39
pandas>=2.0.0
python-multipart>=0.0.6
openpyxl>=3.1.2
```

---

## 🏗️ Arquitectura del Sistema

```
┌─────────────────────────────────────────────────────────┐
│               INDUSTRIAL MASTER v60.0                   │
│                                                         │
│  ┌──────────────────┐      HTTP :8001     ┌──────────┐  │
│  │  Flutter Desktop │ ◄──────────────────► │ FastAPI  │  │
│  │  (Windows App)   │                      │ Backend  │  │
│  └──────────────────┘                      └────┬─────┘  │
│                                                 │         │
│                                          ODBC/TCP:1433    │
│                                                 │         │
│                                    ┌────────────▼──────┐  │
│                                    │  SQL Server       │  │
│                                    │  192.168.1.73     │  │
│                                    └───────────────────┘  │
│                                                           │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  CAD Pipeline (Windows COM via pywin32)             │  │
│  │  SolidWorks.exe ◄──── server.py ────► acad.exe     │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## 📱 Módulos de la Aplicación

La aplicación presenta un `NavigationView` con sidebar lateral (estilo Fluent Design / Windows 11). Los módulos se agrupan en secciones expandibles.

### 🏠 Lobby Principal (`lobby_screen.dart`)
Pantalla de bienvenida. Muestra tarjetas de acceso rápido a cada módulo con descripciones detalladas y guía de uso. Adapta el contenido según el rol del usuario (`ADMIN` / `USER` / `QA`).

---

### 📂 Sección: Consultas Rápidas

#### 📦 Catálogo Maestro (`catalog.dart`)
- Tabla interactiva con miles de registros de `Tbl_Maestro_Piezas`.
- Búsqueda y filtrado en tiempo real.
- CRUD completo: Editar descripción/medida, eliminar piezas con confirmación.
- Visualización de metadatos CAD: `Largo_CAD`, `Ancho_CAD`, `Tiene_DXF`, etc.
- Botón para **copiar la Macro VBA al Portapapeles** para inyectar propiedades en SolidWorks.

#### 🔩 Materiales Oficiales (`materials_list.dart`)
- Lista de materiales aprobados (`Tbl_Materiales_Aprobados`).
- Función **"Hacer Oficial"**: promueve un material a estándar y lo elimina de sugerencias.
- Función **Regla Espejo**: rellenado automático de campos homólogos dependientes.
- Eliminación con modales de confirmación.

#### 🗺️ Mapa de Ingeniería (`engineering_map.dart`)
- Vista panorámica jerárquica de ensambles, folios y revisiones de ingeniería.
- Navegación a revisiones específicas mediante `targetRevisionId`.

#### 📡 Radar de Impacto (`impact_radar_screen.dart`)
- Módulo **Where-Used**: dado un código de pieza, muestra en qué proyectos, ensambles y VINs es utilizado.
- Permite evaluar el impacto antes de modificar o eliminar una pieza.

---

### ⚙️ Sección: Procesamiento de Datos

#### 🔷 Escáner CAD 3D/2D (`cad_scanner_screen.dart`)
- Dashboard para lanzar escaneos en lote de directorios completos.
- Soporta `.SLDPRT` (SolidWorks) y `.DWG/.DXF` (AutoCAD).
- Progreso asíncrono via **polling** al endpoint `/api/cad/background_status`.
- Resiliencia de estado con `AutomaticKeepAliveClientMixin`.
- Muestra resultados: archivos procesados, errores, propiedades extraídas (`Largo`, `Ancho`, `Espesor`, `Tiene_DXF`).

#### 📥 Importar Excel (`arbitration.dart` + `conflict_dialog.dart`)
- Motor de importación masiva de listas `.xlsx`.
- Compara el Excel subido contra los datos existentes en SQL Server.
- Detecta colisiones (`UPDATE`) y presenta un diálogo de arbitraje donde el usuario decide qué fuente prevalece (Excel vs. SQL).
- Widget modular `conflict_dialog.dart` para resolución de conflictos individuales.

#### 🔎 Auditor de Archivos (`auditor.dart`)
- Herramienta de auditoría: valida la coherencia entre archivos Excel de ingeniería y el estado de la base de datos SQL.
- Genera reportes de discrepancias encontradas.

#### 🔡 Estandarización (`standardization.dart`)
- Interfaz para limpieza y normalización de nombres de piezas y materiales.
- Corrige cadenas provenientes de OCR o importaciones manuales.
- Función de **estandarización masiva**: unifica múltiples registros hacia una nomenclatura estándar con un clic.
- ToggleSwitch para filtrar entre materiales estandarizados y pendientes.

---

### 🏭 Sección: Control de Producción

#### 🛒 Requerimientos MRP (`mrp_screen.dart`)
- Módulo de **Material Requirements Planning**.
- Calcula requerimientos de compra basados en BOMs activos.
- Soporte para chapas metálicas: cálculo de área en m² y pulgadas².
- Anidamiento universal para optimización de material.
- Exportación a Excel en dos hojas: **Órdenes de Compra** + **Auditoría de Ingeniería**.

#### 📁 Gestión de Proyectos (`project_management.dart`)
- Administración de macro-proyectos industriales.
- Seguimiento de estado, fechas y responsables.

#### 🚗 Expedientes VIN (`vin_dossier.dart`)
- Dossier completo por unidad (número VIN).
- Datos: tracto, tipo, versión, cliente, número de revisión, notas.
- Botón **"Ver Lista Asignada"**: navega directamente al BOM del VIN en el Mapa de Ingeniería.

#### 📊 Dashboard Analytics (`analytics_screen.dart`)
- Métricas globales del sistema con gráficas interactivas (`fl_chart`).
- Gráfica de barras: complejidad por ensamble.
- Gráfica de línea: evolución de revisiones.
- Gráfica de pastel: distribución por tipo de material.
- Vistas por proyecto, VIN y global.

#### ✅ Centro de QA (`qa_dashboard.dart`)
- Panel de control para el rol de **Aseguramiento de Calidad**.
- Inspección de VINs, validación de listas de materiales y checklist de aprobación.

---

### 📜 Historial de Cambios (`history.dart`)
- Log inmutable de **todas** las operaciones: estandarizaciones, cargas masivas, ediciones manuales, inserciones.
- Interfaz comparativa **Valor Anterior → Valor Nuevo**.
- Fuente: `Tbl_Historial_Cambios` (alimentada continuamente por la función `log_audit()` del backend).

---

### ⚙️ Configuración (`settings.dart`)
- Selector nativo de carpetas maestras (imágenes de planos, directorio CAD, etc.) via `file_picker`.
- Cambio de tema visual (ver sección Temas Visuales).
- Persistencia automática en `SharedPreferences`.

---

## 🐍 Backend API (FastAPI)

**Archivo principal:** `backend/server.py` (~186 KB)  
**Puerto:** `8001`  
**Base URL:** `http://192.168.1.73:8001`

### Endpoints Clave

| Método | Endpoint | Descripción |
|---|---|---|
| `GET` | `/api/health` | Health check: estado del server y conexión SQL |
| `GET` | `/api/catalogo` | Listado completo de `Tbl_Maestro_Piezas` |
| `PUT` | `/api/catalogo/{id}` | Editar pieza (dispara `log_audit`) |
| `DELETE` | `/api/catalogo/{id}` | Eliminar pieza con confirmación |
| `GET` | `/api/materiales` | Materiales oficiales aprobados |
| `POST` | `/api/materiales/oficial` | Promover material a oficial |
| `POST` | `/api/excel/procesar` | Importar `.xlsx` (multipart/form-data) |
| `POST` | `/api/cad/procesar-directorio` | Iniciar escaneo CAD (AutoCAD COM) |
| `POST` | `/api/cad/scan` | Iniciar escaneo SolidWorks COM (multihilo) |
| `GET` | `/api/cad/background_status` | Estado del escaneo CAD en curso |
| `GET` | `/api/historial` | Log de cambios de `Tbl_Historial_Cambios` |
| `GET` | `/api/vins` | Listado de expedientes VIN |
| `POST` | `/api/reportes/nuevo` | Reportar un bug/sugerencia (con captura base64) |
| `GET` | `/api/mrp/{id_proyecto}` | Datos MRP de un proyecto |
| `GET` | `/api/analytics/summary` | Métricas para el Dashboard Analytics |

### Función `log_audit()`
Registra de forma silenciosa en `Tbl_Historial_Cambios` cada operación `PUT` o `POST` relevante. Guarda: usuario, módulo, campo modificado, valor anterior y valor nuevo (serialización JSON segura para iterables).

---

## 🔷 Herramientas CAD

### `backend/tools/convertir_dwg.py`
- Convierte archivos `.DWG` a `.DXF` usando **AutoCAD COM** (`win32com.client`).
- Abre AutoCAD silenciosamente, sanitiza y exporta.
- Usa `CoInitialize` para compatibilidad COM multihilo.

### `backend/tools/preparar_solidworks.py`
- Script base para interacción con **SolidWorks COM**.
- La lógica completa reside en `server.py` como `bg_scan_cad_task` (multihilo resiliente).

### Macro VBA SolidWorks (DEFINITIVA — Marzo 2026)
Macro de inyección masiva de propiedades para archivos `.SLDPRT`. Se ejecuta directamente dentro del entorno de SolidWorks (Editor de Macros VBA).

**Flujo:** Selector visual de carpeta → Escaneo recursivo con filtro anti-duplicados (Dictionary + `DateLastModified`) → Inyección de propiedades custom.

**Propiedades que escribe:**

| Propiedad | Valor |
|---|---|
| `CODIGO_PIEZA` | Nombre base del archivo (sin extensión) |
| `Largo_CAD` | Dimensión mayor en mm (2 decimales) |
| `Ancho_CAD` | Dimensión media en mm (2 decimales) |
| `Espesor_Perfil_CAD` | Espesor en mm (con fallback multi-nivel) |

**Lógica de prioridad para Espesor:**
1. Propiedad custom `"Espesor"` del modelo
2. Propiedad custom `"Thickness"` del modelo
3. Feature `SheetMetal` → `GetDefinition().Thickness * 1000`
4. Feature `CutListFolder` → `"Longitud"` (solo si NO es chapa metálica)
5. Bounding Box → dimensión mínima `dz`

---

## 🗄️ Base de Datos (SQL Server)

**Host:** `192.168.1.73:1433`  
**Base de Datos:** `DB_Materiales_Industrial`  
**Autenticación:** Windows Trusted Connection (`Trusted_Connection=yes; TrustServerCertificate=yes`)

### Tablas Principales

| Tabla | Descripción |
|---|---|
| `Tbl_Maestro_Piezas` | Catálogo maestro de todas las piezas y sus metadatos CAD |
| `Tbl_Materiales_Aprobados` | Lista de materiales oficiales estandarizados |
| `Tbl_Historial_Cambios` | Audit trail inmutable de todas las operaciones |
| `Tbl_Conflictos_Temporales` | Buffer temporal durante importaciones Excel con colisiones |

### Convención de Directorios CAD
- `BIBLIOTECA_DXF`: Los archivos `.dxf` para análisis con `ezdxf` **deben** estar en una subcarpeta con exactamente este nombre dentro del directorio raíz escaneado.

---

## 🎨 Temas Visuales

El sistema soporta **7 temas** persistentes (guardados en `SharedPreferences`):

| Tema | Descripción |
|---|---|
| `dark` | Oscuro estándar (default) — `#202020` / Accent: Azul |
| `light` | Claro Windows 11 — `#F3F3F3` |
| `cyberpunk` | Negro extremo + Cyan `#00FFCC` + fuente Consolas |
| `apple` | Blanco soft + bordes redondeados (estilo macOS) |
| `platzi` | Azul marino + Verde `#98CA3F` (estilo educativo) |
| `azure` | Celeste hielo + Azul marino (corporativo) |
| `pastels` | Lavanda suave + Acentos rosa (pastel) |

---

## 🚀 Instrucciones de Ejecución

### Pre-requisitos
- Flutter SDK ≥ 3.7.2
- Python 3.10+
- ODBC Driver 17 for SQL Server
- SolidWorks y/o AutoCAD instalados (para pipeline CAD)

### 1. Preparar el entorno Python

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

### 2. Levantar el Backend

```bash
cd backend
python server.py
```
El servidor escucha en `0.0.0.0:8001`. Verificar estado en `http://127.0.0.1:8001/api/health`.

### 3. Lanzar la Aplicación Flutter

```bash
# Desde la raíz del proyecto
flutter pub get
flutter run -d windows
```

> **Nota:** Si hay cambios en dependencias, ejecutar `flutter clean` antes de `flutter pub get`.

### 4. Uso de Scripts Auxiliares

```bash
# Detener todos los procesos (antes de compilar o reiniciar)
MATAR_TODO.bat

# Prueba rápida de conectividad
PRUEBA_RAPIDA.bat
```

---

## 🏗️ Protocolo de Build Limpio (Release)

1. Ejecutar `MATAR_TODO.bat` para liberar puertos y archivos bloqueados.
2. Borrar carpetas `build/` antiguas.
3. Compilar: `flutter build windows`
4. Empaquetar con `ROBOCOPY` (no `Copy-Item`, por limitación de rutas largas >260 chars).
5. Incluir en el paquete final: `/build/windows/`, `/backend/`, `requirements.txt`, scripts `.bat`.

---

## 🌐 Infraestructura de Red

| Componente | Detalle |
|---|---|
| **IP del Servidor SQL** | `192.168.1.73` |
| **Puerto SQL** | `1433 (TCP)` |
| **Puerto API** | `8001` |
| **URL interna Flutter** | `http://192.168.1.73:8001` (explícita, no `localhost` — evita resolución IPv6) |
| **Firewall (Fortinet)** | Permitir TCP/1433 saliente hacia 192.168.1.73 + TCP/8001 in/out |

---

## 🐛 Sistema de Reporte de Bugs

La app incluye un **diálogo de reporte de bugs** integrado (botón en el footer de la sidebar):
- Seleccionar módulo afectado, nivel de gravedad (Crítico / Visual / Sugerencia).
- Adjuntar captura de pantalla (selector de archivo o **Ctrl+V** desde portapapeles).
- El reporte se envía a `POST /api/reportes/nuevo` y queda registrado en el servidor.

---

## ⚠️ Bitácora de Errores Críticos (Lecciones Aprendidas)

| Error | Causa | Solución |
|---|---|---|
| **Procesos Zombis** | `uvicorn` o `flutter` quedan corriendo tras cerrar, bloqueando puerto 8001 | Implementar `lifespan` en FastAPI. Ejecutar `MATAR_TODO.bat` antes de cada build. |
| **Fallo de Despliegue** | `Copy-Item` de PowerShell falla con rutas >260 chars | Usar **ROBOCOPY** en scripts `.bat` (nativo y robusto) |
| **Pérdida de selector nativo** | Uso de `TextField` para rutas en lugar de selector nativo | **Nunca** eliminar `file_picker`. Selección de carpetas siempre nativa del SO. |
| **Conexión SQL nula** | Bloqueo SSL/TLS en red interna | Cadena de conexión con `TrustServerCertificate=yes` + `Trusted_Connection=yes` |
| **SolidWorks COM Crash RPC** | Error `-2147023170` (`pywintypes.com_error`) en escaneos masivos | `try/except` por archivo, reset y re-inicialización de conexión COM al detectar el error |

---

## 📁 Estructura del Proyecto

```
industrial_manager_v15_5/
│
├── backend/                        # API REST (Python / FastAPI)
│   ├── server.py                   # Servidor principal (~186 KB)
│   ├── requirements.txt            # Dependencias Python
│   ├── data/
│   │   └── radar_tiempos.json      # Config. minutos simulación Radar (API engineering)
│   ├── routers/                    # Routers modulares (gestor_tareas, usuarios, engineering, …)
│   ├── sql/                        # Scripts de migración SQL Server (gestor / comando)
│   └── tools/
│       ├── convertir_dwg.py        # Conversor DWG → DXF (AutoCAD COM)
│       └── preparar_solidworks.py  # Base COM de SolidWorks
│
├── lib/                            # Frontend Flutter (Dart)
│   ├── main.dart                   # Entry point, NavigationView, sesión, bug reporter
│   ├── theme/
│   │   └── app_themes.dart         # 7 temas visuales + ThemeProvider
│   ├── screens/
│   │   ├── splash_screen.dart      # Pantalla de carga inicial
│   │   ├── login.dart              # Autenticación de usuarios
│   │   ├── lobby_screen.dart       # Bienvenida y accesos rápidos
│   │   ├── catalog.dart            # Catálogo Maestro CRUD
│   │   ├── materials_list.dart     # Materiales Oficiales
│   │   ├── engineering_map.dart    # Mapa de Ingeniería (folios/revisiones)
│   │   ├── impact_radar_screen.dart# Where-Used / Radar de Impacto
│   │   ├── monitoreo_tareas_screen.dart # Centro de Monitoreo / Comando Directivo
│   │   ├── configuracion_usuarios_screen.dart # Usuarios del comando
│   │   ├── monitoreo/              # Widgets del tablero de monitoreo
│   │   ├── cad_scanner_screen.dart # Escáner CAD masivo (SolidWorks + AutoCAD)
│   │   ├── arbitration.dart        # Motor de importación Excel con arbitraje
│   │   ├── auditor.dart            # Auditor de Archivos Excel/SQL
│   │   ├── standardization.dart    # Estandarización de nomenclaturas
│   │   ├── mrp_screen.dart         # MRP: Requerimientos de Material
│   │   ├── project_management.dart # Gestión de Proyectos
│   │   ├── vin_dossier.dart        # Expedientes por VIN
│   │   ├── analytics_screen.dart   # Dashboard de métricas (fl_chart)
│   │   ├── qa_dashboard.dart       # Centro de QA
│   │   ├── history.dart            # Historial de Cambios (Audit Trail)
│   │   ├── home_screen.dart        # Home screen auxiliar
│   │   ├── home.dart               # Componente raíz auxiliar
│   │   └── editor.dart             # Editor auxiliar
│   ├── widgets/
│   │   └── conflict_dialog.dart    # Diálogo de resolución de conflictos Excel vs SQL
│   ├── services/
│   │   └── notification_inbox_service.dart # Bandeja de notificaciones en cliente
│   └── utils/
│       └── excel_helper.dart       # Utilidades para manejo de Excel
│
├── windows/                        # Configuración nativa Windows (Flutter)
├── assets/                         # Assets estáticos
├── BLUEPRINT_INTEGRAL_v15.5.md     # Documento maestro de arquitectura
├── ATLAS_PROYECTO.md               # Mapa detallado del proyecto
├── DOCUMENTACION_CENTRO_MONITOREO.md
├── DOCUMENTACION_PRESENTACION_DIRECTIVA.md
├── RADAR_IMPACTO_ANALISIS_Y_PROPUESTAS.md
├── RESUMEN_IA_CENTRO_MONITOREO_Y_RADAR.md
├── MATAR_TODO.bat                  # Script: terminar todos los procesos
├── PRUEBA_RAPIDA.bat               # Script: prueba de conectividad rápida
├── pubspec.yaml                    # Dependencias Flutter
└── README.md                       # Este archivo
```

---

*Industrial Master v60.0 — Sistema de Gestión Industrial*  
*Desarrollado para uso interno en planta de manufactura.*
