# Industrial Master v13.1 - LIVE WRITER PRO

Este es el repositorio oficial del proyecto **Industrial Master**, una herramienta de gestión y auditoría industrial avanzada.

## Versión Actual: v13.1_LIVE_WRITER_PRO

Esta versión introduce la **Escritura Inteligente en Excel**, permitiendo correcciones directas sobre los archivos fuente.

### 🌟 Novedades V13.1 (Live Writer)

- **Escritura Directa en Archivos Excel:**
  - El sistema ahora abre, edita y guarda cambios directamente en los archivos `.xlsx` originales.
  - **Soporte de Celdas Combinadas (Merge):** Algoritmo inteligente que detecta rangos combinados y escribe en la celda correcta.
  - **Detección de Archivos en Uso:** Alerta si el archivo está abierto por otro usuario (Permission Lock).

- **Gestor de Rutas Dinámico (Path Manager):**
  - Nueva pestaña **"📍 Fuentes de Datos"** en el menú Sistema.
  - Permite "relocalizar" archivos si fueron movidos de carpeta.
  - Mapeo persistente de rutas para futuros accesos.

- **Integridad de Datos:**
  - Actualización simultánea: Se corrige el Excel y se marca el registro en SQL al mismo tiempo.

- **Ayuda Contextual Inteligente:**
  - Botones de ayuda (`?`) en cada módulo principal.
  - Guías rápidas sobre colores de estado y flujos de trabajo.
  - Manual de Usuario integrado y actualizado.

- **Feedback Visual Mejorado:**
  - Indicadores de carga (`ProgressRing`) en todos los botones de acción crítica.
  - Notificaciones flotantes (`InfoBar`) para confirmar éxito o reportar errores.
  - Manejo robusto de errores de red y base de datos con mensajes amigables.

- **Refinamiento Estético:**
  - Mejoras en el tema Oscuro/Claro con paletas de colores industriales (Slate/Cool Gray).
  - Efectos de glassmorfismo optimizados y consistentes.
  - Nueva organización del menú de navegación para un flujo de trabajo lógico.

### Características Principales Anteriores

- **Dashboard de Control:** Vista general de métricas clave.
- **Auditoría de Conflictos:** Herramienta para resolver discrepancias entre Excel y SQL.
- **Smart Detective Data:** Lógica avanzada de mapeo de datos SQL.
- **Búsqueda Automática de Planos:** Vinculación directa con archivos PDF/DWG en red.

### Requisitos

- Windows 10/11
- Conexión a Base de Datos SQL Server
- Archivos Excel de insumos

### Instalación

El proyecto incluye scripts de construcción automatizada en Python para generar instaladores `.exe`. Ejecute `python scripts/build_installer.py` para generar la carpeta de distribución.
