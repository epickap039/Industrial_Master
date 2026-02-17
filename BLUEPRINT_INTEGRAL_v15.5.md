# 🏗️ BLUEPRINT INTEGRAL v15.5 - INDUSTRIAL MANAGER

**Documento Maestro de Arquitectura y Despliegue**
**Estado:** VIVO / INAMOVIBLE
**Versión del Sistema:** v15.5 (Release Industrial)
**Última Actualización:** 16 Febrero 2026

---

## 1. 🛡️ INFRAESTRUCTURA Y SEGURIDAD (El Entorno)

Definiciones estrictas del entorno de despliegue en Planta/Ingeniería.

* **Servidor de Base de Datos:**
  * **IP:** 192.168.1.73
  * **Puerto:** 1433 (TCP)
  * **Driver:** ODBC Driver 17 for SQL Server
  * **Credenciales:** Autenticación de Windows (`Trusted_Connection=yes`).
* **Backend (API Local):**
  * **Tecnología:** Python (FastAPI + Uvicorn).
  * **Puerto:** 8001.
  * **Bind:** `0.0.0.0` (Escuchar en todas las interfaces de red).
* **Red y Firewall (Fortinet):**
  * Reglas de Salida: Permitir tráfico TCP/1433 hacia 192.168.1.73.
  * Reglas Locales: Permitir tráfico TCP/8001 (Inbound/Outbound) para la API.
* **Entorno Python:**
  * **OBLIGATORIO:** Uso de `.venv` en la carpeta raíz para aislar dependencias (`pyodbc`, `pandas`).
  * **Evitar:** Instalaciones globales que causen `ModuleNotFoundError` en despliegues limpios.
* **Resolución de Nombres:**
  * La App Flutter debe apuntar explícitamente a `http://127.0.0.1:8001` para evitar conflictos de resolución DNS donde `localhost` se resuelva como IPv6 (`::1`), lo cual el servidor Python podría no estar escuchando por defecto.

---

## 2. 📓 BITÁCORA DE ERRORES CRÍTICOS (Lecciones Aprendidas)

Historia de fallos técnicos y sus soluciones definitivas. **NO REPETIR ESTOS ERRORES.**

| ERROR CRÍTICO | CAUSA TÉCNICA | SOLUCIÓN IMPLEMENTADA |
| :--- | :--- | :--- |
| **Procesos Zombis** | `uvicorn` o `flutter` quedan corriendo en segundo plano tras cerrar la ventana, bloqueando el puerto 8001 para la siguiente ejecución. | 1. Implementar `lifespan` en FastAPI (`server.py`).<br>2. Ejecutar `MATAR_TODO.bat` (`taskkill /F`) antes de compilar o iniciar. |
| **Fallo de Despliegue** | `Copy-Item` de PowerShell falla con rutas largas (>260 caracteres) o archivos bloqueados. | Reemplazar lógica de copiado por **`ROBOCOPY`** en los scripts `.bat`. Es nativo y robusto. |
| **Pérdida de UI (Ruta)** | Uso de `TextField` simples en lugar de selectores nativos, degradando la UX. | **Nunca** eliminar la dependencia `file_picker`. La selección de carpetas (Excel/Imágenes) debe ser nativa del SO. |
| **Conexión SQL Nula** | Bloqueo por SSL/TLS en red interna. | Cadena de conexión debe incluir `TrustServerCertificate=yes` y `Trusted_Connection=yes`. |

---

## 3. 🖥️ DISEÑO DETALLADO DE PESTAÑAS (Funcionalidad)

Especificaciones funcionales por módulo.

### A. DASHBOARD (Inicio)

* **Indicadores:** Estado del Servidor Local (Online/Offline) y Estado de Conexión SQL (Verde/Rojo).
* **Accesos Rápidos:** Botones grandes a Catálogo, Planos y Configuración.

### B. CATÁLOGO MAESTRO (SQL)

* **Fuente:** `SELECT * FROM Tbl_Maestro_Piezas`
* **Columnas Mapeadas:**
  * `Codigo_Pieza` -> `Codigo_Pieza`
  * `Descripcion` -> `Descripcion`
  * `Medida` -> `Medida`
  * `Material` -> `Material`
* **Tratamiento de Datos:**
  * Nulos SQL (`NULL`) deben transformarse a `"-"` o `""` (String vacío) en el Backend antes de enviar el JSON a Flutter para evitar crashes.

### C. VISOR DE PLANOS

* **Lógica:** Al seleccionar un ítem en el Catálogo:
    1. Tomar `Codigo_Pieza`.
    2. Buscar en la carpeta local configurada (`images_path`).
    3. Coincidencia: Archivos que empiecen con el código (ej: `JA-100.pdf`, `JA-100.jpg`).
    4. Abrir con el visor predeterminado del sistema (`url_launcher`).

### D. EDITOR DE EXCEL (Listas)

* **Ruta:** `Z:\Ingenieria\Listas` (Configurable).
* **Tecnología:** `pandas` + `openpyxl`.
* **Seguridad:** Lectura en modo *readonly* para no bloquear el archivo a otros usuarios de la red. Escritura atómica (copia temporal -> escritura -> reemplazo).

### E. EDITOR DE BASE DE DATOS (CRUD)

* **Permisos:** Usuario Admin (Windows Auth).
* **Funciones:** Insertar nuevo material, Editar descripción/medida.
* **Validación:** Backend debe verificar duplicados de `Codigo` antes de insertar.

---

## 4. 🎨 ESTÁNDARES VISUALES Y UX

* **Estilo:** `fluent_ui` (Diseño Nativo Windows 11).
* **Tema:**
  * Soporte para Claro/Oscuro.
  * Persistencia automática en `SharedPreferences`.
* **Feedback de Usuario:**
  * **Loaders:** Obligatorio mostrar `ProgressRing` o `ProgressBar` en cualquier operación asíncrona (Consulta SQL, Guardado, Carga de Archivo).
  * **SnackBars/InfoBars:** Confirmación visual de éxito ("Guardado correctamente") o error ("Sin conexión").

---

## 5. 🏗️ PROTOCOLO DE CONSTRUCCIÓN LIMPIA

Procedimiento estándar para generar una versión de producción (`Release`).

1. **Limpieza Previa:**
    * Ejecutar `MATAR_TODO.bat` para liberar archivos y puertos.
    * Borrar carpetas `build/` y `versiones/v15.5_Release` antiguas.
2. **Compilación:**
    * `flutter build windows` (Release).
    * `flutter build web` (Release, base href `/`).
3. **Empaquetado (Script):**
    * Usar `ROBOCOPY` para mover binarios a `versiones/v15.5_Release`.
    * Copiar `backend/` (código fuente server) y `requirements.txt`.
    * Copiar scripts `.bat` auxiliares (`iniciar_servidor.bat`, `MATAR_TODO.bat`).
4. **Entrega:**
    * La carpeta `v15.5_Release` es el único entregable válido para el cliente.

---
**FIN DEL BLUEPRINT**
Cualquier código nuevo debe adherirse a estas directrices.
