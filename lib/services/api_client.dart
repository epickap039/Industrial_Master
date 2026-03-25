import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Respuesta HTTP sin validar status (para flujos que tratan 4xx manualmente).
class ApiHttpResult {
  ApiHttpResult(this.statusCode, this.rawBody);

  final int statusCode;
  final String rawBody;

  /// `null` si el cuerpo está vacío; mismo resultado que [json.decode] en caso contrario.
  dynamic decodeJson() {
    if (rawBody.isEmpty) return null;
    return json.decode(rawBody);
  }

  /// Como [decodeJson], pero ante JSON inválido devuelve `null` (no lanza).
  dynamic decodeJsonLenient() {
    if (rawBody.isEmpty) return null;
    try {
      return json.decode(rawBody);
    } catch (_) {
      return null;
    }
  }
}

/// Error de API con código HTTP y mensaje legible.
class ApiException implements Exception {
  ApiException(this.statusCode, this.rawBody, this.message);

  final int statusCode;
  final String rawBody;
  final String message;

  @override
  String toString() => message;
}

/// Cliente HTTP centralizado sobre [kApiBaseUrl].
class ApiClient {
  ApiClient._();

  static String get _base {
    final u = kApiBaseUrl;
    return u.endsWith('/') ? u.substring(0, u.length - 1) : u;
  }

  static Uri uri(String path, [Map<String, String>? queryParameters]) {
    final p = path.startsWith('/') ? path : '/$path';
    final u = Uri.parse('$_base$p');
    if (queryParameters == null || queryParameters.isEmpty) return u;
    return u.replace(
      queryParameters: {...u.queryParameters, ...queryParameters},
    );
  }

  static Map<String, String> _jsonHeaders({Map<String, String>? extra}) {
    return {
      'Content-Type': 'application/json',
      ...?extra,
    };
  }

  /// Añade `Authorization: Bearer …` si hay token guardado tras el login.
  static Future<Map<String, String>> _withAuth(Map<String, String>? headers) async {
    final out = <String, String>{...?headers};
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = prefs.getString('access_token');
      if (t != null && t.isNotEmpty) {
        out.putIfAbsent('Authorization', () => 'Bearer $t');
      }
    } catch (_) {}
    return out;
  }

  static String _messageFromErrorBody(String body) {
    if (body.isEmpty) return 'Solicitud rechazada por el servidor';
    try {
      final j = json.decode(body);
      if (j is Map) {
        if (j['detail'] != null) return j['detail'].toString();
        if (j['message'] != null) return j['message'].toString();
      }
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  static void _ensureSuccess(http.Response response) {
    final c = response.statusCode;
    if (c >= 200 && c < 300) return;
    final msg = _messageFromErrorBody(response.body);
    throw ApiException(
      c,
      response.body,
      c >= 500
          ? 'Error del servidor ($c): $msg'
          : 'Error en la petición ($c): $msg',
    );
  }

  static dynamic _decodeSuccessBody(http.Response response) {
    _ensureSuccess(response);
    if (response.body.isEmpty) return null;
    return json.decode(response.body);
  }

  /// GET que exige 2xx y devuelve el JSON decodificado (lista, mapa, etc.).
  /// No envía `Content-Type` por defecto (mismo comportamiento que [http.get] sin headers).
  static Future<dynamic> get(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async {
    final r = await http.get(
      uri(path, queryParameters),
      headers: await _withAuth(headers),
    );
    return _decodeSuccessBody(r);
  }

  /// GET sin lanzar por status; útil cuando el caller distingue 200 vs 4xx con el mismo JSON.
  static Future<ApiHttpResult> getUnvalidated(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    Future<http.Response> future = http.get(
      uri(path, queryParameters),
      headers: await _withAuth(headers),
    );
    final r =
        timeout != null ? await future.timeout(timeout) : await future;
    return ApiHttpResult(r.statusCode, r.body);
  }

  /// POST sin validar status. Con [body] no nulo añade `Content-Type: application/json`.
  static Future<ApiHttpResult> postUnvalidated(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final Map<String, String> h = {
      if (body != null) 'Content-Type': 'application/json',
      ...await _withAuth(headers),
    };
    final r = await http.post(
      uri(path, queryParameters),
      headers: h.isEmpty ? null : h,
      body: body == null ? null : json.encode(body),
    );
    return ApiHttpResult(r.statusCode, r.body);
  }

  /// PUT sin validar status.
  static Future<ApiHttpResult> putUnvalidated(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final Map<String, String> h = {
      if (body != null) 'Content-Type': 'application/json',
      ...await _withAuth(headers),
    };
    final r = await http.put(
      uri(path, queryParameters),
      headers: h.isEmpty ? null : h,
      body: body == null ? null : json.encode(body),
    );
    return ApiHttpResult(r.statusCode, r.body);
  }

  /// DELETE sin validar status (p. ej. borrado con body JSON y 401).
  static Future<ApiHttpResult> deleteUnvalidated(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final Map<String, String> h = {
      if (body != null) 'Content-Type': 'application/json',
      ...await _withAuth(headers),
    };
    final r = await http.delete(
      uri(path, queryParameters),
      headers: h.isEmpty ? null : h,
      body: body == null ? null : json.encode(body),
    );
    return ApiHttpResult(r.statusCode, r.body);
  }

  /// GET binario (2xx); exportaciones Excel, etc.
  static Future<Uint8List> getBytes(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    Future<http.Response> future = http.get(
      uri(path, queryParameters),
      headers: await _withAuth(headers),
    );
    final r =
        timeout != null ? await future.timeout(timeout) : await future;
    _ensureSuccess(r);
    return r.bodyBytes;
  }

  /// POST JSON; cuerpo se codifica con [json.encode]. Respuesta decodificada si hay cuerpo.
  static Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final r = await http.post(
      uri(path, queryParameters),
      headers: {...await _withAuth(null), ..._jsonHeaders(), ...?headers},
      body: body == null ? null : json.encode(body),
    );
    return _decodeSuccessBody(r);
  }

  /// POST JSON; cuerpo de éxito binario (p. ej. Excel generado desde JSON).
  static Future<Uint8List> postBytes(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final r = await http.post(
      uri(path, queryParameters),
      headers: {...await _withAuth(null), ..._jsonHeaders(), ...?headers},
      body: body == null ? null : json.encode(body),
    );
    _ensureSuccess(r);
    return r.bodyBytes;
  }

  /// PUT JSON si hay [body]; sin cuerpo no fuerza `Content-Type` (p. ej. aprobar revisión).
  static Future<dynamic> put(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final Map<String, String> h = {
      if (body != null) ..._jsonHeaders(),
      ...await _withAuth(headers),
    };
    final r = await http.put(
      uri(path, queryParameters),
      headers: h.isEmpty ? null : h,
      body: body == null ? null : json.encode(body),
    );
    return _decodeSuccessBody(r);
  }

  /// DELETE; si el cuerpo viene vacío en 2xx, devuelve `null`.
  /// Sin headers por defecto (igual que [http.delete] simple).
  static Future<dynamic> delete(
    String path, {
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final r = await http.delete(
      uri(path, queryParameters),
      headers: await _withAuth(headers),
    );
    return _decodeSuccessBody(r);
  }

  /// POST multipart (campos + archivos). Respuesta JSON en 2xx como en los demás métodos.
  static Future<dynamic> postMultipart(
    String path, {
    Map<String, String> fields = const {},
    Map<String, http.MultipartFile> files = const {},
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final request = http.MultipartRequest('POST', uri(path, queryParameters));
    request.fields.addAll(fields);
    for (final e in files.entries) {
      request.files.add(e.value);
    }
    request.headers.addAll(await _withAuth(headers));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    return _decodeSuccessBody(response);
  }

  /// POST multipart cuyo cuerpo de éxito es binario (p. ej. Excel), no JSON.
  static Future<Uint8List> postMultipartBytes(
    String path, {
    Map<String, String> fields = const {},
    Map<String, http.MultipartFile> files = const {},
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final request = http.MultipartRequest('POST', uri(path, queryParameters));
    request.fields.addAll(fields);
    for (final e in files.entries) {
      request.files.add(e.value);
    }
    request.headers.addAll(await _withAuth(headers));
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    _ensureSuccess(response);
    return response.bodyBytes;
  }

  static http.MultipartFile multipartFromBytes(
    String fieldName,
    List<int> bytes, {
    String? filename,
  }) {
    return http.MultipartFile.fromBytes(
      fieldName,
      bytes,
      filename: filename,
    );
  }

  /// Helper: archivo desde ruta (content-type inferido por extensión).
  static Future<http.MultipartFile> fileField(
    String fieldName,
    String filePath, {
    String? filename,
  }) {
    return http.MultipartFile.fromPath(
      fieldName,
      filePath,
      filename: filename,
    );
  }

  /// Comprueba si el servidor responde 200 en [path] antes de [timeout].
  static Future<bool> isReachable(
    String path, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final r = await http.get(uri(path)).timeout(timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
