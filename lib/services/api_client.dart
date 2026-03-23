import 'dart:convert';

import 'package:http/http.dart' as http;

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
      headers: headers,
    );
    return _decodeSuccessBody(r);
  }

  /// GET sin lanzar por status; útil cuando el caller distingue 200 vs 4xx con el mismo JSON.
  static Future<ApiHttpResult> getUnvalidated(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async {
    final r = await http.get(
      uri(path, queryParameters),
      headers: headers,
    );
    return ApiHttpResult(r.statusCode, r.body);
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
      headers: {..._jsonHeaders(), ...?headers},
      body: body == null ? null : json.encode(body),
    );
    return _decodeSuccessBody(r);
  }

  /// PUT JSON.
  static Future<dynamic> put(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, String>? queryParameters,
  }) async {
    final r = await http.put(
      uri(path, queryParameters),
      headers: {..._jsonHeaders(), ...?headers},
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
      headers: headers,
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
    if (headers != null) {
      request.headers.addAll(headers);
    }
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    return _decodeSuccessBody(response);
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
