# Guía Global del Sistema: Industrial Master (NotebookLM Edition)

Este documento sirve como fuente principal de verdad para el análisis del sistema Industrial Master. Resume la lógica de negocio, arquitectura y flujo de datos.

## 1. Propósito del Sistema

Industrial Master es un ecosistema híbrido diseñado para estandarizar la gestión de piezas en ingeniería industrial. Su objetivo es convertir "experiencia acumulada" en archivos Excel en un "Catálogo Maestro" centralizado y validado.

## 2. El Ciclo de Aprendizaje (Core Logic)

El sistema no solo guarda datos, **aprende** de ellos:

1. **Importación:** Al procesar carpetas de Excel, el script `carga_inicial.py` lee cada fila.
2. **Identificación:** Si un código de pieza no existe en el catálogo, se crea automáticamente como una "Nueva Verdad Ofical".
3. **Validación:** Si el código ya existe, el sistema registra su uso en el historial pero **audita** sus propiedades.
4. **Alerta de Conflictos:** Si un archivo nuevo dice que la pieza "X" es de "ACERO" pero el maestro dice "ALUMINIO", se genera un conflicto en la vista `V_Auditoria_Conflictos`.

## 3. Componentes Técnicos

- **Base de Datos (SQL Server):** Almacena el Maestro y el Historial de usos.
- **Backend (Python/Pandas):** Motor ETL que normaliza nombres de columnas (eliminando acentos) y limpia datos sucios de Excel.
- **Frontend (Flutter):** Interfaz para humanos que permite:
  - Editar el catálogo.
  - Resolver conflictos ("Hacer Oficial" un dato de archivo).
  - Listar materiales con auto-rellenado inteligente.

## 4. Consultas Externas (Macro Excel)

Se proporciona una integración vía VBA para que cualquier usuario de Excel en la red pueda consultar el Maestro de Piezas en tiempo real usando el `Codigo_Pieza`.

## 5. Glosario de Datos

- **Codigo_Pieza:** Identificador único (Primary Key).
- **Proceso_Primario:** El primer paso de fabricación (Laser, Sierra, etc.).
- **Simetria:** Indicador de si la pieza tiene un par espejo.
- **Hacer Oficial:** Acción de sobreescribir el catálogo maestro con datos nuevos validados desde un proyecto.
