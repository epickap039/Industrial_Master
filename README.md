# Industrial Manager - Fase 1

Sistema integral de gestión, estandarización y trazabilidad de materiales y piezas industriales.

## Stack Tecnológico 🛠️
- **Frontend:** Flutter & Dart (Aplicación Desktop para Windows, UI/UX profesional basada en *fluent_ui*).
- **Backend:** Python con FastAPI (RESTful API de alto rendimiento).
- **Base de Datos:** Microsoft SQL Server (Base principal: `DB_Materiales_Industrial`).

---

## Módulos Completados en la Fase 1 🎯

### a) Catálogo Maestro de Piezas
- Visualización completa del catálogo de "Maestro de Piezas" en interfaz Desktop (WPF-like).
- Lectura en tiempo real de los datos estructurados provenientes dinámicamente de SQL Server.

### b) Estandarización de Datos
- Interfaz dedicada para limpieza y unificación de descripciones de materiales originados por OCR/Excel.
- Filtros inteligentes para separar materiales estandarizados de no estandarizados (ToggleSwitch).
- Función de "Estandarización Masiva", permitiendo corregir el nombre de múltiples agregados/piezas simultáneamente hacia un estándar oficial.

### c) Gestión de Materiales Oficiales
- Configuración de Regla Espejo para rellenar campos homólogos dependientes.
- **Añadir:** Inserción dinámica de nuevos estándares mediante el botón *"Hacer Oficial"*, el cual recarga la vista eliminando de manera automática las sugerencias pendientes visuales.
- **Eliminar:** Capacidad de borrar materiales del listado oficial a través de modales de confirmación e `IconButtons` destructivos, manteniendo seguro el catálogo final.

### d) Historial de Cambios Global
- Registro inmutable de toda acción (estandarización, carga masiva por Excel, updates manuales o inserciones).
- Capacidad del backend para registrar historiales complejos convirtiendo iterables/diccionarios a strings vía Parseo JSON seguro.
- Control de cambios estricto y UI comparativa para que usuarios/auditores rastreen la iteración de métricas o nomenclaturas entre Valor Anterior vs Valor Nuevo.

---

## Instrucciones de Ejecución 🚀

### 1. Levantar el Servidor (Backend API)
Asegúrate de configurar temporalmente tu IP local o `localhost` y tus credenciales de SQL Server en `server.py`. Una vez el `uvicorn` esté instalado, abre el entorno de Python y ejecuta el servidor:

```bash
# Entrar a la carpeta
cd backend

# Ejecutar script (Contiene auto-reload por uvicorn)
python server.py
```

### 2. Ejecutar la Aplicación (Frontend Flutter)
Abre otra terminal desde la misma ruta raíz de tu ambiente de Flutter y compila para Desktop:

```bash
# Compilar y correr en modo Debug para escritorio Windows
flutter run -d windows
```
Si es necesario y actualizaste dependencias, ejecuta `flutter clean` y `flutter pub get` primero. Ambos proyectos deben ejecutarse simultáneamente interactuando vía el puerto `8001` HTTP.
