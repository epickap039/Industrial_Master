import 'dart:convert';

/// Utilidades locales para inspeccionar el JWT de sesión sin validar la firma
/// (la verificación real es del servidor). Sirve para detectar tokens caducados
/// y forzar re-login, evitando llamadas que el backend rechazaría con 401.
class JwtUtils {
  JwtUtils._();

  /// Devuelve el payload decodificado, o `null` si no es un JWT legible.
  static Map<String, dynamic>? decodePayload(String? token) {
    final t = (token ?? '').trim();
    if (t.isEmpty) return null;
    final parts = t.split('.');
    if (parts.length != 3) return null;
    try {
      var seg = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (seg.length % 4) {
        case 2:
          seg += '==';
          break;
        case 3:
          seg += '=';
          break;
      }
      final decoded = utf8.decode(base64.decode(seg));
      final obj = json.decode(decoded);
      return obj is Map ? Map<String, dynamic>.from(obj) : null;
    } catch (_) {
      return null;
    }
  }

  /// `true` si el token no existe, es ilegible o su `exp` ya pasó.
  /// Un token sin `exp` se considera válido (no caducable).
  static bool isExpired(String? token) {
    final payload = decodePayload(token);
    if (payload == null) return true;
    final exp = payload['exp'];
    if (exp == null) return false;
    final expSec = exp is int ? exp : int.tryParse('$exp');
    if (expSec == null) return false;
    final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return nowSec >= expSec;
  }
}
