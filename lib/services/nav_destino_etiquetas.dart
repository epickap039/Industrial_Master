import 'nav_pane.dart';

/// Etiquetas alineadas con el texto visible en el shell ([main_layout]) para telemetría legible.
String etiquetaNavPane(NavPaneId id) {
  return switch (id) {
    NavPaneId.lobby => 'Lobby principal',
    NavPaneId.operacionHub => 'Operación diaria',
    NavPaneId.ingenieriaHub => 'Ingeniería y cambios',
    NavPaneId.seguimientoHub => 'Seguimiento e incidentes',
    NavPaneId.datosHub => 'Datos y catálogos',
    NavPaneId.catalogoMaestro => 'Catálogo maestro',
    NavPaneId.materialesOficiales => 'Materiales oficiales',
    NavPaneId.escanerCad => 'Escáner CAD',
    NavPaneId.importarExcel => 'Importar Excel',
    NavPaneId.auditorArchivos => 'Auditor de archivos',
    NavPaneId.estandarizacion => 'Estandarización',
    NavPaneId.gestionProyectos => 'Gestión de proyectos',
    NavPaneId.mapaIngenieria => 'Mapa de ingeniería',
    NavPaneId.expedientesVin => 'Expedientes VIN',
    NavPaneId.historialCambios => 'Historial de cambios',
    NavPaneId.ayudasVisuales => 'Ayudas visuales',
    NavPaneId.chatInterno => 'Chat interno',
    NavPaneId.dashboardAnalytics => 'Estadísticas',
    NavPaneId.centroQa => 'Centro de QA',
    NavPaneId.notasVersion => 'Notas de versión',
    NavPaneId.radarImpacto => 'Radar de impacto',
    NavPaneId.requerimientosMrp => 'Requerimientos (MRP)',
    NavPaneId.optimizarCorteMp => 'Optimizar corte MP',
    NavPaneId.generadorCodigo => 'Generador de Código',
    NavPaneId.centroMonitoreo => 'Centro de monitoreo',
  };
}

/// Nombres legibles para eventos de producto ([DevUsageFeatureIds]).
String etiquetaFeatureUso(String featureId) {
  final k = featureId.trim();
  return switch (k) {
    'catalogo_detalle_pieza' => 'Catálogo · detalle de pieza',
    'catalogo_stock_pt_huerfanos_consulta' => 'Catálogo · consulta stock huérfanos',
    'catalogo_stock_pt_sync_manual' => 'Catálogo · sync stock PT manual',
    'notificaciones_bandeja_abierta' => 'Notificaciones · bandeja',
    'monitoreo_pantalla_sesion' => 'Centro de monitoreo · sesión',
    _ => k.isEmpty ? '(evento)' : k,
  };
}
