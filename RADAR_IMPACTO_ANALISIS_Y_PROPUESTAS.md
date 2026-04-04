# Radar de Impacto — Análisis de lógica actual y propuestas de mejora

Documento para revisión detallada. Basado en lectura del código del repositorio (sin implementación asociada).

---

## 1. Archivos involucrados

| Archivo | Papel |
|---------|--------|
| `lib/screens/impact_radar_screen.dart` | Toda la UI y flujo: escaneo, flags, simulación, árbol, plano general, tarea en gestor. |
| `backend/routers/engineering.py` | `GET /api/bom/where-used/{codigo_pieza}` y `POST /api/bom/impacto/simular` (payload Pydantic, SQL, fórmulas). |
| `lib/services/api_client.dart` | HTTP GET/POST (auth opcional). |
| `lib/main.dart` | Integra `ImpactRadarScreen` en el shell. |
| `backend/routers/gestor_tareas.py` | `POST /api/tareas/crear` cuando se genera la tarea desde el radar (no es cálculo de impacto, pero cierra el flujo). |

No hay otros routers ni pantallas que participen en el cálculo del radar.

---

## 2. Lógica actual (end-to-end)

### 2.1 Entrada de códigos

En Flutter, el texto se parte por **comas**, se recorta, pasa a **mayúsculas** y se **deduplica** (`_codigosPiezaDesdeCampo`). Esa lista se usa en escaneo; para el resto se guarda `_currentPiece` como **un solo string** `"CODE1, CODE2"` que es el que viaja a simular y al gestor.

### 2.2 Fase “Escanear impacto” (árbol)

- Por **cada** código se hace un **`GET /api/bom/where-used/{codigo}`** (varias peticiones en serie).
- El SQL de `get_where_used` une `Tbl_BOM_Estructura` → ensamble → estación → **revisión BOM** → versión → tipo → tracto → cliente.
- **No filtra** por `Estado = 'Aprobada'` ni por `Es_Vigente`: cualquier lista donde exista la pieza aparece en el árbol.

En cliente, cada fila se coloca en:

`Map<Cliente, Map<"Tracto / Proyecto / Versión (Rev …)", List<ensamble>>>`

y se evita duplicar el mismo `id_ensamble` dentro del mismo grupo. Por cada ensamble nuevo se crea un `_localChecklists[idEns]` con `plano_ensamble`, `pdf_ensamble`, `drive` en **false**.

Tras cargar, `_syncGruposPlanoGeneralKeys()` crea una entrada en `_planoGeneralPorGrupo` por cada clave de segundo nivel (el string largo `proyecto`), por defecto **`true`**.

### 2.3 Fase “Evaluar impacto” (minutos)

- Un solo **`POST /api/bom/impacto/simular`** con `codigo_pieza: _currentPiece` (misma lista separada por comas que parsea el backend con `_parse_codigos_pieza`).
- El SQL **sí filtra** `R.Estado = 'Aprobada'` y, si existe columna `Es_Vigente`, `ISNULL(R.Es_Vigente, 1) = 1`.
- Consolidación por **`id_ensamble` único**. Si hay varias filas para el mismo ensamble, la **cantidad** para relaciones es el **máximo** de `Cantidad` visto.
- `cantidad_piezas_distintas`: `COUNT(DISTINCT Codigo_Pieza)` en **toda** la BOM de ese ensamble (no solo las piezas del análisis).
- **Plano general:** grupos únicos `(Cliente, ID_Tipo, ID_Version)` — la **revisión de lista no entra** en esa clave.
- **Tiempos (reglas fijas en código):** 10 min por código con plano pieza; 20 min por ensamble con plano ensamble; PDF ensamble Σ(5 + piezas_distintas); plano general 23 × número de grupos; Drive 3 × (ensambles + códigos con plano pieza si aplica); relaciones ⌈cantidad⌉×5 por ensamble cuando el flag está activo.
- Respuesta: `total_minutos`, `entregables` (líneas agregadas y, en relaciones, una línea por ensamble con `id_ensamble`), `resumen_ensambles` (incluye `minutos_estimados` por ensamble = 20 + (5+D) + relaciones si aplica), `tipos_o_grupos_afectados`.

### 2.4 Qué hace realmente la UI con eso

- **Flags globales** que **sí** llegan al API: `_gPlano` → `incluir_plano_pieza`, `_gPdfDxf` → `incluir_pdf_ensamble`, `_gDrive` → `incluir_subir_drive`, `_afectaRelaciones`, y `_incluirPlanoGeneralSimulacion` (derivado de los checkboxes “Plano General” por fila del árbol).
- **`incluir_plano_ensamble` va siempre `true`** en el POST: el usuario no puede apagarlo.
- **`_gEdrawing`:** solo estado local; **no se envía** al backend → **no cambia minutos**.
- **Checklist por ensamble** (`_localChecklists`): solo `setState` en pantalla; **nunca se envían** a simular ni al gestor.
- **Plano general por grupo:** la clave es el **string** `Tracto / Proyecto / Versión (Rev X)`. El backend agrupa por **(cliente, id_tipo, id_version)**. Si varias filas del árbol comparten ese triple pero difieren en revisión visible en el texto, el usuario ve **varios** checkboxes pero el servidor puede contar **un solo** grupo → la UI puede **sobre-representar** control fino frente al cálculo real.
- Al marcar “Plano General” o “Afecta relaciones”, si ya hay `_currentPiece`, se llama **`_evaluarImpacto()`** de nuevo (re-simulación automática).
- Tras simular, se puede **Generar tarea**: checklist = todos los `entregables` (nombre + minutos), `meta` = JSON completo de la simulación.

### 2.5 Inconsistencia importante (árbol vs simulación)

- El **árbol** puede mostrar usos en listas **no aprobadas** o no vigentes.
- La **simulación** solo cuenta **aprobadas** (y vigentes si aplica).

Eso puede dar el caso: **árbol con ensambles** pero **simulación en 0** o **menos ensambles** de los mostrados, sin que el usuario lo entienda si no conoce la regla.

---

## 3. Propuestas de mejora (sin implementar)

### 3.1 Coherencia de datos y confianza del usuario

1. **Alinear criterios** entre `where-used` y `simular`: mismos filtros (`Aprobada`, `Es_Vigente`) **o** mantener `where-used` amplio pero mostrar en cada nodo **badge** “Borrador / No vigente” según columnas de `R` (requiere ampliar el SELECT del GET). Objetivo: que el árbol y los minutos cuenten la **misma realidad operativa**.

2. **Un solo endpoint de escaneo multi-código**, p. ej. `POST /api/bom/where-used` con lista de códigos: menos latencia, una transacción, misma lógica de filtros que la simulación si se elige alinear.

### 3.2 Modelo de UI alineado con el backend

3. **Plano general:** usar en la UI identificadores estables devueltos por el API (`tipos_o_grupos_afectados` ya trae `cliente`, `id_tipo`, `id_version`, nombres). Un checkbox por **ese** grupo, no por string que mezcla revisión. Si hace falta granularidad por revisión, habría que **cambiar la regla de negocio** en el servidor, no solo la UI.

4. **Checklists por ensamble:** o bien **eliminarlas** (evitar falsa sensación de control) o **conectarlas**: p. ej. enviar al simular un mapa `id_ensamble → {plano, pdf, drive}` y que el backend **recorte** ensambles o minutos (más trabajo de diseño, pero coherente).

5. **`incluir_plano_ensamble`:** exponer toggle en UI como el resto; hoy está forzado a verdadero.

6. **E-Drawing:** añadir al payload y a las constantes de tiempo (o unificar con “PDF/DXF” si negocio lo ve equivalente), o **quitar** el checkbox para no generar expectativas falsas.

### 3.3 Estimación y mantenimiento

7. **Parametrizar** los números (10, 20, 5, 23, 3, 5 min/relación) en tabla de configuración o archivo de política, con posible **perfil por tipo de proyecto** o complejidad, en lugar de mágicos en código.

8. **Validación opcional** al crear tarea: que la suma de minutos del checklist coincida con `total_minutos` (o documentar que el total es “oficial” y los ítems son desglose).

### 3.4 Experiencia y robustez

9. **Re-evaluar al cambiar** flags globales (plano pieza, PDF, Drive) con el mismo patrón que ya usas para plano general y relaciones — o un botón explícito “Actualizar estimación” para no disparar tantas llamadas.

10. **Mostrar en UI** `tipos_o_grupos_afectados` y, si el árbol sigue mostrando listas no aprobadas, una leyenda clara: *“La estimación solo incluye listas aprobadas y vigentes.”*

11. **Manejo de carga:** indicador de progreso si hay muchos códigos en el escaneo secuencial actual; o el batch del punto 2.

---

## 4. Resumen ejecutivo

La lógica actual es **escaneo permisivo + simulación restrictiva**, **constantes fijas**, **parte de la UI no conectada al cálculo** (E-Drawing, checklist por ensamble), y **plano general** con posible desajuste entre claves de UI y agrupación del servidor.

Las mejoras con más retorno suelen ser **alinear filtros o visualizar estado de lista**, **unificar criterio de grupos para plano general**, y **parametrizar / conectar** lo que hoy es decorativo o fijo.

---

*Documento generado para análisis interno. Ajustar prioridades según acuerdo de negocio antes de implementar.*
