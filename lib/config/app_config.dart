/// ─────────────────────────────────────────────────────────────────────────
/// CONFIGURACIÓN GLOBAL DE LA APLICACIÓN
/// ─────────────────────────────────────────────────────────────────────────
/// Parametrizable con:
/// flutter run/build --dart-define=API_BASE_URL=http://IP:8001
/// ─────────────────────────────────────────────────────────────────────────
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://192.168.1.73:8001',
);
