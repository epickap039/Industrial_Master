# Industrial Master v13.0 - USER CENTRIC

Este es el repositorio oficial del proyecto **Industrial Master**, una herramienta de gestión y auditoría industrial avanzada.

## Versión Actual: v13.0_USER_CENTRIC

Esta versión se centra en optimizar la experiencia del usuario (UX), mejorar la seguridad en la edición de datos y proporcionar ayuda contextual en tiempo real.

### 🌟 Novedades V13.0 (User Centric Update)

- **Edición Protegida en Catálogo Maestro:**
  - Sistema de cambios diferidos: edite múltiples celdas y guarde todo al final.
  - Indicadores visuales de "cambios pendientes" (celdas azules y contador global).
  - Protección de navegación: alerta si intenta salir con cambios sin guardar.

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
