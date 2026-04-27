/// Roles de negocio (valor en `Tbl_Usuarios.rol` y `SharedPreferences` 'rol').
enum AppRole {
  administrador,
  desarrollador, // Rango superior con máximos permisos
  calidad,
  produccion,
  ingenieriaMetodos,
  gestion,
  compras,
  direccion,
  qaLegacy,
  userLegacy,
  otro,
}

AppRole parseAppRole(String? raw) {
  final s = (raw ?? '')
      .trim()
      .toUpperCase()
      .replaceAll('Á', 'A')
      .replaceAll('É', 'E')
      .replaceAll('Í', 'I')
      .replaceAll('Ó', 'O')
      .replaceAll('Ú', 'U');
  final normalized = s.replaceAll(RegExp(r'[^A-Z0-9]+'), ' ').trim();
  switch (s) {
    case 'ADMIN':
    case 'ADMINISTRADOR':
      return AppRole.administrador;
    case 'DESARROLLADOR':
    case 'DESAROLLADOR':
    case 'DESARROLLO':
    case 'DEVELOPER':
    case 'DEV':
    case 'PROGRAMADOR':
      return AppRole.desarrollador;
    case 'CALIDAD':
      return AppRole.calidad;
    case 'PRODUCCION':
    case 'PRODUCCIÓN':
      return AppRole.produccion;
    case 'INGENIERIA':
    case 'INGENIERIA_METODOS':
    case 'INGENIERÍA':
    case 'INGENIERIA METODOS':
    case 'METODOS':
    case 'METODOS DE INGENIERIA':
    case 'INGENIERIA DE METODOS':
      return AppRole.ingenieriaMetodos;
    case 'GESTION':
    case 'GESTIÓN':
      return AppRole.gestion;
    case 'COMPRAS':
      return AppRole.compras;
    case 'DIRECCION':
    case 'DIRECCIÓN':
      return AppRole.direccion;
    case 'QA':
      return AppRole.qaLegacy;
    case 'USER':
    case 'READONLY':
      return AppRole.userLegacy;
    default:
      // Fallback tolerante: algunos entornos guardan rol con sufijos/prefijos
      // (ej. "INGENIERIA IMV327", "ROL: DESARROLLADOR").
      if (normalized.contains('INGENIERIA') || normalized.contains('METODOS')) {
        return AppRole.ingenieriaMetodos;
      }
      if (normalized.contains('DESARROLLADOR') ||
          normalized.contains('DESAROLLADOR') ||
          normalized.contains('DESAR') ||
          normalized.contains('DESARROLLO') ||
          normalized.contains('DEVELOPER') ||
          normalized.contains('DEV') ||
          normalized.contains('PROGRAMADOR')) {
        return AppRole.desarrollador;
      }
      if (normalized.contains('ADMIN')) return AppRole.administrador;
      if (normalized.contains('CALIDAD')) return AppRole.calidad;
      if (normalized.contains('PRODUCCION')) return AppRole.produccion;
      return AppRole.otro;
  }
}

extension AppRoleAccess on AppRole {
  bool get showsNavLobby => switch (this) {
        AppRole.qaLegacy => false,
        _ => true,
      };

  /// Lobby con últimas piezas de catálogo y estadísticas de ayudas visuales por categoría.
  /// Solo **Calidad**, **Ingeniería / Métodos**, **Producción** y **Desarrollador** (incluye simulación admin).
  bool get showsLobbyOperativoAyudasCatalogo => switch (this) {
        AppRole.calidad => true,
        AppRole.ingenieriaMetodos => true,
        AppRole.produccion => true,
        AppRole.desarrollador => true,
        _ => false,
      };

  bool get showsNavCatalogo => switch (this) {
        AppRole.qaLegacy => true,
        AppRole.gestion => false,
        AppRole.direccion => false,
        AppRole.compras => true,
        AppRole.calidad => true,
        AppRole.produccion => true,
        _ => true,
      };

  /// Generador de código: no Producción ni Calidad (solo consulta catálogo / ayudas).
  bool get showsNavGeneradorCodigo =>
      showsNavCatalogo &&
      this != AppRole.produccion &&
      this != AppRole.calidad;

  bool get showsNavMateriales =>
      this != AppRole.qaLegacy && _fullEngineering;

  bool get showsNavCadScanner =>
      this != AppRole.qaLegacy && _fullEngineering;

  bool get showsNavImportarExcel =>
      this != AppRole.qaLegacy && _fullEngineering;

  /// Reconciliación BOM vs export CSV SolidWorks (solo Ingeniería / métodos y Desarrollador).
  bool get showsNavBomDespiece =>
      this == AppRole.desarrollador || this == AppRole.ingenieriaMetodos;

  bool get showsNavAuditor =>
      this != AppRole.qaLegacy && _fullEngineering;

  bool get showsNavEstandarizacion =>
      this != AppRole.qaLegacy && _fullEngineering;

  bool get showsNavGestionProyectos => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => false,
        AppRole.direccion => false,
        AppRole.compras => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavMapaIngenieria => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => true,
        AppRole.direccion => false,
        AppRole.compras => false,
        AppRole.calidad => true,
        AppRole.produccion => true,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavVin => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.direccion => true,
        AppRole.gestion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavHistorialCambios => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => true,
        AppRole.direccion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavAyudas => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => false,
        AppRole.direccion => false,
        AppRole.compras => false,
        AppRole.calidad => true,
        AppRole.produccion => true,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  /// Chat interno habilitado para Ingeniería, Ingeniería Métodos y Desarrollo.
  bool get showsNavChatInterno => _fullEngineering;

  bool get showsNavAnalytics => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.direccion => true,
        AppRole.gestion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavQa => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.direccion => false,
        AppRole.gestion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavRadar => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => true,
        AppRole.direccion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get showsNavMrp => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.compras => true,
        AppRole.gestion => false,
        AppRole.direccion => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  /// Optimización de corte avanzada (retacería/nesting ligero):
  /// visible solo para roles de ingeniería completos.
  bool get showsNavOptimizarCorteMp => _fullEngineering;

  bool get showsNavMonitoreo => switch (this) {
        AppRole.qaLegacy => false,
        AppRole.gestion => false,
        AppRole.direccion => false,
        AppRole.compras => false,
        AppRole.calidad => false,
        AppRole.produccion => false,
        _ => _fullEngineering || this == AppRole.userLegacy || this == AppRole.otro,
      };

  bool get _fullEngineering =>
      this == AppRole.administrador ||
      this == AppRole.desarrollador ||
      this == AppRole.ingenieriaMetodos;

  bool get catalogCanEditRows =>
      this == AppRole.administrador ||
      this == AppRole.desarrollador ||
      this == AppRole.ingenieriaMetodos;

  bool get catalogCanExportExcel => _fullEngineering;

  bool get catalogCanExportPdf => this == AppRole.calidad || _fullEngineering;

  bool get catalogCanSearchDxf => switch (this) {
        AppRole.produccion => false,
        AppRole.calidad => false,
        AppRole.qaLegacy => false,
        _ => true,
      };

  bool get catalogCanSelectColumns =>
      this != AppRole.produccion && this != AppRole.calidad;

  /// Stock físico PT (hoja inventario) y utilidades de sync: roles de ingeniería completos.
  bool get catalogShowsStockPtAlmacen => _fullEngineering;

  /// Visibilidad de controles de stock en catálogo (todos lo ven; no todos lo ejecutan).
  bool get catalogCanSeeStockPtActions => true;

  bool get catalogHideModificadoPor => this == AppRole.calidad;

  bool get catalogHideRutaArchivo => this == AppRole.calidad || this == AppRole.produccion;

  bool get catalogHideFechaModificacion => this == AppRole.produccion;

  bool get catalogHideDxfColumns => this == AppRole.produccion;

  /// Subir/borrar revisiones y demás mutaciones en Ayudas (API + UI).
  /// Solo **Administrador**, **Desarrollador** e **Ingeniería / métodos**; Calidad y Producción solo lectura.
  bool get ayudasCanUpload => switch (this) {
        AppRole.administrador => true,
        AppRole.desarrollador => true,
        AppRole.ingenieriaMetodos => true,
        _ => false,
      };

  /// Edición de icono/fondo de categoría en Ayudas (mismo criterio que [ayudasCanUpload]).
  bool get ayudasCanEditCategoryImage =>
      this == AppRole.desarrollador ||
      this == AppRole.ingenieriaMetodos ||
      this == AppRole.administrador;

  /// Timeline y revisiones anteriores del **mismo** documento.
  /// **Producción**: desactivado (solo revisión vigente + comparar otras ayudas vigentes).
  /// **Calidad**: sí puede consultar historial; no puede mutar (ver [ayudasCanUpload]).
  bool get ayudasShowRevisionHistory => this != AppRole.produccion;

  /// Barra «Comparar» / dual usando API de ayudas vigentes (p. ej. Producción sin historial).
  bool get ayudasAllowCrossDocumentCompare => showsNavAyudas;

  bool get monitoreoCanControlMisiones => _fullEngineering;

  bool get isAdminRail =>
      this == AppRole.administrador || this == AppRole.desarrollador;

  /// Pie del menú: entrada «Configuración» (ajustes del sistema). Sin Calidad ni Producción.
  bool get showsFooterConfiguracion =>
      this != AppRole.produccion && this != AppRole.calidad;
}

extension AppRoleAdmin on AppRole {
  bool get isAdmin =>
      this == AppRole.administrador || this == AppRole.desarrollador;

  /// Limpiezas destructivas (BD): historial QA, etc.
  bool get qaCanPurgeDb => this == AppRole.desarrollador;
}
