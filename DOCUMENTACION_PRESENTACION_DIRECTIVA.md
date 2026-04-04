   # Industrial Manager — Documentación para presentación directiva

**Alcance:** visión técnica y de negocio del ecosistema **Flutter (escritorio) + FastAPI + SQL Server**, con foco en **Ayudas Visuales**, **Radar de Impacto** y **Gestor / Centro de Monitoreo de Tareas**.  
**Versión de referencia en código:** API etiquetada como *Industrial Manager API v60.0*; cliente Flutter `industrial_manager_v15_5`.

---

## 1. Arquitectura del sistema

### 1.1 Visión general

La solución sigue un patrón **cliente-servidor** clásico: una aplicación de escritorio consulta y envía datos a una API REST; la API persiste y consulta información en **Microsoft SQL Server** mediante **ODBC** (`pyodbc`).

```text
┌─────────────────────────┐         HTTP/JSON          ┌─────────────────────────┐
│  Flutter Desktop        │ ◄──────────────────────────► │  FastAPI (Python)       │
│  (Windows, Fluent UI)   │    Puerto configurable       │  uvicorn, p. ej. :8001    │
└─────────────────────────┘                              └────────────┬────────────┘
                                                                       │
                                                                       │ ODBC (TCP 1433)
                                                                       ▼
                                                            ┌──────────────────────┐
                                                            │  SQL Server          │
                                                            │  Base: materiales /   │
                                                            │  ingeniería (BOM,     │
                                                            │  tareas, ayudas…)    │
                                                            └──────────────────────┘
```

**Punto de configuración del cliente:** la URL base del API se define en `lib/config/app_config.dart` (`kApiBaseUrl`, por defecto apuntando al mismo host que la base de datos en el entorno de referencia).

**Servidor API:** `backend/server.py` crea la aplicación FastAPI, registra **routers** modulares (`bom`, `engineering`, `gestor_tareas`, `ayudas_visuales`, `auth`, `cad`, etc.) y expone CORS abierto para entornos de red interna. Al arranque se inicializan servicios de **auditoría** y **autenticación**.

**Base de datos:** `backend/database.py` centraliza la cadena de conexión (servidor, puerto, nombre de base, **Trusted_Connection**, `TrustServerCertificate`) y la función `get_db_connection()` usada por todos los routers.

### 1.2 Capa de presentación (Flutter)

- **Framework:** Flutter con **Fluent UI** para una experiencia alineada a Windows.
- **Comunicación:** cliente HTTP centralizado (`lib/services/api_client.dart`) que:
  - construye URLs a partir de `kApiBaseUrl`;
  - adjunta `Authorization: Bearer …` cuando existe token tras el login (`SharedPreferences`).
- **Navegación principal:** `lib/main.dart` integra las pantallas en el shell de la aplicación (incluye Radar de Impacto, Ayudas Visuales y Centro de Monitoreo, entre otros módulos).

### 1.3 Capa de aplicación (FastAPI)

- **Responsabilidad:** exponer endpoints REST, validar payloads (Pydantic), ejecutar SQL, servir archivos (PDF de ayudas), y orquestar procesos pesados (p. ej. CAD) en routers dedicados.
- **Seguimiento:** `audit_service` y `registrar_log_global` registran acciones relevantes (ayudas, gestor de tareas, etc.).
- **Identidad:** `user_context.resolve_actor_user` combina cabeceras JWT / `X-Usuario` para atribuir operaciones.

### 1.4 Capa de datos (SQL Server)

Los módulos descritos en este documento apoyan en tablas como:

- **BOM / ingeniería:** `Tbl_BOM_Estructura`, `Tbl_Ensambles`, `Tbl_BOM_Revisiones`, `Tbl_Versiones_Ingenieria`, jerarquía de proyectos (`Tbl_Proyectos_Tracto`, `Tbl_Tipos_Proyecto`), clientes por versión, etc.
- **Ayudas visuales:** `Tbl_Ayudas_Categorias`, `Tbl_Ayudas_Maestro`, `Tbl_Ayudas_Revisiones` (script de referencia en `backend/sql/create_ayudas_visuales.sql`).
- **Gestor de tareas:** `Tbl_Gestor_Tareas`, `Tbl_Gestor_Checklist` (el API **descubre nombres de columnas** en tiempo de ejecución para adaptarse a variantes del esquema).

### 1.5 Activos en disco y red

- **Ayudas visuales:** PDFs bajo ruta de red tipo `Z:\Ayudas_Visuales\<Categoria>\` (configurable en el router de ayudas).
- **CAD / automatización:** existen herramientas y routers que interactúan con entornos Windows (SolidWorks, AutoCAD); no son el foco de este documento pero forman parte del mismo despliegue industrial.

---

## 2. Módulo de Ayudas Visuales

### 2.1 Propósito de negocio

Centralizar **documentación visual operativa** (principalmente **PDF**) por **categorías** (p. ej. torque, pintura, seguridad), con **trazabilidad por revisiones**: cada documento puede tener varias versiones de archivo; una queda marcada como **vigente** para consulta diaria, manteniendo historial.

### 2.2 Modelo de datos

| Entidad | Rol |
|--------|-----|
| **Categoría** | Agrupa documentos; campos como nombre, activo, código de icono para la UI. |
| **Maestro (documento lógico)** | Un título por categoría; admite **subcategoría** y **VIN** opcional para filtrado o contexto vehicular. |
| **Revisión** | Cada subida de PDF: número de revisión, ruta en disco, fecha, usuario, bandera **Es_Vigente**. |

Al subir una nueva revisión, el backend **desactiva** revisiones anteriores del mismo documento (`Es_Vigente = 0`) e inserta la nueva como vigente.

### 2.3 Almacenamiento de archivos

- Carpeta raíz configurable (`AYUDAS_RAIZ` en `backend/routers/ayudas_visuales.py`).
- Subcarpeta por **nombre de categoría sanitizado** (caracteres problemáticos reemplazados).
- Nombre de archivo: identificador de ayuda + revisión + sufijo único (UUID) + extensión `.pdf`.

### 2.4 API principal (resumen)

| Método | Ruta | Uso |
|--------|------|-----|
| GET | `/api/ayudas/categorias` | Listado de categorías activas. |
| POST | `/api/ayudas/categorias` | Crear categoría (con auditoría). |
| GET | `/api/ayudas/lista/{id_categoria}` | Documentos con revisión **vigente**. |
| GET | `/api/ayudas/historial/{id_ayuda}` | Todas las revisiones de un documento. |
| POST | `/api/ayudas/subir` | Subida multipart de PDF (nuevo documento o nueva revisión). |
| GET | `/api/ayudas/ver/{id_revision}` | **Streaming** del PDF al visor. |
| PUT | `/api/ayudas/subcategoria/editar` | Renombrado masivo de subcategorías. |
| DELETE | `/api/ayudas/revision/{id_revision}` | Elimina revisión (y archivo si aplica). |
| DELETE | `/api/ayudas/documento/{id_ayuda}` | Elimina documento y todas sus revisiones. |

### 2.5 Experiencia en Flutter

Flujo en tres niveles (`lib/screens/ayudas_visuales/`):

1. **Menú de categorías** — rejilla con iconos según `Icono_Codigo` (mapeo a iconos Material).
2. **Lista por categoría** — documentos vigentes, búsqueda, alta de documento / subida (según permisos `canUpload`).
3. **Visor** — **Syncfusion PDF Viewer** + línea de tiempo de revisiones; la URL del PDF apunta al endpoint `ver` del API.

El contenedor `AyudasVisualesNav` usa un `Navigator` interno para no mezclar el back stack con el resto de la app.

**Mensaje clave para dirección:** las ayudas dejan de depender solo de carpetas compartidas sin control; pasan a tener **catálogo, versiones y auditoría** integrados con la misma identidad de usuario que el resto del sistema.

---

## 3. Radar de Impacto — lógica de negocio y cálculo de tiempos

### 3.1 Qué problema resuelve

Ante el cambio de una **pieza** (o varias, separadas por comas), la organización necesita saber **dónde se usa** cada código en la estructura de producto (ensambles, listas BOM, proyecto, cliente) y **cuánto esfuerzo documental/diseño** estimar para acompañar ese cambio. El Radar automatiza la **exploración** y ofrece una **simulación cuantificada en minutos**, alineada a entregables típicos de ingeniería (planos, PDFs, plano general, Drive, relaciones en CAD).

### 3.2 Fase 1 — “Where used” (escaneo en pantalla)

**Endpoint:** `GET /api/bom/where-used/{codigo_pieza}` (`engineering.py`).

- Recorre la BOM **ascendente** (la pieza aparece en líneas de `Tbl_BOM_Estructura` ligadas a ensambles, estaciones y revisiones).
- Devuelve filas con: ensamble, cantidad, lista/revisión BOM, versión, tipo de proyecto, tracto, **cliente**.

En Flutter (`impact_radar_screen.dart`), el usuario puede introducir **varios códigos** separados por comas. Para cada código se llama al endpoint y los resultados se **agrupan** en una estructura:

`Cliente → "Tracto / Proyecto / Versión (Rev …)" → lista de ensambles` (sin duplicar el mismo `id_ensamble` dentro del mismo grupo).

Esa vista responde a la pregunta: **“¿En qué configuraciones de cliente y en qué listas afecta este cambio?”**

### 3.3 Fase 2 — Simulación de impacto y minutos

**Endpoint:** `POST /api/bom/impacto/simular` con cuerpo JSON (`ImpactSimulationPayload`).

**Filtros de datos (regla de negocio):**

- Solo revisiones BOM con **`Estado = 'Aprobada'`**.
- Si en `Tbl_BOM_Revisiones` existe la columna **`Es_Vigente`**, solo se consideran filas con `Es_Vigente = 1` (o equivalente según `ISNULL`).

**Consolidación:**

- Se unen todas las filas que usan **cualquiera** de los códigos analizados (lista separada por comas).
- Se agrupa por **`id_ensamble` único**. Si un ensamble aparece varias veces por joins, la **cantidad de pieza** usada para “relaciones” toma el **máximo** observado.
- Por cada ensamble se calcula **`cantidad_piezas_distintas`**: número de códigos distintos en toda la BOM de ese ensamble (consulta adicional `COUNT(DISTINCT Codigo_Pieza)`), usada como proxy de **complejidad del ensamble** para PDF.
- Se identifican las **piezas del análisis** presentes en cada ensamble (`piezas_especificas_encontradas`).
- **Grupos de plano general:** claves únicas `(Cliente, ID_Tipo, ID_Versión)` para no duplicar el esfuerzo de “plano maestro” cuando varios ensambles comparten el mismo contexto de producto/cliente.

### 3.4 Fórmulas de tiempo (minutos) — lado servidor

Sean:

- \(C\) = número de **códigos de pieza** en el análisis (tras separar por comas).
- \(E\) = número de **ensambles distintos** afectados.
- \(D_i\) = **piezas distintas** en el ensamble \(i\) (cardinalidad de BOM del ensamble).
- \(G\) = número de **grupos** distintos *(Cliente + Tipo + Versión)* para plano general.
- \(\text{cant}_i\) = cantidad de la pieza afectada en el ensamble \(i\) (entero **ceil** para relaciones).

**Flags del payload** (cada uno suma solo si está en `true`):

| Concepto | Condición | Minutos añadidos al total global | Notas |
|----------|-----------|-----------------------------------|--------|
| Plano de pieza | `incluir_plano_pieza` | \(10 \times C\) | Un bloque por código: “Actualizar plano pieza (CODE)”. |
| Planos de ensamble | `incluir_plano_ensamble` | \(20 \times E\) | Agregado como un solo entregable global. |
| PDF de ensambles | `incluir_pdf_ensamble` | \(\sum_i (5 + D_i)\) | Base 5 min por ensamble + 1 min por pieza distinta en ese ensamble. |
| Plano general maestro | `incluir_plano_general` | \(23 \times \max(G, 1)\) | Por grupo Cliente+Tipo+Versión. |
| Subir a Drive | `incluir_subir_drive` | \(3 \times (E + (C \text{ si plano pieza}))` | Cuenta un “plano” por ensamble y, si aplica, uno por cada pieza con plano. |
| Relaciones CAD | `afecta_relaciones` | \(\sum_i (\text{cant}_i \times 5)\) | Por ensamble; también se refleja en el detalle por ensamble. |

**Minutos por ensamble** (`minutos_estimados` en `resumen_ensambles`), coherente con lo anterior a nivel línea:

\[
\text{per\_ens}_i =
\begin{cases}
20 & \text{si plano ensamble} \\
0 & \text{si no}
\end{cases}
+
\begin{cases}
5 + D_i & \text{si PDF ensamble} \\
0 & \text{si no}
\end{cases}
+
\begin{cases}
\text{cant}_i \times 5 & \text{si afecta relaciones} \\
0 & \text{si no}
\end{cases}
\]

**Importante:** los **totales globales** (`total_minutos` y la lista `entregables`) son la suma de **partidas de proyecto** (planos pieza, bloques agregados, Drive, relaciones, etc.). Las cifras por ensamble sirven para **desglose** y priorización visual en la UI.

### 3.5 Comportamiento en la aplicación Flutter

- El usuario marca **tareas globales** (plano pieza, PDF/DXF, Drive, etc.) y opción **“afecta relaciones”**.
- La llamada a simular envía esos booleanos; **`incluir_plano_ensamble` está fijado en `true`** en el cliente actual (siempre se asume actualización de plano de ensamble en la simulación).
- Tras simular, puede **crear una tarea en el Gestor** con tipo `RADAR`, título de cambio, minutos totales, **checklist** derivada de `entregables` y **meta** JSON con toda la simulación para trazabilidad.

**Nota de transparencia:** la casilla **E-Drawing** aparece en la UI del Radar como tarea global, pero **no forma parte del payload** de `/api/bom/impacto/simular` en la versión actual del código; no incide en los minutos calculados por el backend hasta que se integre explícitamente.

---

## 4. Gestor de Tareas y Centro de Monitoreo

### 4.1 Rol en el negocio

El gestor convierte estimaciones (p. ej. salida del Radar) y otras iniciativas en **tareas ejecutables** con **checklist**, **progreso** y **estado**, persistidos en SQL Server para visibilidad compartida y seguimiento.

### 4.2 Backend (`gestor_tareas.py`)

**Crear tarea:** `POST /api/tareas/crear`

- Payload: `tipo` (p. ej. `RADAR` o `MANUAL`), `titulo`, `descripcion`, `codigo_pieza`, `minutos_estimados`, lista `checklist` (nombre + minutos por ítem), `meta` (objeto JSON arbitrario, p. ej. simulación completa), `titulo_cambio` opcional.
- Inserta en **`Tbl_Gestor_Tareas`** usando **mapeo dinámico** de columnas (`INFORMATION_SCHEMA`): el código busca nombres habituales (`Titulo`, `Tipo_Tarea`, `Minutos_Estimados`, `Meta_JSON`, etc.) para compatibilidad con distintas convenciones de nombres en la base.
- Inserta ítems en **`Tbl_Gestor_Checklist`** ligados por clave foránea a la tarea, con orden secuencial.
- Estado inicial: **Pendiente**, progreso **0**; usuario tomado de contexto de autenticación.
- Auditoría: evento `CREAR_TAREA`.

**Listar:** `GET /api/tareas/lista`

- Devuelve tareas ordenadas por ID descendente, cada una con su checklist.
- Calcula progreso alternativo si hiciera falta: proporción de ítems marcados como completados.

**Actualizar ítem:** `PUT /api/tareas/check/{id_check}`

- Marca un ítem del checklist como completado o no.
- Recalcula **porcentaje** de la tarea y actualiza **estado** a `En proceso` o `Terminado` (100%).
- Auditoría: `UPDATE_CHECK`.

El diseño **schema-tolerant** reduce fricción ante evoluciones de la base sin redeploy inmediato del mapeo fijo.

### 4.3 Frontend — Centro de Monitoreo (`monitoreo_tareas_screen.dart`)

Pantalla con **dos pestañas**:

1. **Tareas de Radar**  
   - Carga `/api/tareas/lista`.  
   - Filtra tareas cuyo `tipo` contiene / es `RADAR`.  
   - Muestra barra de progreso y permite abrir un diálogo de **checklist** que llama a `PUT /api/tareas/check/...` y refresca la lista.

2. **Cambios manuales (Excel)**  
   - Tabla estilo **hoja de cálculo** alineada a una **plantilla de cambios** (columnas: cambio, dificultad 1–4, equipos, marcas para planos, e-drawing, listas, ensamble, ayuda visual, completado).  
   - Los datos viven en **`SharedPreferences`** (clave `monitoreo_cambios_manuales_v1`), no en SQL en la implementación actual: sirve como **tablero local** de seguimiento paralelo al Excel operativo.  
   - Incluye semillas iniciales que replican filas típicas de la plantilla y acciones para agregar filas o **restaurar plantilla**.

**Mensaje para dirección:** el **Gestor SQL** centraliza tareas **cuantificadas y auditables** (especialmente las originadas en el Radar); el tablero **manual** replica la lógica visual del Excel de cambios para reuniones y seguimiento en pantalla, con persistencia local hasta que se decida unificar en base de datos si el negocio lo requiere.

---

## 5. Resumen ejecutivo (mensajes clave)

| Tema | Mensaje |
|------|---------|
| **Arquitectura** | Cliente Flutter en Windows, API FastAPI en red interna, datos en SQL Server; un solo punto de configuración de URL en el cliente. |
| **Ayudas visuales** | Biblioteca de PDFs por categoría con revisiones, historial, auditoría y archivos en ruta de red controlada. |
| **Radar de impacto** | De código(s) de pieza a mapa de uso en BOM + estimación en minutos basada en reglas explícitas (planos, PDFs, plano general, Drive, relaciones). |
| **Gestor / Monitoreo** | Tareas con checklist en base de datos; el monitoreo muestra tareas RADAR del servidor y un tablero manual tipo Excel almacenado localmente. |

---

*Documento generado a partir del análisis del repositorio. Las fórmulas y rutas reflejan el código vigente; cualquier ajuste de reglas de negocio debe actualizarse de forma coordinada en `engineering.py` (simulación) y en la UI del Radar.*
