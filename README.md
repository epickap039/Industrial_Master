# Industrial Master v14.1 - PERFORMANCE & STABILITY

Este es el repositorio oficial del proyecto **Industrial Master**, una herramienta de gestión y auditoría industrial avanzada.

## Versión Actual: v14.1_PERFORMANCE

Esta versión se centra en la estabilidad crítica del sistema backend y la experiencia de usuario fluda.

### 🚀 Novedades V14.1 (Performance Update)

- **Optimización Crítica del Data Bridge:**
  - **Suicide Protocol:** El backend Python ahora se autodestruye si pierde conexión con la interfaz Flutter, eliminando procesos "zombies".
  - **Uso de Recursos:** Implementación de `sleep` en bucles infinitos para reducir el uso de CPU de 30% a <1%.
  - **Gestión de Logs:** Prevención de desbordamiento de disco mediante control de errores repetivos.

- **Nueva Interfaz "Workflow":**
  - Pantalla de inicio rediseñada con un flujo visual de procesos (Fuentes -> Corrección -> Validación -> Catálogo).
  - Tarjetas interactivas con indicadores visuales de estado.
  - Diseño responsivo mediante `LayoutBuilder` para adaptarse a diferentes resoluciones.

- **Configuración Refinada:**
  - Nueva pantalla **Server Config Glass** con diseño moderno traslúcido.
  - Validación de conexión SQL más robusta con timeouts ajustados (15s) para redes lentas.
  - Indicadores de estado de carga independientes para "Guardar" y "Conectar".

### 🌟 Características Principales (Live Writer Pro)

- **Escritura Directa en Archivos Excel:**
  - Edición y guardado directo en archivos `.xlsx` originales.
  - Algoritmo inteligente para celdas combinadas.
  - Bloqueo de permisos para archivos en uso.

- **Gestor de Rutas Dinámico:**
  - Relocalización de fuentes de datos movidas.
  - Persistencia de rutas.

- **Integridad de Datos:**
  - Sincronización atómica entre Excel y SQL.

### Requisitos

- Windows 10/11
- Conexión a Base de Datos SQL Server (ODBC Driver 17/18 recommended)
- Python 3.x (para desarrollo/construcción)
- Dart/Flutter SDK

### Instalación y Construcción

El proyecto incluye scripts de automatización para generar el instalador portátil.

1. **Construir Backend:**

    ```bash
    pyinstaller scripts/data_bridge.py --onefile
    ```

2. **Construir Instalador Completo:**
    Ejecute el script de construcción para empaquetar todo (Flutter + Python + DLLs):

    ```bash
    python scripts/build_installer.py
    ```

    Esto generará la carpeta `INSTALADOR_JAES_v14.1_PERFORMANCE` lista para distribuir.
