# Log de Errores Resueltos - Industrial Master

## 1. Catálogo Maestro Vacío

- **Problema:** El usuario reportó que el catálogo no mostraba datos a pesar de haber ejecutado importaciones.
- **Causa Raíz:**
  1. Los archivos Excel originales contenían acentos en los encabezados (ej: "CÓDIGO"), lo que impedía que el script de Python identificara la columna correctamente en la primera versión.
  2. La falta de normalización Unicode en el mapeo de columnas causaba saltos silenciosos de filas.
- **Solución:**
  1. Se actualizó `carga_inicial.py` con una función de normalización que elimina acentos y pasa todo a mayúsculas antes del mapeo.
  2. Se añadió un log de validación al final del script de carga para confirmar el número de piezas en la base de datos.
  3. Se añadieron controladores de errores y estados de carga en la UI de Flutter para diagnosticar fallos en el puente de datos.

## 2. Errores de Tipado en SQL (Float vs Object)

- **Problema:** Fallos al insertar la columna "Cantidad" desde Excel a SQL Server.
- **Causa:** Algunos archivos Excel tenían texto ("-") o celdas vacías en campos numéricos.
- **Solución:** Implementación de limpieza con `clean_float` y manejo de excepciones en la conversión de tipos en Python.

## 3. Rutas de Scripts en Compilación

- **Problema:** La App no encontraba los scripts de Python al ejecutarse desde el binario `.exe`.
- **Solución:** Ajuste en `DatabaseHelper` para buscar la carpeta `scripts/` relativa al ejecutable en modo release y relativa a la raíz en modo debug.
