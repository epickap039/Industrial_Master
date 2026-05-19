# Reporte técnico MRPII — para agentes IA

**Proyecto:** `industrial_manager_v15_5`  
**Archivos clave:** `backend/routers/mrp.py`, `lib/screens/mrp_screen.dart`  
**Última revisión:** 2026-05-18  

---

## Resumen operativo

| Módulo | API | UI |
|--------|-----|-----|
| Requerimientos | `GET /api/mrp/revisiones`, `GET /api/mrp/calculate/{id_revision}` | `MRPScreen` modo `requerimientos` |
| Nesting / corte MP | `POST /api/mrp/optimizar_uso_material` | `MRPScreen` modo `optimizacionCorte` |
| Excel | Solo cliente (`_exportToExcel`) | 3 hojas: Orden_Compra, Componentes_Comerciales, Auditoria_Ingenieria |

**Datos:** BOM (`Tbl_BOM_Estructura` + revisiones aprobadas) + maestro (`Tbl_Maestro_Piezas`). Material MRP = columna `M.Material` únicamente (sin fallback a descripción).

**Agrupación actual de materia prima:** `(material_oficial, Calibre_Espesor)` donde `Calibre_Espesor = CAST(Espesor_Perfil_CAD AS VARCHAR)` o `'N/A'` si NULL.

---

## PROBLEMA PENDIENTE (no corregido en código) — Fragmentación de espesor

**ID:** `MRP-ESPESOR-001`  
**Estado:** Abierto — investigado, sin fix  
**Reportado por:** UAT / pantalla Requerimientos MRP (ej. REMOLQUE 53 VERSATIL Rev 0)

### Síntoma

Un mismo **material oficial** (ej. `ACERO ASTM A36 1/8"`) aparece en **varias filas** con **calibres/espesores distintos** en la misma revisión:

| Material (ejemplo) | Calibre/Espesor en UI | Piezas (ej.) |
|--------------------|------------------------|--------------|
| ACERO ASTM A36 1/8" | 1.9 | 9 |
| ACERO ASTM A36 1/8" | 3 | 2 |
| ACERO ASTM A36 1/8" | 3.18 | 1183 |
| ACERO ASTM A36 1/8" | N/A | 10 |
| ACERO ASTM A36 3/16" | 4.76, 4.8, 6.35, N/A | … |

La **orden de compra sugerida** se repite por fila (mismas placas 4'×10'), pero el usuario espera **una sola línea por material** para compra y nesting.

### Causa raíz (comportamiento actual, by design)

1. **Doble semántica de “espesor”**
   - **Nombre de material** (`M.Material`): espesor **nominal comercial** embebido en texto (`1/8"`, `3/16"`, `C.10`, `C.14`).
   - **Calibre en MRP** (`Calibre_Espesor`): valor **por pieza** desde `M.Espesor_Perfil_CAD` (propiedad SolidWorks / escaneo CAD), en **mm numérico** (o `N/A`).

2. **Agrupación SQL explícita por ambos campos** (`mrp.py`, CTE `AggPerCode` → `GROUP BY material_oficial, Calibre_Espesor`). Cualquier diferencia en `Espesor_Perfil_CAD` entre piezas del mismo material genera **otra fila MRP**.

3. **Variabilidad de datos en maestro** (origen `Espesor_Perfil_CAD`):
   - Medición real por pieza en SW (chapa ~3.18 mm ≈ 1/8"; redondeos `Round(..., 2)` en macro VBA).
   - Valores atípicos (1.9, 3, 6.35) por piezas mal clasificadas, modelo distinto, importes viejos o espesor de **perfil** vs **lámina**.
   - `NULL` / sin CAD → fila con `N/A` aunque el material ya diga `1/8"` en el nombre.

4. **Sin normalización** hacia el espesor del catálogo oficial ni hacia el token del nombre (`1/8"`, `3/16"`). No hay tabla puente material→espesor canónico usada en el GROUP BY.

5. **Efecto colateral:** stock y brecha **repartidos** en varias filas; riesgo “Crítico/Alerta” duplicado; optimización de corte pide elegir un solo `calibre_espesor` y ignora el resto de variantes del mismo material.

### Comportamiento esperado (negocio)

- **Un material oficial = una fila** (o una fila por material + espesor **canónico** derivado del catálogo, no del CAD crudo pieza a pieza).
- `Calibre_Espesor` debería alinearse con la designación del material (`1/8"` → un valor estándar, p. ej. 3.18 mm) o mostrarse una sola vez desde `Tbl_Materiales_Aprobados` / parser del nombre.
- Piezas sin `Espesor_Perfil_CAD` no deberían abrir fila `N/A` si el material ya declara espesor en el texto.

### Direcciones de solución (para implementación futura; no aplicadas)

| Opción | Descripción |
|--------|-------------|
| A | `GROUP BY` solo `material_oficial`; `Calibre_Espesor` = espesor parseado del nombre o catálogo |
| B | Normalizar `Espesor_Perfil_CAD` a “bin” por tolerancia (±0.1 mm) antes de agrupar |
| C | Regla: si `Material` contiene `1/8"`, `3/16"`, etc., usar ese como calibre y ignorar CAD salvo auditoría |
| D | Vista de huérfanos: piezas mismo material con CAD espesor fuera de tolerancia del nominal |

**Archivos a tocar cuando se implemente:** `backend/routers/mrp.py` (query + posible helper de normalización), opcional `lib/screens/mrp_screen.dart` (etiquetas / aviso de consolidación), Excel `_exportToExcel` si cambia shape de filas.

---

## Referencia rápida: flujo de cálculo (sin cambios)

```
Revisiones aprobadas → PiezasBase (BOM + Maestro)
  → excluir COMERCIAL
  → GROUP BY (Material, Espesor_Perfil_CAD, Codigo_Pieza)  ← aquí se fragmenta
  → GROUP BY (Material, Calibre_Espesor)
  → sugerencia compra (tramos 6/12 m o placas 4'×10' + 15% scrap)
```

**Nesting:** `POST /api/mrp/optimizar_uso_material` filtra además por `calibre_espesor` exacto; exacerba el problema si hay varios calibres para un material.

**Excel:** no exporta nesting; exporta filas tal cual salen de `mrp_calculado` (incluye duplicados por espesor).

---

## Otros endpoints

- `GET /api/mrp/revisiones` — solo `Estado = 'Aprobada'`
- `GET /api/mrp/calculate/{id_revision}` — `mrp_calculado`, `componentes_comerciales`, `piezas_sin_medidas`, `resumen_stock_mrp`
- `POST /api/mrp/optimizar_uso_material` — `fabricables`, `sobrestock`, `descartadas_por_medida`, nesting guillotina 2D

---

## Solución implementada — 2026-05-18 (build 354)

### Backend (`backend/routers/mrp.py`)

- **`_calibre_canonico(material)`** — nueva función que parsea el nombre del material contra tablas `_FRAC_TO_MM` (fracciones pulgada) y `_CAL_TO_MM` (calibres GA) y devuelve el espesor estándar en mm, p. ej. `"3.18 mm (1/8\")"`.
- **SQL reagrupado** — se eliminó `Espesor_Perfil_CAD` del `GROUP BY`. Ahora `AggPerCode` agrupa por `(material_oficial, Codigo_Pieza)`.
- **Consolidación Python** — loop `_piezas_por_mat` acumula piezas hijas por material; produce una fila por material con `"piezas": [...]` y `"Calibre_Espesor"` derivado del nombre.
- Stock y Brecha siguen sumando correctamente (≡ comportamiento anterior pero sin fragmentación).

### Frontend (`lib/screens/mrp_screen.dart`)

- `_expandedMaterials: Set<String>` para controlar qué materiales están expandidos.
- `_buildExpandableMPRow` — fila padre clicable con ícono chevron; fondo azul tenue cuando abierta.
- `_buildPiezaChildRow` — filas hija con código de pieza (`↳ código`), cantidad y área individual.
- `_buildHeaderRow` actualizado: columna "CALIBRE CANÓNICO" en lugar de "CALIBRE / ESPESOR".

### Excel (`_exportToExcel`)

- Fila **padre**: fondo azul oscuro (#1E3A8A), negrita — muestra material, calibre canónico, totales.
- Filas **hija**: fondo gris claro (#F0F4FF) con sangría `↳ código`, cantidad y área por pieza.

### Checklist (todos completados)

- [x] Implementar normalización en backend (no solo UI).
- [x] Ajustar nesting y filtros de calibre en Flutter.
- [x] Validar Excel y resumen stock/brecha tras consolidación.
- [x] Añadir línea en `assets/qa_version_notes.json` tras el fix.
