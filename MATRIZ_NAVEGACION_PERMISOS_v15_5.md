# Matriz de navegacion y permisos v15.5

Base: revision del codigo actual en `main_layout.dart`, `services/nav_pane.dart`, `services/app_role.dart` y pantallas de `lib/screens/*`.

## 1) Inventario de paginas existentes y funcion

## Shell / acceso
- `SplashScreen`: valida sesion y redirige a login o main.
- `LoginScreen`: autenticacion y guardado de sesion (`rol`, `username`, token).
- `NavigationView` principal: menu lateral + appbar + notificaciones + estado red.

## Modulos navegables desde menu lateral
- `LobbyScreen`: tablero inicial por rol, KPIs y accesos rapidos.
- `CatalogScreen` (Catalogo Maestro): consulta de piezas, filtros, columnas, enlace a plano/drive, acciones por rol.
- `MaterialsListScreen`: catalogo de materiales oficiales (alta/edicion en modulo).
- `CADScannerScreen`: flujo de escaneo CAD y utilidades de carga/procesamiento.
- `ArbitrationScreen` (Importar Excel): conciliacion y arbitraje de cambios de Excel/BOM.
- `AuditorScreen`: auditoria/autocorreccion de archivos Excel.
- `StandardizationScreen`: reglas de estandarizacion de datos/estructura.
- `ProjectManagementScreen`: alta/edicion de tractos, tipos, versiones, clientes.
- `EngineeringMapScreen` (Mapa de Ingenieria): jerarquia tracto/tipo/version/revision y entrada a BOM.
- `VINDossierScreen`: consulta VIN, notas y archivos asociados.
- `HistoryScreen`: historial de cambios con busqueda y exportaciones.
- `AyudasVisualesNav`:
  - `AyudasMenuScreen`: categorias + buscador global de PDF.
  - `AyudasCategoriaScreen`: lista por categoria.
  - `AyudasVisorScreen`: visor PDF y revisiones.
- `AnalyticsScreen`: estadisticas globales/revision (graficas).
- `QADashboardScreen`: gestion y export de reportes QA.
- `ImpactRadarScreen` (Radar de Impacto): evaluacion de impacto y asignacion de tarea.
- `MRPScreen`: calculo MRP y exportacion.
- `MonitoreoTareasScreen`: centro de monitoreo de misiones (activas/historial/calendario, voz).

## Modulos en footer del menu
- `SettingsScreen`: diagnostico conexion, sincronizacion y configuracion local.
- `ConfiguracionUsuariosScreen`: alta/baja/listado de usuarios (admin rail).
- Acciones: selector de tema, reportar bug.

## Flujo relacionado clave (fuera del lateral)
- `BOMManagerScreen`: gestion de revisiones BOM, ECR, arbol de ensambles y operaciones de ingenieria.

---

## 2) Estructura propuesta del nuevo menu lateral (por funcionamiento)

- `Inicio`
- `Operacion diaria`
- `Ingenieria y cambios`
- `Seguimiento e incidentes` (renombrado solicitado)
- `Datos y catalogos`
- `Mapa de Ingenieria` (entrada visible de primer nivel)
- `Administracion` (solo ingenieria/desarrollador/admin)

Notas UX:
- Maximo 6-7 items visibles por bloque.
- Subitems colapsables.
- En tablet: modo compacto + tooltip.
- Bloque "Recientes/Favoritos" opcional en parte superior.

---

## 3) Matriz objetivo por rol (pantalla y permiso)

Leyenda:
- `V`: ver/consultar.
- `V+R`: ver con acciones de consulta rapida (buscar, filtros, abrir enlaces).
- `E`: editar/crear/eliminar/cargar.
- `X`: no visible.

## Produccion
- Inicio: `V`
- Operacion diaria:
  - Centro de Monitoreo: `X` (operacion actual de monitoreo es para roles de control)
  - Misiones/calendario: `X` por menu (consulta puede quedar desde lobby/resumen si se requiere)
- Ingenieria y cambios:
  - Radar de Impacto: `X`
  - Gestion proyectos: `X`
  - VIN: `X`
- Mapa de Ingenieria: `V` (solo lectura, requerido para entender version/lista)
- Seguimiento e incidentes: `V` (solo consulta de incidencias propias si aplica)
- Datos y catalogos:
  - Ayudas visuales: `V+R` (buscar/abrir rapido, sin subir ni editar)
  - Catalogo maestro: `V+R` con columnas privadas ocultas
- Administracion: `X`

Restricciones explicitas Produccion:
- Sin editar en catalogo.
- Sin seleccionar columnas.
- Sin exportar Excel.
- Sin buscar DXF.
- Sin ver columnas privadas (`Ruta_Archivo`, `Ruta_Plano/Link/Ruta`, `Modificado_Por`, `Tiene_DXF`, `Largo_DXF`, `Ancho_DXF`).
- Ayudas visuales: solo consulta; sin subida; sin historial de revision editable.

## Calidad
- Inicio: `V`
- Operacion diaria: `V` de seguimiento (sin control operativo de misiones)
- Ingenieria y cambios: `X` para modulos de edicion tecnica
- Mapa de Ingenieria: `V` (solo lectura, solicitado)
- Seguimiento e incidentes: `V+R`
- Datos y catalogos:
  - Catalogo maestro: `V+R` (ver procesos y abrir hipervinculo de plano/drive)
  - Ayudas visuales: `V+R`
- Administracion: `X`

Restricciones explicitas Calidad:
- Sin editar/eliminar piezas.
- Sin ver columnas privadas de ruta/autor.
- Puede consultar planos por hipervinculo.
- Puede exportar reporte de catalogo sin columnas privadas (ver nota tecnica abajo).

## Ingenieria / Metodos
- Inicio: `V`
- Operacion diaria: `V+R`
- Ingenieria y cambios: `V+E` (Radar, CAD, proyectos, VIN, historial, BOM)
- Mapa de Ingenieria: `V+E` (flujo completo)
- Seguimiento e incidentes: `V+E`
- Datos y catalogos: `V+E` (catalogo, ayudas, analytics)
- Administracion: `V` (settings; usuarios solo admin/desarrollador)

## Desarrollador
- Acceso total `V+E` en todos los modulos (incluye administracion y usuarios).

## Administrador (si se mantiene separado de desarrollador)
- Equivalente funcional a Ingenieria, con panel de usuarios y simulacion de roles.

---

## 4) Regla de permisos transversales (objetivo final)

- Solo `Ingenieria/Metodos` y `Desarrollador`:
  - editar, subir, bajar, importar, exportar (global).
- Excepcion solicitada:
  - `Calidad` puede exportar salida del Catalogo sin columnas privadas.
- `Produccion`:
  - foco en consumo rapido de ayudas visuales y consulta puntual de catalogo/plano.

---

## 5) Validacion tecnica puntual: exportacion de Calidad en Catalogo

Hallazgo actual en codigo:
- `CatalogScreen` ahora expone exportaciones separadas:
  - Excel por `catalogCanExportExcel` (solo ingenieria/metodos, admin, desarrollador).
  - PDF por `catalogCanExportPdf` (incluye Calidad).
- La exportacion PDF del catalogo ya se implemento en pantalla y respeta columnas filtradas por rol.
- Las columnas exportadas se filtran por visibilidad y exclusiones de rol; por lo tanto Calidad exporta sin columnas privadas.

Implicacion:
- Requisito de Calidad para exportar PDF del catalogo ya queda cubierto.

---

## 6) Cambios de implementacion recomendados para alinear con esta matriz

1. Reorganizar `_buildNavItems` en secciones nuevas:
   - `Operacion diaria`, `Ingenieria y cambios`, `Seguimiento e incidentes`, `Datos y catalogos`.
2. Ajustar `AppRoleAccess`:
   - Habilitar `showsNavMapaIngenieria` para `calidad` y `produccion` en solo lectura.
   - Revisar visibilidad de modulos no operativos para `produccion` y `calidad`.
3. Catalogo:
   - Consolidar ocultamiento de columnas privadas para `calidad` y `produccion`.
   - Mantener `catalogCanEditRows = false` para ambos.
4. Ayudas visuales:
   - `canUpload = false` para `calidad`/`produccion`.
   - `allowRevisionHistory = false` para `produccion` (ya aplicado en arquitectura).
5. Si se confirma necesidad de PDF real:
   - agregar boton `Exportar PDF` en `CatalogScreen` para `calidad`, `ingenieria`, `desarrollador`.

