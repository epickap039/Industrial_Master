# Documentación Técnica v12.1 - Smart Homologator 🤖✨

## Introducción

La versión 12.1 introduce el **Smart Homologator**, un motor de inteligencia artificial (lógica difusa) diseñado para cerrar la brecha entre los datos "sucios" de ingeniería (Excel) y el Maestro de Materiales estandarizado (SQL).

## Arquitectura del Proceso

### 1. Detección de Conflictos

El sistema `SENTINEL` (en la base de datos) detecta automáticamente cuando una descripción en un archivo de Excel no coincide con lo que hay en el Maestro de Materiales. Estos se listan en `Tbl_Auditoria_Conflictos`.

### 2. Fase de Homologación (Limpieza de Excel)

En la sección **"Correcciones Pendientes"**, el sistema utiliza el algoritmo `difflib.SequenceMatcher` para comparar la descripción de Excel contra la `Tbl_Estandares_Materiales`.

- **Efecto:** Se sugiere el nombre estándar más probable.
- **Acción:** Al guardar la corrección, se actualiza el campo `Desc_Excel` en la tabla de auditoría y se marca como `CORREGIDO`.

### 3. Fase de Resolución (Actualización del Maestro)

Al entrar al **"Árbitro de Conflictos"**, el sistema ahora lee la descripción ya "limpia" (homologada en el paso anterior).

- **Acción:** Al presionar **"Aceptar Cambios"**, se actualiza la `Tbl_Maestro_Materiales` con la descripción estándar, logrando integridad total.

## Componentes Técnicos

- **Python Backend:** `get_match_suggestion` y `save_excel_correction` en `data_bridge.py`.
- **Flutter Frontend:** Integración de `FutureBuilder` con el motor de sugerencias en `main.dart`.
- **Base de Datos:** Actualización de estados en `Tbl_Auditoria_Conflictos`.

## Instrucciones para el Usuario

1. Abra **Correcciones Pendientes**.
2. Aplique las sugerencias de la **IA (Robot 🤖)**.
3. Vaya al **Árbitro de Conflictos** y acepte los cambios para impactar la base de datos maestra.
