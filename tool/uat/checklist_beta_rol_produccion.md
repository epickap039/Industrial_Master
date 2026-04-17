# Checklist UAT — rol **Producción** (`PRODUCCION`)

Documento para beta testers con usuario cuyo rol en base de datos es **PRODUCCION** (también acepta **PRODUCCIÓN**).  
Versión alineada al código de la app (navegación, permisos de UI y buzón de notificaciones).

---

## 1. Glosario breve (técnico → simple)

| Término | Qué es, en pocas palabras |
|--------|---------------------------|
| **Rol** | Etiqueta del usuario que decide qué menús y botones ve la aplicación. No es lo mismo que “contraseña”. |
| **Lobby** | Pantalla de inicio con accesos rápidos (en Producción suele ser una vista enfocada a **ayudas** y **catálogo**). |
| **JWT / sesión** | Credencial digital tras iniciar sesión; mantiene abierta la app con tu usuario. |
| **Catálogo maestro** | Tabla principal de piezas: códigos, materiales, medidas, etc. (aquí Producción es **solo lectura**). |
| **Ayudas visuales** | Instructivos en PDF (u otros) agrupados por categoría; Producción **consulta** y abre documentos. |
| **Revisión (ayudas)** | Versión publicada de un documento; ingeniería puede subir nuevas; tú ves la **vigente**. |
| **Mapa de ingeniería** | Árbol de proyectos / versiones / revisiones para ubicar en qué “rama” está un ensamble. |
| **BOM** | Lista de materiales de una pieza o ensamble (gestor avanzado); **Producción no debe abrirlo** desde el mapa. |
| **Columnas “privadas”** | Caminos de archivos en servidor, DXF, “quién modificó”, etc., ocultos a Producción por seguridad. |
| **Modo claro / oscuro** | Tema visual; debe seguir siendo legible en ambos. |

---

## 2. Alcance real del rol Producción (qué **sí** y qué **no**)

Resumen derivado de permisos en código (`lib/services/app_role.dart`, `lib/services/nav_pane.dart`, `lib/main_layout.dart`).

### 2.1 Debe ver en el menú lateral (rail)

1. **Lobby principal**  
2. **Operación diaria** → solo submódulo **Ayudas visuales** (no chat, no radar, no monitoreo).  
3. **Datos y catálogos** → **Catálogo maestro** (sin generador de código, sin MRP, sin estadísticas).  
4. **Mapa de ingeniería** (jerarquía y estados de revisiones; **sin** abrir BOM).

### 2.2 No debe ver (comprueba que **no** aparezcan)

- **Ingeniería y cambios** (hub completo).  
- **Seguimiento e incidentes** (Centro QA, historial de cambios, notas de versión).  
- **Centro de monitoreo** como ítem propio del rail.  
- **Chat interno** (ni en menú ni botón de chat en barra superior, según build actual).  
- Pie del menú: entrada **Configuración** (diagnóstico avanzado / ajustes del sistema) — **oculta** para Producción.  
- En **Catálogo**: botones de exportar Excel/PDF, selector de columnas, búsqueda DXF; botones de sincronización de stock PT **visibles pero deshabilitados** (solo ingeniería los ejecuta).  
- En **Ayudas**: subir/borrar documentos, editar icono de categoría, **historial de revisiones** del mismo documento (Producción no debe ver esa línea de tiempo; sí puede usar comparación entre ayudas vigentes si está habilitada en tu build).

### 2.3 Barra superior y pie

- **Campana (buzón)**: para Producción avisa de **novedades en ayudas visuales** (no es el mismo buzón de misiones del centro de monitoreo).  
- **Tema visual** y **Reportar bug**: deben estar en el pie del menú.  
- Indicador de **red / servidor** (si existe en tu pantalla): debe reflejar conexión razonable.

---

## 3. Cómo pasar esto a **Google Forms** (documentado)

Objetivo: cada ítem del checklist = **una pregunta** trazable + comentario opcional.

### 3.1 Estructura recomendada del formulario

1. **Sección 0 — Metadatos** (texto corto): nombre del tester, fecha, versión de la app o build, resolución de pantalla aproximada, Windows.  
2. **Sección 1 — Legibilidad y UX general** (bloque común a todos los roles).  
3. **Sección 2 — Lobby**  
4. **Sección 3 — Ayudas visuales**  
5. **Sección 4 — Catálogo maestro**  
6. **Sección 5 — Mapa de ingeniería**  
7. **Sección 6 — Barra superior, pie y notificaciones**  
8. **Sección 7 — Comprobaciones negativas** (“no debe poder…”)  
9. **Sección 8 — Comentarios libres** (párrafo largo).

### 3.2 Tipo de pregunta sugerido por ítem

| Necesidad | Tipo en Google Forms |
|-----------|----------------------|
| ¿Pasó la prueba? | **Opción múltiple** fija: `Sí` · `No` · `No apliqué / sin datos` |
| Severidad si falló | **Escala lineal** 1–5 o lista: `Bloqueante` · `Grave` · `Menor` · `Cosmético` |
| Detalle / captura | **Párrafo** opcional debajo, o una sola pregunta “Adjunta enlace a captura” al final |

**Consejo:** en Forms, activa **“Respuesta obligatoria”** solo en bloques críticos; deja “No apliqué” para no forzar datos inventados.

### 3.3 Importación masiva

Google Forms permite **importar preguntas desde una hoja de cálculo** (menú del formulario: importar). La fila suele llevar al menos: texto de la pregunta y tipo.  
En la **última sección** de este documento hay una tabla **TSV** (separada por tabuladores) lista para pegar en Google Sheets y probar importación; si el importador de tu cuenta no acepta el tipo, copia solo las columnas *Pregunta* y *Ayuda* y asigna el tipo `Opción múltiple` a mano una vez por sección.

---

## 4. Checklist de pruebas (Producción)

Convención de columnas:

- **ID**: código estable para enlazar con tickets o hoja de resultados.  
- **Prueba**: qué hacer.  
- **Nota técnica**: por qué existe el comportamiento (opcional para testers).  
- **Criterio “Sí”**: condición de éxito.  
- **Form**: tipo de pregunta sugerida en Google Forms.

---

### Sección A — Entorno, legibilidad y usabilidad general

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| GEN-01 | Inicia sesión con usuario **Producción** y confirma que el **menú lateral** muestra solo las entradas del apartado 2.1. | `visibleNavPanes` + hubs en `nav_pane.dart` / `main_layout.dart`. | Coincide con la lista permitida; no hay ítems extra de ingeniería/QA/monitoreo. | Opción múltiple + párrafo |
| GEN-02 | **Modo claro**: ¿Se lee bien el texto del menú, títulos y tablas sin forzar la vista? | Tema Fluent + tokens de color. | Letras nítidas, sin solapes; contraste aceptable en chrome (menú/barra). | Opción múltiple |
| GEN-03 | **Modo oscuro**: misma comprobación. | Regla de contraste shell. | Misma legibilidad; iconos visibles sobre fondo oscuro. | Opción múltiple |
| GEN-04 | Cambia entre claro y oscuro desde **Tema visual** (pie del menú) varias veces. | `PaneItemAction` tema en `main_layout.dart`. | No queda pantalla en blanco, no hay textos “fantasma” ni cortados. | Opción múltiple |
| GEN-05 | Redimensiona la ventana (más estrecha / más ancha). | `NavigationPane` compacto vs expandido. | Navegación usable; tooltips en rail estrecho si el texto no cabe. | Opción múltiple |
| GEN-06 | **Facilidad de uso** (subjetivo 1–5): ¿encontraste en menos de 1 minuto Ayudas, Catálogo y Mapa? | — | Escala o Sí/No según protocolo del equipo. | Escala + párrafo |

---

### Sección B — Lobby principal

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| LOB-01 | Abre el lobby y verifica que los **accesos o mosaicos** llevan a Ayudas / Catálogo según lo que muestre tu build. | `showsLobbyOperativoAyudasCatalogo` es `true` para Producción. | No hay enlaces rotos; no pide permisos de administrador. | Opción múltiple |
| LOB-02 | Si hay **tarjetas de categorías de ayudas**, los textos e iconos se ven completos y alineados. | Lobby puede cargar datos remotos. | Sin recortes graves; colores coherentes con el tema. | Opción múltiple |
| LOB-03 | Si abres una ayuda desde el lobby, el **visor** abre el PDF (o documento) y puedes volver atrás sin perder sesión. | `MainNav.requestOpenAyudaLobby` / consumo en navegación de ayudas. | Flujo ida y vuelta estable. | Opción múltiple |

---

### Sección C — Operación diaria → Ayudas visuales

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| AYV-01 | Navega **Operación diaria → Ayudas visuales**; lista categorías y documentos. | `showsNavAyudas`; `ayudasCanUpload` es `false`. | Ves listados; **no** ves flujo de subida como ingeniería. | Opción múltiple |
| AYV-02 | Abre un documento vigente en el **visor integrado**; zoom/scroll razonables. | Visor embebido. | Contenido legible; rendimiento aceptable. | Opción múltiple |
| AYV-03 | Comprueba que **no** aparece el **historial de revisiones** del mismo documento (timeline), o está deshabilitado/oculto. | `ayudasShowRevisionHistory` es `false` para Producción. | No se filtra información de versiones internas que no deban verse. | Opción múltiple |
| AYV-04 | Si existe acción **Comparar** entre dos ayudas vigentes, pruébala con dos documentos distintos. | `ayudasAllowCrossDocumentCompare` cuando hay ayudas. | Solo compara documentos permitidos; UI clara. | Opción múltiple / No aplica |
| AYV-05 | **Colores y tipografía** en listados, chips y barras de la pantalla de ayudas: ¿todo legible en claro y oscuro? | — | Sin texto del mismo color que el fondo. | Opción múltiple |

---

### Sección D — Datos y catálogos → Catálogo maestro

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| CAT-01 | Entra a **Catálogo maestro** y busca una pieza por **código** conocido. | `showsNavCatalogo`; solo lectura. | Resultados correctos; filtros respondiendo. | Opción múltiple |
| CAT-02 | Confirma que **no** ves columnas de rutas de archivo, DXF (tienen/largo/ancho), ni “modificado por” como ingeniería. | `catalogHideRutaArchivo`, `catalogHideDxfColumns`, columnas extra Producción en `catalog.dart`. | Esas columnas ausentes u ocultas según política. | Opción múltiple |
| CAT-03 | Confirma que **no** aparecen **Última actualización** / **Fecha creación** si tu build las oculta para Producción. | `catalogHideFechaModificacion` para Producción. | Coherente con lo esperado por privacidad. | Opción múltiple |
| CAT-04 | Revisa la barra de herramientas: **no** deben estar activos exportar Excel/PDF, selector de columnas ni búsqueda DXF. | Flags `catalogCanExport*`, `catalogCanSelectColumns`, `catalogCanSearchDxf`. | Botones ausentes o deshabilitados. | Opción múltiple |
| CAT-05 | Localiza los botones de **sincronización de stock PT**: deben verse **deshabilitados** (no ejecutan). | `catalogShowsStockPtAlmacen` es `false`; `onPressed: null`. | Tooltip indica que solo ingeniería/desarrollo; no rompe la UI. | Opción múltiple |
| CAT-06 | Intenta **editar** una celda o fila: no debe permitir guardar cambios como Producción. | `catalogCanEditRows` es `false`. | No hay edición persistente. | Opción múltiple |
| CAT-07 | Pulsa **Reportar fallo del catálogo** (icono de bug en barra del catálogo) y verifica que el diálogo abre. | Diálogo contextual de bug. | Puedes describir el problema sin error de app. | Opción múltiple |

---

### Sección E — Mapa de ingeniería

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| MAP-01 | Abre **Mapa de ingeniería** y espera a que cargue el árbol (`/api/mapa/jerarquia`). | `showsNavMapaIngenieria`. | Datos o mensaje de error claro; no bloqueo infinito. | Opción múltiple |
| MAP-02 | Localiza una **revisión** y el icono para abrir BOM: debe estar **deshabilitado** o mostrar aviso de acceso restringido. | `bomDesdeMapaPermitido` falso para Producción en `engineering_map.dart`. | No abre `BOMManagerScreen` desde Producción. | Opción múltiple |
| MAP-03 | **Filtro / agrupación** (si existe en tu pantalla): prueba escribir texto de búsqueda. | Filtro local en mapa. | Resultados coherentes; UI fluida. | Opción múltiple |
| MAP-04 | **Legibilidad** de nodos (tracto, tipo, versión, estado con colores). | Estados con colores semáforo. | Leyenda comprensible sin documentación externa. | Opción múltiple |

---

### Sección F — Barra superior, campana y pie

| ID | Prueba | Nota técnica | Criterio “Sí” | Form |
|----|--------|--------------|---------------|------|
| APP-01 | **Campana**: si hay ayuda nueva publicada, aparece **badge** o contador; al abrir, muestra diálogo de “Nueva ayuda visual” o mensaje coherente. | `_AppBarNotificationInbox` rama Producción en `main.dart`. | Flujo comprensible; “Marcar como vista” y “Ver documento” funcionan sin crash. | Opción múltiple / No aplica |
| APP-02 | Tras “Marcar como vista”, el contador debería **bajar o limpiarse** hasta la próxima publicación. | `ProduccionAyudaNovedadPrefs`. | Comportamiento estable. | Opción múltiple / No aplica |
| APP-03 | **Reportar bug** en el pie del menú abre el flujo de reporte. | `onBugTap`. | Formulario o diálogo usable. | Opción múltiple |
| APP-04 | Confirma que **no** existe entrada **Configuración** en el pie para este rol. | `showsFooterConfiguracion` es `false`. | No visible (o no accesible). | Opción múltiple |
| APP-05 | Estado de **red** (icono/indicador si aplica): desconecta Wi‑Fi unos segundos y reconecta. | `NetworkStatusIndicator`. | La app refleja el cambio sin cerrarse. | Opción múltiple |

---

### Sección G — Pruebas negativas (seguridad de rol)

| ID | Prueba | Criterio “Sí” | Form |
|----|--------|---------------|------|
| NEG-01 | Busca en el menú **Centro QA**, **Historial de cambios**, **Radar**, **Monitoreo**, **Chat**: no deben listarse. | Ausentes del menú lateral. | Opción múltiple |
| NEG-02 | Desde catálogo, confirma que no puedes **exportar** ni **buscar DXF**. | Acciones no disponibles. | Opción múltiple |
| NEG-03 | Desde mapa, confirma que no abres **BOM**. | Gestor BOM inaccesible desde Producción. | Opción múltiple |
| NEG-04 | Desde ayudas, confirma que no puedes **subir** archivo ni **editar categoría**. | Sin controles de carga/edición de categoría. | Opción múltiple |

---

## 5. Tabla TSV para Google Sheets (pegar en celda A1)

Copia desde la línea siguiente hasta el final del bloque, pégalo en una hoja y revisa columnas. Ajusta el **tipo** si tu importador usa otros nombres (`multiple_choice`, etc.).

```tsv
ID	Sección	Pregunta	Texto de ayuda (para el tester)	Tipo sugerido	Opción 1	Opción 2	Opción 3
META-01	0 Metadatos	Nombre o iniciales del tester		Quién ejecutó la prueba	Texto corto		
META-02	0 Metadatos	Fecha (AAAA-MM-DD)			Texto corto		
META-03	0 Metadatos	Resolución aproximada (ej. 1920x1080)			Texto corto		
GEN-01	1 General	Menú lateral: solo Lobby, Operación diaria (Ayudas), Datos y catálogos (Catálogo), Mapa de ingeniería	Revisa que NO aparezcan Ingeniería y cambios, Seguimiento, Monitoreo, etc.	Opción múltiple	Sí	No	No probé
GEN-02	1 General	Modo claro: ¿texto legible en menú, títulos y tablas?			Opción múltiple	Sí	No	No aplica
GEN-03	1 General	Modo oscuro: misma legibilidad			Opción múltiple	Sí	No	No aplica
GEN-04	1 General	Cambio de tema varias veces sin pantallas en blanco			Opción múltiple	Sí	No	No probé
GEN-05	1 General	Ventana estrecha/ancha: navegación usable			Opción múltiple	Sí	No	No probé
GEN-06	1 General	Facilidad: ¿Ayudas, Catálogo y Mapa en menos de 1 minuto? (subjetivo)			Escala 1-5		
LOB-01	2 Lobby	Accesos del lobby sin errores ni permisos de admin			Opción múltiple	Sí	No	No probé
LOB-02	2 Lobby	Tarjetas/listas: textos e iconos sin recortes graves			Opción múltiple	Sí	No	No aplica
LOB-03	2 Lobby	Abrir ayuda desde lobby y volver sin perder sesión			Opción múltiple	Sí	No	No probé
AYV-01	3 Ayudas	Listado de categorías/documentos; sin flujo de subida			Opción múltiple	Sí	No	No probé
AYV-02	3 Ayudas	Visor: zoom/scroll y lectura aceptable			Opción múltiple	Sí	No	No probé
AYV-03	3 Ayudas	Historial de revisiones del mismo documento NO visible (o deshabilitado)			Opción múltiple	Correcto (oculto)	Incorrecto (visible)	No probé
AYV-04	3 Ayudas	Comparar entre dos ayudas vigentes (si existe)			Opción múltiple	OK	Fallo	No aplica
AYV-05	3 Ayudas	Colores y tipografía legibles en claro y oscuro			Opción múltiple	Sí	No	No probé
CAT-01	4 Catálogo	Búsqueda por código funciona			Opción múltiple	Sí	No	No probé
CAT-02	4 Catálogo	Columnas privadas (rutas, DXF, modificado por) no visibles como ingeniería			Opción múltiple	Sí	No	No probé
CAT-03	4 Catálogo	Fechas de modificación/creación ocultas si aplica tu política			Opción múltiple	Sí	No	No aplica
CAT-04	4 Catálogo	Sin export Excel/PDF, sin columnas, sin buscar DXF activos			Opción múltiple	Sí	No	No probé
CAT-05	4 Catálogo	Botones stock PT visibles pero NO ejecutan (deshabilitados)			Opción múltiple	Sí	No	No probé
CAT-06	4 Catálogo	No permite editar/guardar filas			Opción múltiple	Sí	No	No probé
CAT-07	4 Catálogo	Reportar fallo del catálogo abre diálogo			Opción múltiple	Sí	No	No probé
MAP-01	5 Mapa	Mapa carga jerarquía o mensaje de error claro			Opción múltiple	Sí	No	No probé
MAP-02	5 Mapa	No se abre BOM desde revisión (icono deshabilitado o aviso)			Opción múltiple	Correcto	Incorrecto	No probé
MAP-03	5 Mapa	Filtros/búsqueda en mapa coherentes			Opción múltiple	Sí	No	No aplica
MAP-04	5 Mapa	Nodos y estados comprensibles visualmente			Opción múltiple	Sí	No	No probé
APP-01	6 App bar	Campana: aviso de nueva ayuda coherente (si hay publicación)			Opción múltiple	OK	Fallo	No aplica
APP-02	6 App bar	Marcar como vista limpia el badge hasta próxima novedad			Opción múltiple	OK	Fallo	No aplica
APP-03	6 App bar	Reportar bug en pie abre flujo			Opción múltiple	Sí	No	No probé
APP-04	6 App bar	NO aparece Configuración en pie para Producción			Opción múltiple	Correcto	Incorrecto	No probé
APP-05	6 App bar	Indicador de red refleja desconexión/reconexión			Opción múltiple	Sí	No	No probé
NEG-01	7 Negativas	No hay Centro QA, Historial, Radar, Monitoreo, Chat en menú			Opción múltiple	Correcto	Incorrecto	No probé
NEG-02	7 Negativas	No export ni DXF en catálogo			Opción múltiple	Correcto	Incorrecto	No probé
NEG-03	7 Negativas	No BOM desde mapa			Opción múltiple	Correcto	Incorrecto	No probé
NEG-04	7 Negativas	No subida ni edición de categoría en ayudas			Opción múltiple	Correcto	Incorrecto	No probé
FIN-01	8 Cierre	Comentarios libres (bloqueantes, sugerencias UX)			Párrafo		
```

---

## 6. Mantenimiento de este documento

Cuando cambien permisos en `AppRole` o entradas de `nav_pane.dart`, actualizar las secciones **2** y **4–5** y la fecha en el control de versiones del repo.

**Referencia de código principal:** `lib/services/app_role.dart`, `lib/services/nav_pane.dart`, `lib/main_layout.dart`, `lib/screens/engineering_map.dart`, `lib/screens/catalog.dart`, `lib/main.dart` (`_AppBarNotificationInbox`), `lib/screens/lobby_screen.dart`.
