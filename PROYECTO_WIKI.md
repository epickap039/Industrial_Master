# Industrial Master — Wiki de proyecto (auditoría completa)

Documento generado a partir del código en `lib/`, `lib/screens/`, `lib/widgets/` y `backend/server.py`.  
**API base recomendada:** `lib/config/app_config.dart` → `kApiBaseUrl` (varias pantallas aún usan IP fija; ver §7).

---

## 1. Rutas Flutter (`lib/main.dart`)

| Ruta | Widget | Función |
|------|--------|---------|
| `/` | `SplashScreen` | Espera breve y redirige a `/login` o `/main` según sesión (7 días). |
| `/login` | `LoginScreen` | Autenticación contra backend; guarda rol y usuario en `SharedPreferences`. |
| `/main` | `NavigationView` | Shell principal con `NavigationPane` (rol **QA** = solo catálogo; resto = menú completo). |

**Footer del pane (no son pestañas de cuerpo principal):** selector de tema (`AppThemeMode`), **Reportar Bug** (`_showBugDialog` → `POST /api/reportes/nuevo`), **Configuración** (`SettingsScreen`).

---

## 2. Índice de pestañas del `NavigationPane` (rol ≠ QA)

Orden **plano** según la lista `items` en `main.dart` (comportamiento típico de `fluent_ui`: `PaneItem` raíz + hijos de cada `PaneItemExpander` en orden).

| Índice | Título en UI | Archivo | Qué hace |
|--------|----------------|---------|----------|
| **0** | Lobby Principal | `lib/screens/lobby_screen.dart` | KPIs (`GET /api/dashboard/kpi`), accesos rápidos (`onNavigate`). |
| **1** | *(cabecera)* Consultas Rápidas | — | Expander; cuerpo `SizedBox.shrink()`. |
| **2** | Catálogo Maestro | `lib/screens/catalog.dart` | `GET /api/catalog`, `PUT /api/material/update`, `DELETE /api/catalog/{codigo}` → **`Tbl_Maestro_Piezas`**; exportes, DXF, planos. |
| **3** | Materiales Oficiales | `lib/screens/materials_list.dart` | Lista `GET /api/config/materiales`; alta/baja de materiales aprobados (**URL hardcodeada en archivo**). |
| **4** | Mapa de Ingeniería | `lib/screens/engineering_map.dart` | Árbol `GET /api/mapa/jerarquia`; abre `BOMManagerScreen` con `Navigator.push`. Si `targetRevisionId` viene de VIN, auto-navega a la revisión. |
| **5** | Radar de Impacto | `lib/screens/impact_radar_screen.dart` | Where-used `GET /api/bom/where-used/{codigo}`; checklists locales de impacto. |
| **6** | *(cabecera)* Procesamiento de Datos | — | Expander. |
| **7** | Escáner CAD 3D/2D | `lib/screens/cad_scanner_screen.dart` | Macro VBA, `POST /api/cad/*` (scan, upload, status, download, abort, procesar-directorio). |
| **8** | Importar Excel | `lib/screens/arbitration.dart` | Motor Excel/arbitraje: `ConflictResolutionDialog` (`lib/widgets/conflict_dialog.dart`), sincronización y conflictos vía `/api/excel/*`. |
| **9** | Auditor de Archivos | `lib/screens/auditor.dart` | Sube Excel; auditoría/corrección `/api/excel/auditar`, `/api/excel/corregir`, enlaces, etc. |
| **10** | Estandarización | `lib/screens/standardization.dart` | Descripciones `GET /api/limpieza/descripciones_unicas`, masivo `POST /api/limpieza/actualizar_masivo`, materiales (**URL hardcodeada**). |
| **11** | *(cabecera)* Control de Producción | — | Expander. |
| **12** | Requerimientos (MRP) | `lib/screens/mrp_screen.dart` | Revisiones `GET /api/mrp/revisiones`, cálculo `GET /api/mrp/calculate/{id}`; pestañas materia prima / comerciales / huérfanos; export Excel. |
| **13** | Gestión de Proyectos | `lib/screens/project_management.dart` | CRUD tractos/tipos/versiones/clientes `/api/proyectos/*`; abre `BOMManagerScreen` con `Navigator.push`. |
| **14** | Expedientes VIN | `lib/screens/vin_dossier.dart` | Búsqueda `GET /api/vins/buscar`, ADN, notas, archivos, vincular socios; `onNavigateToBOM` → `_handleNavigation(4, id: idRevision)` (Mapa de Ingeniería). |
| **15** | Dashboard Analytics | `lib/screens/analytics_screen.dart` | Datos `GET /api/analytics/dashboard/{id_revision\|global}`; exclusión de revisiones en modo global. |
| **16** | Centro de QA | `lib/screens/qa_dashboard.dart` | Reportes `GET /api/reportes`, export, resolver; usa `API_URL` de `main.dart`. |
| **17** | Historial de Cambios | `lib/screens/history.dart` | `GET /api/historial`; export/descarga según implementación en pantalla. |

### Rol **QA**

Un solo ítem: índice **0** = **Catálogo Maestro** (`CatalogScreen`).

---

## 3. Pantallas y archivos fuera del pane (o legado)

| Archivo | Clase principal | Enlace en la app actual |
|---------|-----------------|-------------------------|
| `lib/screens/bom_manager.dart` | `BOMManagerScreen` | Solo por **`Navigator.push`** desde Mapa de Ingeniería, Gestión de Proyectos o contextos VIN/BOM. |
| `lib/widgets/conflict_dialog.dart` | `ConflictResolutionDialog` | Diálogo de comparación Excel vs SQL en **Importar Excel**. |
| `lib/screens/editor.dart` | `EditorScreen` | **No** referenciado en `NavigationPane`; import en `main.dart` sin uso en rutas actuales (placeholder CRUD). |
| `lib/screens/home.dart` | `HomeScreen` (Stateless) | **No** usado en `main.dart` actual. |
| `lib/screens/home_screen.dart` | `HomeScreen` (Stateful) | **No** usado en `main.dart` actual (lobby antiguo con `onNavigate`). |

---

## 4. Flujos de usuario (A → B)

### 4.1 Autenticación

**Splash** → (sesión válida) **Main** / (no) **Login** → **Login** exitoso → **Main** (`pushReplacementNamed`).

### 4.2 Lobby

**Lobby** → tarjetas KPI / módulos llaman `onNavigate(n)` (índices **2, 7–9, 12–16**, etc.) sin `Navigator`; el `NavigationPane` cambia de pestaña.

### 4.3 Ingeniería / PLM

- **Mapa de Ingeniería** → icono abrir revisión → **`BOMManagerScreen`** → (volver con `true`) refresco `GET /api/mapa/jerarquia`.
- **Gestión de Proyectos** → selección tracto/tipo/versión/cliente → abrir BOM → **`BOMManagerScreen`**.
- **VIN** → “ir a BOM” → cambia a índice **4** (Mapa) + `targetRevisionId`; el mapa auto-abre BOM si encuentra la revisión en el árbol.

### 4.4 Catálogo e inventario de datos

- **Catálogo Maestro**: listado/edición/borrado vía `/api/catalog` y `/api/material/update` sobre **`Tbl_Maestro_Piezas`**.
- **Materiales oficiales** y **Estandarización**: listas y reglas de limpieza enlazadas a **`Tbl_Maestro_Piezas`** / **`Tbl_Materiales_Aprobados`** según endpoint (ver §6).

### 4.5 Producción / MRP / Analytics

- **MRP**: elige revisión → cálculo de requerimientos por API MRP.
- **Analytics**: elige revisión o **global** → gráficos y KPIs de dashboard.

### 4.6 CAD y Excel

- **Escáner CAD**: flujo de carpeta → backend CAD asíncrono (estado en `/api/cad/status`).
- **Importar Excel / Auditor**: ficheros locales → `/api/excel/*` (procesar, sincronizar, auditar, corregir, exportar).

### 4.7 QA y auditoría global

- **Reportar Bug** (footer) → diálogo → `POST /api/reportes/nuevo`.
- **Centro de QA** → listado abierto → detalle con captura Base64 → resolver `PUT /api/reportes/{id}/resolver`.
- **Historial** → `GET /api/historial` (`Tbl_Auditoria_Cambios`).

### 4.8 Configuración

- **Configuración** (footer) → `SettingsScreen`: prueba de conexión, sincronización según botones del archivo, rol QA visible.

---

## 5. KPI del Lobby (`GET /api/dashboard/kpi`)

Los indicadores **no mezclan** el tamaño del maestro de piezas con el volumen de filas en listas BOM:

| Campo JSON | Significado | Origen SQL |
|------------|-------------|------------|
| **`total_piezas`** | Registros del **catálogo maestro** (p. ej. ~1 595) | `SELECT COUNT(*) FROM Tbl_Maestro_Piezas` |
| **`total_lineas_bom`** | **Filas** en listas de materiales (incluye posibles fantasmas si no se ha purgado) | `SELECT COUNT(*) FROM Tbl_BOM_Estructura` → **0** tras `backend/sql/purga_fantasmas.sql` |
| **`salud_cad`** | % CAD sobre líneas BOM **enlazadas** a maestro (join completo) | CTE `PiezasBase` (estructura→ensamble→estación→`Tbl_Maestro_Piezas`). Sin filas BOM → `0%`. |
| **`total_unidades`** | VINs | `Tbl_Unidades_Fisicas` |
| **`total_versiones`** | Versiones de ingeniería | `Tbl_Versiones_Ingenieria` |
| **`merma_configurada`** | Fijo | `15` |

**Pantalla Catálogo (`GET /api/catalog`):** lee y escribe **`Tbl_Maestro_Piezas`** (misma fuente que `total_piezas` del Lobby).

**Purga de fantasmas BOM:** `backend/sql/purga_fantasmas.sql` — vacía ingeniería transaccional **sin** tocar **`Tbl_Maestro_Piezas`**.

---

## 6. Mapa de base de datos (`Tbl_*` referenciadas en `server.py`)

### 6.0 Catálogo maestro vs listas BOM

| Tabla | Rol |
|-------|-----|
| **`Tbl_Maestro_Piezas`** | **Única tabla oficial del catálogo** — grilla Catálogo (`GET/DELETE /api/catalog`, `PUT /api/material/update`), **KPI Lobby `total_piezas`** = `SELECT COUNT(*) FROM Tbl_Maestro_Piezas`, joins BOM/MRP/analytics/Excel. **No se borra** con purga de ingeniería. |
| **`Tbl_BOM_Estructura`** | **Listas BOM transaccionales** — **KPI `total_lineas_bom`** (`COUNT(*)`); se vacía con `backend/sql/purga_fantasmas.sql`. |

El Lobby muestra **dos números**: piezas en maestro (~1 595) y filas en estructura BOM (0 si no hay listas).

Lista **única** de tablas detectadas en el backend (puede haber más en SQL fuera del repo):

| Tabla | Rol resumido |
|-------|----------------|
| **Tbl_Auditoria_Cambios** | Log transversal (pieza/código, acción, valores, usuario, fecha). |
| **Tbl_BOM_Estructura** | Líneas de BOM por ensamble (código, cantidad, observaciones). |
| **Tbl_BOM_Revisiones** | Revisiones por versión (número, estado: Borrador, PENDIENTE, Aprobada, OBSOLETO). |
| **Tbl_Clientes_Configuracion** | Clientes asignados a una versión de ingeniería. |
| **Tbl_Ensambles** | Ensambles bajo estación. |
| **Tbl_Estaciones** | Estaciones de línea bajo una revisión. |
| **Tbl_Log_Cambios_Ingenieria** | Log por `ID_Revision` (acciones BOM/ECR); best-effort insert. |
| **Tbl_Maestro_Piezas** | Catálogo maestro + metadatos CAD; ver §6.0. |
| **Tbl_Materiales_Aprobados** | Materiales oficiales. |
| **Tbl_Proyectos_Tracto** | Tractos / proyectos raíz. |
| **Tbl_Reportes_Beta** | Bugs/QA (incl. `Captura_Base64`). |
| **Tbl_Tipos_Proyecto** | Tipos bajo tracto. |
| **Tbl_Unidades_Fisicas** | VINs / unidades; notas, socios, archivos en disco aparte. |
| **Tbl_Usuarios** | Login (creación condicional en arranque de endpoint login). |
| **Tbl_Versiones_Ingenieria** | Versiones (V1, V2…) bajo tipo. |

**Relación conceptual:**  
`Tracto` → `Tipo` → `Versión` → (`Clientes`) + `Revisiones` → `Estaciones` → `Ensambles` → `BOM_Estructura` (piezas ↔ **`Tbl_Maestro_Piezas`** por código para metadatos CAD en ingeniería).  
**Catálogo de pantalla y KPI `total_piezas`** = **`Tbl_Maestro_Piezas`**.

El motor **Excel** (`/api/excel/*`) y sincronizaciones masivas actualizan **`Tbl_Maestro_Piezas`** (coherente con el catálogo UI).

---

## 7. Endpoints HTTP (`backend/server.py`) — inventario

> Nota: hay rutas duplicadas en Python (p. ej. `GET/POST /api/bom/estaciones/{id_revision}`); FastAPI conserva la **última** definición en el archivo.

### Raíz y sistema

| Método | Ruta |
|--------|------|
| GET | `/` |
| GET | `/api/health` |
| POST | `/api/system/open_file` |

### KPI y configuración

| Método | Ruta |
|--------|------|
| GET | `/api/dashboard/kpi` |
| GET/POST | `/api/config/materiales` |
| DELETE | `/api/config/materiales/{material_name}` |
| POST/DELETE | `/api/materiales/oficial`, `/api/materiales/oficial/{identificador}` |
| GET/POST | `/api/config/regla_espejo` |
| POST | `/api/config/update_links` |

### Proyectos / jerarquía

| Método | Ruta |
|--------|------|
| GET/POST/DELETE | `/api/proyectos/tractos`, `/api/proyectos/tractos/{id_tracto}` |
| GET/POST/DELETE | `/api/proyectos/tipos/{id_tracto}`, `/api/proyectos/tipos`, `/api/proyectos/tipos/{id_tipo}` |
| GET/POST/DELETE | `/api/proyectos/versiones/{id_tipo}`, `/api/proyectos/versiones`, `/api/proyectos/versiones/{id_version}` |
| GET/POST/DELETE | `/api/proyectos/clientes/{id_version}`, `/api/proyectos/clientes`, `/api/proyectos/clientes/{id_cliente}` |
| PUT | `/api/proyectos/clientes/{id_cliente}/asignar_revision` |
| GET | `/api/mapa/jerarquia` |

### MRP y analytics

| Método | Ruta |
|--------|------|
| GET | `/api/mrp/revisiones` |
| GET | `/api/mrp/calculate/{id_revision}` |
| GET | `/api/analytics/dashboard/{id_revision}` |

**Respuesta Analytics (campos añadidos, sin romper los existentes):**  
`total_lineas_bom_estructura` → `COUNT(*)` sobre **`Tbl_BOM_Estructura`** (volumen físico de la tabla).  
`total_registros_maestro_piezas` → `COUNT(*)` sobre **`Tbl_Maestro_Piezas`**.  
Las gráficas siguen usando joins BOM+maestro con el alcance de revisión / global ya definido.

### Catálogo y materiales

| Método | Ruta |
|--------|------|
| GET/DELETE | `/api/catalog`, `/api/catalog/{codigo}` |
| GET | `/api/dxf/search/{codigo}` |
| PUT | `/api/material/update` |

### VINs y archivos

| Método | Ruta |
|--------|------|
| GET | `/api/vins/buscar` |
| GET/PUT/DELETE | `/api/vins/{id_unidad}/adn`, notas, notas_reemplazar, `DELETE /api/vins/{serie}` |
| POST | `/api/vins/{id_unidad}/vincular/{id_socio}` |
| GET/POST/DELETE | `/api/vins/{id_vin}/archivos`, subir, borrar por nombre |

### BOM / revisiones / estructura

(Incluye duplicados literales en el archivo; listar como contrato funcional.)

| Método | Ruta (patrón) |
|--------|----------------|
| GET | `/api/bom/where-used/{codigo_pieza}` |
| GET/POST/DELETE | `/api/bom/estaciones/...`, `/api/bom/ensambles/...`, `/api/bom/estructura/...` |
| GET/POST | `/api/bom/revisiones/version/{id_version}`, `/api/bom/revisiones/{id_cliente}` |
| PUT/DELETE | `/api/bom/revisiones/{id_revision}/aprobar`, `DELETE .../{id_revision}` |
| GET/POST/DELETE | VINs ligados a revisión, exportar, log, importar, árbol, plana, delta |
| POST | `/api/bom/clonar`, `/api/bom/clonar/{id_revision_origen}`, `/api/bom/branching` |
| POST | `/api/bom/buscar_planos`, `/api/bom/propagar` |
| GET | `/api/bom/{id_revision}/calcular_placas` |
| PUT | `/api/bom/estructura/cantidad/{id_bom}`, `/api/bom/piezas/{id_bom}` |

### Excel

| Método | Ruta |
|--------|------|
| POST | `/api/excel/procesar`, `sincronizar`, `actualizar_enlaces`, `auditar`, `corregir`, `exportar_reporte` |

### Historial, limpieza, reportes, login, CAD

| Método | Ruta |
|--------|------|
| GET | `/api/historial` |
| GET/POST | `/api/limpieza/descripciones_unicas`, `/api/limpieza/actualizar_masivo` |
| POST/GET/PUT | `/api/reportes/nuevo`, `/api/reportes`, `/api/reportes/exportar`, `/api/reportes/exportar_gemini`, `/api/reportes/{id}/resolver` |
| POST | `/api/login` |
| POST/GET | `/api/cad/abort`, `scan`, `procesar-directorio`, `status`, `download`, `upload` |

### 7.1 Lista plana de decoradores `@app` en `server.py` (orden de aparición)

```
GET    /
GET    /api/health
GET    /api/dashboard/kpi
GET    /api/config/materiales
POST   /api/config/materiales
DELETE /api/config/materiales/{material_name}
POST   /api/materiales/oficial
DELETE /api/materiales/oficial/{identificador}
GET    /api/proyectos/tractos
POST   /api/proyectos/tractos
DELETE /api/proyectos/tractos/{id_tracto}
GET    /api/proyectos/tipos/{id_tracto}
POST   /api/proyectos/tipos
DELETE /api/proyectos/tipos/{id_tipo}
GET    /api/proyectos/versiones/{id_tipo}
POST   /api/proyectos/versiones
DELETE /api/proyectos/versiones/{id_version}
GET    /api/proyectos/clientes/{id_version}
POST   /api/proyectos/clientes
DELETE /api/proyectos/clientes/{id_cliente}
GET    /api/mapa/jerarquia
GET    /api/bom/where-used/{codigo_pieza}
GET    /api/mrp/revisiones
GET    /api/mrp/calculate/{id_revision}
GET    /api/analytics/dashboard/{id_revision}
GET    /api/vins/{id_vin}/archivos
POST   /api/vins/{id_vin}/subir_archivo
GET    /api/vins/{id_vin}/archivos/{nombre_archivo}
GET    /api/bom/estaciones/{id_revision}
POST   /api/bom/estaciones
GET    /api/bom/revisiones/version/{id_version}
POST   /api/bom/revisiones/version/{id_version}
GET    /api/bom/revisiones/{id_cliente}
POST   /api/bom/revisiones/{id_cliente}
PUT    /api/bom/revisiones/{id_revision}/aprobar
DELETE /api/bom/revisiones/{id_revision}
GET    /api/bom/revisiones/{id_revision}/vins
GET    /api/bom/buscar_pieza_jerarquia/{codigo_pieza}
GET    /api/bom/exportar/{id_revision}
GET    /api/bom/log/{id_revision}
PUT    /api/proyectos/clientes/{id_cliente}/asignar_revision
POST   /api/bom/revisiones/{id_revision}/vins
DELETE /api/bom/vins/{id_unidad}
GET    /api/vins/buscar
GET    /api/vins/{id_unidad}/adn
POST   /api/vins/{id_unidad}/vincular/{id_socio}
PUT    /api/vins/{id_unidad}/notas
PUT    /api/vins/{id_unidad}/notas_reemplazar
DELETE /api/vins/{id_vin}/archivos/{nombre_archivo}
DELETE /api/vins/{serie}
POST   /api/bom/clonar
POST   /api/bom/clonar/{id_revision_origen}
POST   /api/bom/branching
POST   /api/bom/buscar_planos
POST   /api/bom/propagar
GET    /api/bom/estaciones/{id_revision}   ← segunda definición en archivo
POST   /api/bom/estaciones                 ← segunda definición
DELETE /api/bom/estaciones/{id_estacion}
GET    /api/bom/ensambles/{id_estacion}
POST   /api/bom/ensambles
GET    /api/bom/{id_revision}/calcular_placas
DELETE /api/bom/ensambles/{id_ensamble}
GET    /api/bom/estructura/{id_ensamble}
POST   /api/bom/estructura
DELETE /api/bom/estructura/{id_bom}
PUT    /api/bom/estructura/cantidad/{id_bom}
PUT    /api/bom/piezas/{id_bom}
GET    /api/bom/arbol/{id_revision}
GET    /api/bom/plana/{id_revision}
GET    /api/bom/delta/{id_revision}
POST   /api/bom/importar/{id_revision}
GET    /api/config/regla_espejo
POST   /api/config/regla_espejo
POST   /api/login
GET    /api/catalog
DELETE /api/catalog/{codigo}
GET    /api/dxf/search/{codigo}
PUT    /api/material/update
POST   /api/excel/procesar
POST   /api/excel/sincronizar
POST   /api/config/update_links
POST   /api/excel/actualizar_enlaces
POST   /api/excel/auditar
POST   /api/excel/corregir
POST   /api/system/open_file
POST   /api/excel/exportar_reporte
GET    /api/historial
GET    /api/limpieza/descripciones_unicas
POST   /api/limpieza/actualizar_masivo
POST   /api/reportes/nuevo
GET    /api/reportes/exportar_gemini
GET    /api/reportes
GET    /api/reportes/exportar
PUT    /api/reportes/{id_reporte}/resolver
POST   /api/cad/abort
POST   /api/cad/scan
POST   /api/cad/procesar-directorio
GET    /api/cad/status
GET    /api/cad/download
POST   /api/cad/upload
```

---

## 8. Deuda técnica detectada en el cliente

- **`lib/screens/standardization.dart`**: `API_URL = "http://192.168.1.73:8001"` — debería usar `kApiBaseUrl`.
- **`lib/screens/materials_list.dart`**: misma IP fija en `GET` de materiales.
- **`lib/screens/login.dart`**: health check a IP fija; el resto de la app usa `kApiBaseUrl` en muchos módulos.

### Base de datos (alineación Catálogo vs Maestro)

- Mantener **`Tbl_Maestro_Piezas`** como fuente única del catálogo (~1 595 piezas corregidas).

---

## 9. Verificación rápida post-cambio KPI

1. Purga BOM fantasma (si aplica): `backend/sql/purga_fantasmas.sql` → `SELECT COUNT(*) FROM Tbl_BOM_Estructura` = **0**.
2. API: `GET /api/dashboard/kpi` → `total_piezas` = `COUNT(*)` en **`Tbl_Maestro_Piezas`**; `total_lineas_bom` = **`Tbl_BOM_Estructura`**.
3. `GET /api/catalog` devuelve filas de **`Tbl_Maestro_Piezas`** (sin error 208 por tabla inexistente).
4. Lobby: tarjetas alineadas con maestro vs BOM.

---

*Documento alineado con el código en el repositorio; ante migraciones de BD no reflejadas aquí, contrastar con SQL Server.*
