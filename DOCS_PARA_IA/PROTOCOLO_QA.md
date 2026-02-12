# PROTOCOLO DE REVISIÓN CRÍTICA (QA CHECKLIST) - INDUSTRIAL MASTER

Este documento establece los puntos mínimos de verificación antes de cada liberación de versión.

## 1. Prueba de Humo (Smoke Test)

- [ ] **Arranque:** ¿La aplicación inicia sin crasheos?
- [ ] **Identidad:** ¿Se muestra la pantalla "JAES" con la versión y fecha correctas?
- [ ] **Navegación:** ¿Funciona el cambio entre todas las pestañas laterales?

## 2. Integridad de Datos (Backend & STDIN)

- [ ] **Árbitro de Conflictos:** Ir a la pestaña Árbitro y pulsar "Resolver" en un ítem. ¿Abre el diálogo de comparación sin errores de "argument too long"?
- [ ] **Persistencia Catálogo:** Editar un campo en el Catálogo Maestro (ej. cambiar un Proceso), cerrar la app y volver a entrar. ¿El cambio persiste?
- [ ] **Logging:** Verificar que las acciones de actualización generen logs en la base de datos (según implementación en `data_bridge.py`).

## 3. Automatización & Red (File Handling)

- [ ] **Selección Dinámica:** ¿El botón "Buscar Carpeta" abre el diálogo de Windows y permite elegir rutas?
- [ ] **Rutas UNC (Red):** Intentar seleccionar una carpeta de red (ej. `\\Server\Proyectos\Excel`). Verificar que el script Python procesa los archivos sin problemas de permisos o caracteres.
- [ ] **Procesamiento Masivo:** Verificar que al terminar el escaneo se muestre el mensaje "--- PROCESO TERMINADO ---".

## 4. Ciclo de Vida de Conflictos

- [ ] **Resolución "Mantener Maestro":** Al ignorar un conflicto, verificar que desaparezca de la lista de Auditoría.
- [ ] **Historial:** Verificar que el ítem ignorado aparezca en la pestaña "Historial Resoluciones" con el estado **IGNORADO** y la fecha correcta.
- [ ] **Safe Nulls:** En el Historial, verificar que si un campo es nulo en la BD, se muestre como "N/A" o similar en lugar de romper la UI.

## 5. Visuales & UX

- [ ] **Modo Oscuro:** ¿El contraste es legible en todas las pantallas?
- [ ] **Manual:** Abrir el Manual de Usuario. ¿Los Tabs de ayuda muestran la información actualizada de la v6.1?
