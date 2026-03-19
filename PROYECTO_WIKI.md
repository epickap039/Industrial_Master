# Industrial Master — Proyecto Wiki (v60)

Documentación estructural del sistema: Flutter (cliente), FastAPI (`backend/server.py`) y SQL Server.

---

## Capítulo 1 — Arquitectura y navegación

### 1.1 Flujo general

- **Cliente:** Flutter + `fluent_ui`, punto de entrada `lib/main.dart`.
- **API:** FastAPI en `backend/server.py` (puerto típico **8001** según `uvicorn` al final del archivo).
- **Configuración de URL:** `lib/config/app_config.dart` (`kApiBaseUrl`).

### 1.2 Roles y paneles

| Rol | Comportamiento |
|-----|----------------|
| **QA** | Solo ve **Catálogo Maestro** (`CatalogScreen`). |
| **ADMIN / USER** | Navegación completa: Lobby, consultas, procesamiento, control de producción, historial. |

### 1.3 Índices del `NavigationPane` (usuario no-QA)

El `NavigationPane` de `fluent_ui` asigna un **índice plano** a cada `PaneItem` en el orden en que aparecen en `main.dart` (incluidos los hijos de los `PaneItemExpander`).

| Índice | Ubicación en menú | Archivo Dart | Función resumida |
|--------|-------------------|--------------|------------------|
| **0** | Lobby Principal | `lib/screens/lobby_screen.dart` | Dashboard, KPIs, accesos rápidos. |
| **2** | Consultas → Catálogo Maestro | `lib/screens/catalog.dart` | Piezas/catálogo maestro, enlaces CAD. |
| **3** | Consultas → Materiales Oficiales | `lib/screens/materials_list.dart` | Lista de materiales aprobados. |
| **4** | Consultas → Mapa de Ingeniería | `lib/screens/engineering_map.dart` | Árbol tracto → tipo → versión → revisiones; abre `BomManagerScreen`. |
| **5** | Consultas → Radar de Impacto | `lib/screens/impact_radar_screen.dart` | Where-used / impacto de piezas. |
| **7** | Procesamiento → Escáner CAD | `lib/screens/cad_scanner_screen.dart` | Escaneo de metadatos CAD. |
| **8** | Procesamiento → Importar Excel | `lib/screens/arbitration.dart` | Carga/arbitraje Excel (`ArbitrationScreen`). |
| **9** | Procesamiento → Auditor | `lib/screens/auditor.dart` | Integridad de archivos enlazados. |
| **10** | Procesamiento → Estandarización | `lib/screens/standardization.dart` | Normalización masiva de datos. |
| **12** | Control → MRP | `lib/screens/mrp_screen.dart` | Requerimientos de materiales. |
| **13** | Control → Gestión de Proyectos | `lib/screens/project_management.dart` | Tractos, tipos, versiones, clientes; enlaza con BOM. |
| **14** | Control → Expedientes VIN | `lib/screens/vin_dossier.dart` | Unidades físicas; puede navegar al mapa BOM (índice **4**). |
| **15** | Control → Dashboard Analytics | `lib/screens/analytics_screen.dart` | Métricas y salud CAD por revisión/global. |
| **16** | Control → Centro de QA | `lib/screens/qa_dashboard.dart` | Reportes beta, capturas, resolución. |
| **17** | Historial de Cambios | `lib/screens/history.dart` | Vista de auditoría vía API historial. |

**Pantallas auxiliares (no son ítems del pane principal):**

- `lib/screens/bom_manager.dart` — Editor BOM (estaciones, ensambles, estructura); se abre con `Navigator.push` desde mapa de ingeniería, proyectos o VIN según flujo.
- `lib/screens/login.dart`, `lib/screens/splash_screen.dart` — Autenticación y arranque.
- `lib/screens/settings.dart` — **Footer** del `NavigationPane` (Configuración).
- `lib/screens/editor.dart`, `lib/screens/home.dart`, `lib/screens/home_screen.dart` — **Legado / no enlazados** al pane actual; `editor.dart` puede quedar importado en `main.dart` sin uso en el árbol visible.

### 1.4 Footer del pane (documentado — no son “huérfanos”)

- **Selector de tema** (`AppThemeMode`): cambia apariencia global.
- **Reportar Bug** (`_showBugDialog` en `main.dart`): diálogo con captura; POST a `/api/reportes/nuevo`.
- **Configuración** → `SettingsScreen` (`lib/screens/settings.dart`).

### 1.5 Lobby y KPIs

- **Archivo:** `lib/screens/lobby_screen.dart`.
- **Endpoint:** `GET /api/dashboard/kpi`.
- **Campos usados:** `total_piezas`, `total_unidades`, `total_versiones`, `salud_cad`, `merma_configurada`.

Las tarjetas del Lobby llaman a `onNavigate(n)` con los índices **2, 12, 13, 14, 15** y la cuadrícula inferior usa **7, 8, 9, 13, 14, 16**, coherentes con la tabla anterior.

---

## Capítulo 2 — Lógica de ingeniería (corazón del PLM)

### 2.1 Jerarquía de datos

1. **Tracto** (`Tbl_Proyectos_Tracto`) — Proyecto / línea de producto.
2. **Tipo** (`Tbl_Tipos_Proyecto`) — Variante bajo un tracto.
3. **Versión de ingeniería** (`Tbl_Versiones_Ingenieria`) — Línea de diseño (p. ej. **V1, V2, V3…** tras branching específico).
4. **Cliente(s)** (`Tbl_Clientes_Configuracion`) — Asignados a una **versión** (`ID_Version`).
5. **Revisión BOM** (`Tbl_BOM_Revisiones`) — Snapshots numerados (**0, 1, 2…**) bajo una misma versión; estados típicos: Borrador, PENDIENTE, Aprobada, OBSOLETO.
6. **Estaciones → Ensambles → Estructura** — `Tbl_Estaciones` → `Tbl_Ensambles` → `Tbl_BOM_Estructura` (líneas de BOM por ensamble).

### 2.2 Versiones (V1, V2…) y revisiones

- Una **versión** es una fila en `Tbl_Versiones_Ingenieria` (pertenece a un tipo).
- Cada versión puede tener **N revisiones** en `Tbl_BOM_Revisiones` (`Numero_Revision` incremental en la misma `ID_Version`).
- La **ingeniería editable** suele ser la revisión en curso (Borrador / PENDIENTE); al **aprobar**, las anteriores pueden pasar a OBSOLETO según reglas del endpoint de aprobación.

### 2.3 Branching ECR (`POST /api/bom/branching`)

Implementación en `branching_ecr` (`server.py`):

| `tipo_cambio` | Efecto |
|---------------|--------|
| **GLOBAL** | Nueva **revisión** en la **misma** `ID_Version` (Rev N+1), clonando estaciones/ensambles/estructura desde la revisión origen. Estado inicial **Borrador**. |
| **ESPECIFICO** | Nueva **versión** en el mismo tipo (nomenclatura **V{n}** según versiones existentes del tipo), **opcionalmente** mueve clientes (`Tbl_Clientes_Configuracion.ID_Version`), crea **Revisión 0** en la nueva versión, clona la BOM desde la revisión origen. Log `DERIVACION` en ingeniería. |

Tras clonar, se registra acción **ECR_BRANCHING** vía `registrar_log`.

### 2.4 Borrado físico en cascada (confirmación)

Funciones clave en `server.py`:

1. **`_physical_delete_revision_cascade(cursor, id_revision)`**  
   Elimina en orden: log de ingeniería (si existe), **estructura BOM**, **ensambles**, **estaciones**, **unidades físicas** ligadas a la revisión, fila en **`Tbl_BOM_Revisiones`**.

2. **`_purge_version_physical(cursor, id_version)`**  
   Para cada revisión de la versión llama a `_physical_delete_revision_cascade`, luego **`Tbl_Clientes_Configuracion`** de esa versión y **`Tbl_Versiones_Ingenieria`**.

3. **`_purge_tipo_physical(cursor, id_tipo)`**  
   Purga todas las versiones del tipo y borra **`Tbl_Tipos_Proyecto`**.

4. **API** `DELETE /api/bom/revisiones/{id_revision}` — Tras reglas de contraseña para estados no editables, ejecuta `_physical_delete_revision_cascade` y deja rastro en **`Tbl_Auditoria_Cambios`** antes del borrado.

5. **Script operativo:** `scripts/purge_ingenieria_fisico.py` — Purga completa de ingeniería llamando a `_purge_tipo_physical` por cada tipo; **no** borra tractos ni catálogo maestro de piezas.

**Orden conceptual:** tipos (vía purga) → versiones → revisiones → estaciones/ensambles → estructura (y VINs asociados a revisiones).

---

## Capítulo 3 — API y base de datos

### 3.1 Catálogo vs BOM

| Tabla / concepto | Rol |
|------------------|-----|
| **`Tbl_Catalogo_Maestro` / API catálogo** | Registro de **piezas únicas** (códigos, descripciones, metadatos de negocio) tal como las expone el módulo de catálogo (`/api/catalog`, etc.). |
| **`Tbl_Maestro_Piezas`** | Maestro técnico de piezas (materiales, dimensiones CAD, etc.), muy usado en joins de BOM y analytics. |
| **`Tbl_BOM_Estructura`** | **Uso** de una pieza dentro de un **ensamble** concreto: `Codigo_Pieza`, `Cantidad`, `ID_Ensamble`. Una misma pieza del maestro puede aparecer en muchas filas (muchas listas / muchos ensambles). |

En resumen: **maestro = qué es la pieza**; **estructura = dónde y cuánto se usa en una lista BOM**.

### 3.2 Mapeo resumido endpoint → tablas

(Selección representativa; el archivo completo define muchos más.)

| Área | Endpoint(s) | Tablas principales |
|------|-------------|-------------------|
| Health | `GET /api/health` | Conexión BD |
| **KPI Lobby** | `GET /api/dashboard/kpi` | `Tbl_Maestro_Piezas`, `Tbl_BOM_Estructura`, `Tbl_Ensambles`, `Tbl_Estaciones`, `Tbl_Unidades_Fisicas`, **`Tbl_Versiones_Ingenieria`** (`total_versiones` = `COUNT(*)`) |
| Proyectos | `/api/proyectos/tractos`, `tipos`, `versiones`, `clientes` | `Tbl_Proyectos_Tracto`, `Tbl_Tipos_Proyecto`, `Tbl_Versiones_Ingenieria`, `Tbl_Clientes_Configuracion` |
| Mapa | `GET /api/mapa/jerarquia` | Jerarquía tracto → tipo → versión |
| MRP | `/api/mrp/*` | Revisiones, estructura, maestro |
| Analytics | `GET /api/analytics/dashboard/{id_revision}` | Agregaciones sobre estructura + maestro; `total_versiones` alineado con **`Tbl_Versiones_Ingenieria`** |
| BOM | `/api/bom/*` (estaciones, ensambles, estructura, árbol, import/export, aprobar, eliminar) | `Tbl_BOM_Revisiones`, `Tbl_Estaciones`, `Tbl_Ensambles`, `Tbl_BOM_Estructura` |
| Clonación / ECR | `POST /api/bom/clonar*`, `POST /api/bom/branching` | Mismas tablas BOM + versiones/clientes |
| VINs | `/api/vins/*`, adjuntos en disco | `Tbl_Unidades_Fisicas`, carpetas bajo `VIN_FILES_BASE` |
| Catálogo | `/api/catalog`, DXF, materiales | `Tbl_Catalogo_Maestro`, `Tbl_Maestro_Piezas`, `Tbl_Materiales_Aprobados` |
| Excel / CAD | `/api/excel/*`, `/api/cad/*` | Varía (maestro, archivos, procesos) |
| **Historial UI** | `GET /api/historial` | **`Tbl_Auditoria_Cambios`** |
| Log ingeniería | (interno `registrar_log`) | **`Tbl_Log_Cambios_Ingenieria`** (`ID_Revision`, acción, detalle) |
| QA / bugs | `/api/reportes/*` | **`Tbl_Reportes_Beta`** |
| Login | `POST /api/login` | Según implementación de usuarios en BD |

---

## Capítulo 4 — QA y auditoría

### 4.1 Reportes QA (Zoom, Base64)

- Los reportes se persisten en **`Tbl_Reportes_Beta`** con campo **`Captura_Base64`** (imagen adjunta codificada).
- **Alta:** `POST /api/reportes/nuevo` — cuerpo con usuario, módulo, descripción, gravedad y captura.
- **Listado:** `GET /api/reportes` — devuelve metadatos + `captura_base64` para el **Centro de QA** (`qa_dashboard.dart`).
- **Export:** `GET /api/reportes/exportar_gemini` (JSON con capturas), `GET /api/reportes/exportar` (Excel sin embebido binario en celdas).
- **Cierre:** `PUT /api/reportes/{id}/resolver` — marca estado **Cerrado**.

En Flutter, el detalle del reporte usa vistas que permiten **zoom/pan** (p. ej. `InteractiveViewer`) sobre la imagen decodificada desde Base64.

### 4.2 Log de cambios y trazabilidad

| Sistema | Tabla | Alcance |
|---------|--------|---------|
| **Auditoría global** | `Tbl_Auditoria_Cambios` | Eventos diversos (piezas, VIN, eliminación de revisiones, etc.). **Historial de Cambios** en app → `GET /api/historial`. |
| **Log de ingeniería por revisión** | `Tbl_Log_Cambios_Ingenieria` | Acciones BOM (aprobar, branching, derivaciones…); asociado a `ID_Revision`. Consulta vía endpoints de log de BOM (`/api/bom/log/{id_revision}`). |

`registrar_log` no debe romper la transacción principal: los errores de inserción se ignoran de forma controlada.

---

## PASO 3 — Verificación post-corrección del Lobby

### Conteo de versiones = 0 tras purga

1. En SQL:  
   `SELECT COUNT(*) FROM Tbl_Versiones_Ingenieria;`  
   Debe ser **0** si la purga de ingeniería fue completa.

2. En API (backend en marcha):  
   `GET /api/dashboard/kpi` → campo **`total_versiones`** debe ser **0** (misma fuente: `COUNT(*)` sobre **`Tbl_Versiones_Ingenieria`**).

3. En app: abrir **Lobby Principal** y comprobar la tarjeta **“Versiones de Ing.”** — debe mostrar **0**.

### Coherencia Analytics

`GET /api/analytics/dashboard/{id_revision}` incluye **`total_versiones`** con la misma lógica (`Tbl_Versiones_Ingenieria`), para no desviarse del Lobby.

### Elementos UI documentados

- Todo ítem del menú lateral principal y footer está referenciado en **§1.3–1.4**.
- **BOM Manager** y rutas de login/splash están en **§1.3** (auxiliares).
- Archivos **home/editor** sin enlace en el pane actual están marcados como **legado** para evitar confusiones con “botones huérfanos” no documentados.

---

*Última actualización: alineación KPI `total_versiones` con `Tbl_Versiones_Ingenieria` y creación de esta wiki.*
