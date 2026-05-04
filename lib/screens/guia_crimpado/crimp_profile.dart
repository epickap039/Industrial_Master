import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Ruta del manifiesto JSON en assets (declarado en pubspec).
const String kCrimpProfilesAssetPath = 'assets/guia_crimpado/profiles.json';

class CrimpJustificacion {
  const CrimpJustificacion({
    this.comentarios,
    this.referenciaDocumento,
    this.versionTabla,
    this.fechaVigencia,
  });

  final String? comentarios;
  final String? referenciaDocumento;
  final String? versionTabla;
  final String? fechaVigencia;

  static CrimpJustificacion? fromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    String? s(String k) {
      final v = m[k];
      if (v == null) return null;
      final t = v.toString().trim();
      return t.isEmpty ? null : t;
    }

    return CrimpJustificacion(
      comentarios: s('comentarios'),
      referenciaDocumento: s('referencia_documento'),
      versionTabla: s('version_tabla'),
      fechaVigencia: s('fecha_vigencia'),
    );
  }

  bool get hasAny =>
      (comentarios != null && comentarios!.isNotEmpty) ||
      (referenciaDocumento != null && referenciaDocumento!.isNotEmpty) ||
      (versionTabla != null && versionTabla!.isNotEmpty) ||
      (fechaVigencia != null && fechaVigencia!.isNotEmpty);
}

class CrimpDisplayImage {
  const CrimpDisplayImage({required this.asset, this.etiqueta});

  final String asset;
  final String? etiqueta;

  static CrimpDisplayImage? tryParse(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final path = m['asset']?.toString().trim();
    if (path == null || path.isEmpty) return null;
    final tag = m['etiqueta']?.toString().trim();
    return CrimpDisplayImage(
      asset: path,
      etiqueta: (tag != null && tag.isNotEmpty) ? tag : null,
    );
  }
}

class CrimpProfile {
  const CrimpProfile({
    required this.id,
    required this.nombre,
    this.tipoConexion,
    this.codigoConjunto,
    this.sku,
    this.manguera,
    this.tipoMalla,
    this.marcaProveedor,
    this.diametroExteriorAntesMm,
    this.diametroExteriorDespuesMm,
    this.toleranciaExterior,
    this.presionRangoBar,
    this.topeMm,
    this.topeAplica,
    this.caudalInternoDespuesMm,
    this.toleranciaCaudalInterno,
    this.tipoMatriz,
    this.tipoMaquina,
    this.imagenConexion,
    this.imagenesPantalla = const [],
    this.justificacion,
  });

  final String id;
  final String nombre;
  final String? tipoConexion;
  final String? codigoConjunto;
  final String? sku;
  final String? manguera;
  final String? tipoMalla;
  final String? marcaProveedor;
  final String? diametroExteriorAntesMm;
  final String? diametroExteriorDespuesMm;
  final String? toleranciaExterior;
  final String? presionRangoBar;
  final String? topeMm;
  final bool? topeAplica;
  final String? caudalInternoDespuesMm;
  final String? toleranciaCaudalInterno;
  final String? tipoMatriz;
  final String? tipoMaquina;
  final String? imagenConexion;
  final List<CrimpDisplayImage> imagenesPantalla;
  final CrimpJustificacion? justificacion;

  static String? _str(dynamic v) {
    if (v == null) return null;
    final t = v.toString().trim();
    return t.isEmpty ? null : t;
  }

  static String? _tipoMaquinaFromJson(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      final parts = v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty);
      if (parts.isEmpty) return null;
      return parts.join(', ');
    }
    return _str(v);
  }

  static List<CrimpDisplayImage> _displayImagesFromJson(Map<String, dynamic> m) {
    final out = <CrimpDisplayImage>[];
    final list = m['imagenes_pantalla'];
    if (list is List) {
      for (final item in list) {
        final img = CrimpDisplayImage.tryParse(item);
        if (img != null) out.add(img);
      }
    }
    if (out.isEmpty) {
      final single = _str(m['imagen_pantalla']);
      if (single != null) {
        out.add(CrimpDisplayImage(asset: single));
      }
    }
    return List.unmodifiable(out);
  }

  factory CrimpProfile.fromJson(Map<String, dynamic> m) {
    final id = _str(m['id']) ?? _str(m['nombre']) ?? 'sin_id';
    final nombre = _str(m['nombre']) ?? id;

    bool? topeAplica;
    if (m.containsKey('tope_aplica')) {
      final b = m['tope_aplica'];
      if (b is bool) {
        topeAplica = b;
      } else if (b != null) {
        final s = b.toString().toLowerCase();
        if (s == 'true') topeAplica = true;
        if (s == 'false') topeAplica = false;
      }
    }

    return CrimpProfile(
      id: id,
      nombre: nombre,
      tipoConexion: _str(m['tipo_conexion']),
      codigoConjunto: _str(m['codigo_conjunto']),
      sku: _str(m['sku']),
      manguera: _str(m['manguera']),
      tipoMalla: _str(m['tipo_malla']),
      marcaProveedor: _str(m['marca_proveedor']),
      diametroExteriorAntesMm: _str(m['diametro_exterior_antes_mm']),
      diametroExteriorDespuesMm: _str(m['diametro_exterior_despues_mm']),
      toleranciaExterior: _str(m['tolerancia_exterior']),
      presionRangoBar: _str(m['presion_rango_bar']),
      topeMm: _str(m['tope_mm']),
      topeAplica: topeAplica,
      caudalInternoDespuesMm: _str(m['caudal_interno_despues_mm']),
      toleranciaCaudalInterno: _str(m['tolerancia_caudal_interno']),
      tipoMatriz: _str(m['tipo_matriz']),
      tipoMaquina: _tipoMaquinaFromJson(m['tipo_maquina']),
      imagenConexion: _str(m['imagen_conexion']),
      imagenesPantalla: _displayImagesFromJson(m),
      justificacion: CrimpJustificacion.fromJson(m['justificacion']),
    );
  }

  /// `true` si el tope no aplica (flag explícito o texto tipo Excel).
  bool get topeResaltarNoAplica {
    if (topeAplica == false) return true;
    final t = topeMm?.toUpperCase().trim() ?? '';
    return t.contains('NO APLICA') || t == 'N/A';
  }

  static Future<List<CrimpProfile>> loadFromAssets() async {
    final s = await rootBundle.loadString(kCrimpProfilesAssetPath);
    final decoded = jsonDecode(s);
    if (decoded is! Map) return const [];
    final list = decoded['profiles'];
    if (list is! List) return const [];
    final out = <CrimpProfile>[];
    for (final item in list) {
      if (item is Map) {
        out.add(CrimpProfile.fromJson(item.cast<String, dynamic>()));
      }
    }
    return out;
  }
}
