import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

class UserAvatarService {
  UserAvatarService._();
  static final UserAvatarService instance = UserAvatarService._();

  static const String _kPrefsAvatarMap = 'user_avatar_map_v1';

  String _normUser(String username) => username.trim().toLowerCase();

  Future<Map<String, String>> _loadMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsAvatarMap);
      if (raw == null || raw.isEmpty) return <String, String>{};
      final decoded = json.decode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (k, v) => MapEntry(k.toString(), v == null ? '' : v.toString()),
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> _saveMap(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsAvatarMap, json.encode(map));
  }

  Uint8List? _decodeBase64(String b64) {
    try {
      if (b64.trim().isEmpty) return null;
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  String _encodeBase64(Uint8List bytes) => base64Encode(bytes);

  Future<Uint8List?> loadAvatarForUser(String username) async {
    final user = _normUser(username);
    if (user.isEmpty) return null;

    // 1) Cache local inmediato.
    final map = await _loadMap();
    final local = map[user];
    final localBytes = local == null ? null : _decodeBase64(local);
    if (localBytes != null) return localBytes;

    // 2) Intento backend opcional; fallback silencioso.
    try {
      final res = await ApiClient.getUnvalidated('/api/usuarios/$user/avatar');
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = res.decodeJsonLenient();
      if (decoded is! Map) return null;
      final b64 = '${decoded['avatar_base64'] ?? decoded['avatar'] ?? ''}'.trim();
      final bytes = _decodeBase64(b64);
      if (bytes == null) return null;
      map[user] = b64;
      await _saveMap(map);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAvatarForUser(String username, Uint8List bytes) async {
    final user = _normUser(username);
    if (user.isEmpty || bytes.isEmpty) return;
    final b64 = _encodeBase64(bytes);
    final map = await _loadMap();
    map[user] = b64;
    await _saveMap(map);

    // Intento backend no bloqueante para compatibilidad futura.
    try {
      await ApiClient.putUnvalidated(
        '/api/usuarios/$user/avatar',
        body: {'avatar_base64': b64},
      );
    } catch (_) {}
  }

  Future<void> removeAvatarForUser(String username) async {
    final user = _normUser(username);
    if (user.isEmpty) return;
    final map = await _loadMap();
    map.remove(user);
    await _saveMap(map);

    try {
      await ApiClient.deleteUnvalidated('/api/usuarios/$user/avatar');
    } catch (_) {}
  }

  /// Fuerza lectura desde backend y refresca caché local sin borrar avatar remoto.
  Future<Uint8List?> refreshAvatarFromServer(String username) async {
    final user = _normUser(username);
    if (user.isEmpty) return null;
    try {
      final res = await ApiClient.getUnvalidated('/api/usuarios/$user/avatar');
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = res.decodeJsonLenient();
      if (decoded is! Map) return null;
      final b64 = '${decoded['avatar_base64'] ?? decoded['avatar'] ?? ''}'.trim();
      final bytes = _decodeBase64(b64);
      if (bytes == null) return null;
      final map = await _loadMap();
      map[user] = b64;
      await _saveMap(map);
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
