# ARQUITECTURA TÉCNICA INDUSTRIAL MASTER

## 1. Conectividad SQL

- **Drivers:** NO hardcodear. Usar detección automática (Pref: 18 > 17).
- **Auth:** Soportar SQL Auth (User/Pass) y Windows Auth (Trusted).
- **Encryption:** Driver 18 requiere `TrustServerCertificate=yes`.

## 2. Gestión de Archivos Excel

- **Rutas:** Dinámicas. Se leen de `Tbl_Fuentes_Datos`.
- **Estructura:** Datos inician Fila 6. Cols: D(Codigo), E(Desc), F(Medida), H(Simetria), I-L(Procesos).
- **Escritura:** Usar `openpyxl`. Respetar CELDAS COMBINADAS (Escribir en Top-Left).

## 3. Lógica de Negocio

- **Homologación:** Priorizar `Tbl_Estandares_Materiales`.
- **Conflicto:** Si Excel != SQL, se marca conflicto en `Tbl_Auditoria_Conflictos`. NO sobrescribir SQL automáticamente.
