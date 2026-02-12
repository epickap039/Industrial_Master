# MANUAL DE USUARIO 2.0 - INDUSTRIAL MASTER

Este manual proporciona una guía paso a paso para el uso correcto de la aplicación de gestión de materiales e ingeniería.

## 1. Inicio Rápido: Conexión al Servidor

Al abrir la aplicación por primera vez, o si la conexión falla:

1. Diríjase a la pestaña **Configuración** en el menú lateral.
2. Ingrese el nombre del servidor: `PC08\SQLEXPRESS`.
3. Seleccione la carpeta de red para los planos (Z:\...).
4. Pulse **Guardar Configuración** y luego **Probar Conexión**.

## 2. Automatización: Carga de Datos desde Excel

Para importar nuevos proyectos o actualizaciones:

1. Vaya a la pestaña **Automatización Masiva**.
2. Pulse **Seleccionar Carpeta** para elegir dónde se encuentran los archivos Excel del proyecto.
3. Pulse **Iniciar Proceso de Carga**.
4. Observe la consola de logs. Si hay discrepancias con la base de datos oficial, las piezas aparecerán en el **Árbitro de Conflictos**.

## 3. Árbitro de Conflictos (Smart UI)

Cuando un Excel tiene datos distintos a la base de datos oficial, el sistema le pedirá que actúe como "Árbitro".

### Guía de Colores y Símbolos

- **NARANJA (Ambar) + Icono ⚠️:** Indica que hay un cambio detectado. La base de datos oficial dice una cosa, pero el Excel propone otra.
- **GRIS / TENUE:** Indica que los datos son idénticos o no hay conflicto.
- **CAMPOS OCULTOS:** Si un campo (como P.1 o P.2) está vacío en ambos lados, el sistema lo oculta para limpiar la interfaz.

### Toma de Decisiones

1. **✅ ACEPTAR CAMBIO (Botón Azul):** Use este si la información del Excel es la más reciente y desea actualizar la base de datos oficial.
2. **❌ IGNORAR (Botón Gris):** Use este si desea conservar la información original de la base de datos y descartar la propuesta del Excel.

## 4. Catálogo Maestro: Búsqueda Turbo de Planos

En la pestaña **Catálogo**, puede gestionar las piezas y sus planos:

- **Botón PDF (Rojo):** Realiza una búsqueda Turbo en el servidor para encontrar el plano `.pdf` y abrirlo.
- **Botón Carpeta (Amarillo):** Abre la carpeta contenedora en el servidor `Z:` para ver otros archivos del proyecto.
- **Materia Prima:** Si el sistema detecta números en la medida (ej: 1/2"), le advertirá antes de buscar, ya que las materias primas no suelen tener planos individuales.

## 5. Mantenimiento y Logs

- **Historial de Resoluciones:** Consulte qué decisiones se tomaron en el pasado.
- **Saneamiento:** Si ve datos inconsistentes, un administrador puede ejecutar `fix_history.py` para limpiar estados nulos.
