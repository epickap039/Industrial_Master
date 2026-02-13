# 📘 DOCUMENTACIÓN MAESTRA DE RECUPERACIÓN - INDUSTRIAL MASTER (INTEGRITY SUITE)

**Versión:** 13.4 (STABLE_BOOT)
**Fecha:** 13/02/2026
**Propósito:** Guía definitiva para reconstruir, mantener y operar el sistema en caso de pérdida total de conocimiento o datos.

## 🚀 NOVEDADES v13.4_STABLE_BOOT (CRÍTICO)

- **Arranque Seguro:** La App ya no intenta conectarse si no hay configuración cargada, evitando el error `Login failed for user ''`.
- **Sincronización de Comandos:** Se reparó el comando `register_path` en el Backend para compatibilidad total con el Frontend.
- **Redirección de Configuración:** Si la conexión falla en el arranque, el sistema redirige automáticamente a la pantalla de Configuración en lugar de quedar en gris.

---

# 🏗️ 1. ARQUITECTURA TÉCNICA Y REGLAS DE ORO

Este sistema utiliza una arquitectura híbrida **Flutter (Frontend) + Python (Backend)**.

## 1.1 Reglas Inmutables (ARQUITECTURA_Y_REGLAS.md)

### Conectividad SQL

- **Drivers:** NO hardcodear. Usar detección automática (`get_best_driver()`: 18 > 17 > 13).
- **Auth:** Soportar SQL Auth (`UID/PWD`) y Windows Auth (`Trusted_Connection=yes`).
- **Encryption:** Driver 18 requiere `TrustServerCertificate=yes`.

### Gestión de Archivos Excel

- **Rutas:** Dinámicas. Se leen de la tabla `Tbl_Fuentes_Datos`.
- **Estructura Data:** Datos inician Fila 6. Cols: D(Codigo), E(Desc), F(Medida), H(Simetria), I-L(Procesos).
- **Lectura/Escritura:** Usar librería `openpyxl`.
- **Celdas Combinadas:** Al escribir correcciones, apuntar siempre a la celda Top-Left del rango.

### Lógica de Negocio

- **Homologación:** Priorizar descripciones estandarizadas (`Tbl_Estandares_Materiales`).
- **Conflicto:** Si Excel != SQL, se marca conflicto en `Tbl_Auditoria_Conflictos`. **NUNCA** sobrescribir el Maestro automáticamente si existe duda.

## 1.2 Flujo de Datos (Data Bridge)

`Usuario (UI Flutter)` ➡️ `JSON Payload` ➡️ `data_bridge.py (STDIN)` ➡️ `SQL Server` ➡️ `Respuesta JSON (STDOUT)` ➡️ `Flutter`

---

# 🛠️ 2. GUÍA DE RECONSTRUCCIÓN (DESDE CERO)

Si se pierde el entorno de desarrollo, siga estos pasos para restaurarlo.

## 2.1 Requisitos del Sistema

- **OS:** Windows 10/11 x64.
- **Python:** 3.10 o superior.
- **Flutter SDK:** Stable channel (v3.x).
- **SQL Server:** Express o Standard (2012+).
- **Drivers ODBC:** Instalar "ODBC Driver 17 for SQL Server".

## 2.2 Instalación de Dependencias Python

Ejecutar en terminal:

```bash
pip install pandas sqlalchemy pyodbc openpyxl pyinstaller
```

## 2.3 Estructura del Proyecto

El proyecto debe tener esta estructura de archivos mínima:

```
/industrial_manager
  /lib
    main.dart          (Punto de entrada, Navegación lateral)
    database_helper.dart (Puente con Python, busca data_bridge.exe)
    ... (Páginas: catalog_screen, sources_screen, etc.)
  /scripts
    data_bridge.py     (Lógica CORE del sistema)
    build_installer.py (Script de empaquetado)
    config.json        (Generado automáticamente, NO incluir en repo)
  /windows
    runner/            (Código nativo de Windows generado por Flutter)
  pubspec.yaml         (Dependencias de Dart: fluent_ui, file_picker, etc.)
```

## 2.4 Compilación del Backend (Python a EXE)

Para que el cliente funcione sin Python instalado:

```bash
pyinstaller --onefile --clean --distpath scripts/ --workpath build/ --specpath scripts/ --name data_bridge scripts/data_bridge.py
```

*Esto genera `scripts/data_bridge.exe`.*

## 2.5 Compilación del Frontend (Flutter)

```bash
flutter clean
flutter build windows --release
```

*El ejecutable final estará en `build/windows/x64/runner/Release/industrial_manager.exe`.*

## 2.6 Generación del Instalador

Usar el script automatizado que empaqueta todo:

```bash
python scripts/build_installer.py
```

*Generará una carpeta `INSTALADOR_JAES_vXX.X` lista para copiar al cliente.*

---

# 🗄️ 3. ESQUEMA DE BASE DE DATOS

El sistema intentará crear automáticamente estas estructuras si no existen (`ensure_v13_1_schema` en `data_bridge.py`).

## 3.1 Tbl_Fuentes_Datos (Nueva v13.1)

Rastrea los archivos Excel vinculados.

```sql
CREATE TABLE Tbl_Fuentes_Datos (
    ID INT IDENTITY(1,1) PRIMARY KEY,
    Nombre_Logico NVARCHAR(255),
    Ruta_Actual NVARCHAR(MAX),
    Ultima_Sincronizacion DATETIME,
    Estado NVARCHAR(50) DEFAULT 'ACTIVO'
)
```

## 3.2 Tbl_Maestro_Piezas (Core)

El catálogo oficial.

- `Codigo_Pieza` (PK, Varchar)
- `Descripcion`, `Material`
- `Simetria` (NVARCHAR 100) - *Agregado en v13.1*
- `Proceso_Primario`, `Procesos_Secundarios`

## 3.3 Tbl_Auditoria_Conflictos

Registro de discrepancias entre Excel y SQL.

- `Simetria_Excel` - *Agregado v13.1*
- `Proceso_Primario_Excel` - *Agregado v13.1*
- `Tipo_Conflicto` ('NUEVO', 'DATOS_DIFERENTES')

---

# 📘 4. MANUAL DE USUARIO UNIFICADO

## 4.1 Inicio y Conexión

1. Al abrir, verifique el semáforo de conexión.
2. Si falla, vaya a **Configuración** (Engrane).
3. Servidor: `PC08\SQLEXPRESS` (Ingeniería).
4. Auth: **Windows Auth** (Recomendado). Si falla, usar SQL Auth (`jaes_admin`).

## 4.2 Gestión de Archivos (Fuentes de Datos)

1. Vaya a la pestaña **Fuentes de Datos**.
2. **Agregar Fuente:** Seleccione el archivo Excel del proyecto.
3. **Sincronizar:** El sistema leerá el archivo.
   - Si la pieza es **NUEVA**, se agrega al Maestro.
   - Si la pieza **YA EXISTE**, se compara. Si hay diferencias ➡️ **Conflicto**.

## 4.3 Árbitro de Conflictos

Aquí llegan las diferencias detectadas.

- **Izquierda:** Verdad Oficial (BD).
- **Derecha:** Verdad del Archivo (Excel).
- **Acción:**
  - **Aceptar Excel:** Actualiza la BD con los datos del archivo.
  - **Ignorar:** Mantiene la BD tal cual.

## 4.4 Catálogo Maestro

- Busque piezas por código.
- Use el botón **PDF (Rojo)** para abrir el plano automáticamente.

---

# 🔧 5. SOLUCIÓN DE PROBLEMAS Y QA

## 5.1 Errores Comunes

| Síntoma | Causa Probable | Solución |
| :--- | :--- | :--- |
| **Login Failed / Untrusted Domain** | Red sin dominio usando Windows Auth. | Cambiar a **SQL Auth** en Configuración o instalar ODBC Driver de confianza. |
| **App Pantalla Blanca/Carga Infinita** | Backend no responde o BD caída. | Revisar si `data_bridge.exe` existe. Verificar servicio SQL Server en PC08. |
| **Excel no carga datos** | Formato incorrecto. | Asegurar que fila 4 tenga encabezados ("CÓDIGO", "DESCRIPCIÓN"). Fila de datos inicia en 6. |

## 5.2 Protocolo QA (Antes de liberar)

1. **Smoke Test:** Abrir app, navegar pestañas.
2. **Conexión:** Probar `Test Connection` en Configuración.
3. **Ingesta:** Cargar un Excel pequeño de prueba. Verificar que las piezas nuevas aparezcan.
4. **Conflicto:** Cambiar un dato en Excel de una pieza existente. Verificar que salte la alerta en Árbitro.

---

# 📎 6. ANEXOS

## 6.1 Macro VBA para Excel

Para consultar el maestro desde Excel directamente:

```vba
Sub ConsultarPieza()
    ' Requiere referencia ADODB
    conn.Open "Driver={SQL Server};Server=PC08\SQLEXPRESS;Database=DB_Materiales_Industrial;Trusted_Connection=yes;"
    sql = "SELECT Descripcion FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = '" & Range("A2").Value & "'"
    ' ... Ejecutar y pegar en celda
End Sub
```
