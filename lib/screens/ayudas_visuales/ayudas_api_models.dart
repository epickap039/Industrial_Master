import 'dart:convert';

import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';

import '../../services/api_client.dart';

/// Claves JSON alineadas con columnas SQL devueltas por la API (PascalCase vía pyodbc).
abstract final class AyudasJsonKeys {
  static const tituloDocumento = 'Titulo_Documento';
  static const fechaSubida = 'Fecha_Subida';
  static const rutaPdf = 'Ruta_PDF';
  static const idAyuda = 'Id_Ayuda';
  static const idRevision = 'Id_Revision';
  static const numeroRevision = 'Numero_Revision';
  static const esVigente = 'Es_Vigente';
  static const usuarioSubida = 'Usuario_Subida';
  static const vin = 'VIN';
  static const subcategoriaProceso = 'Subcategoria';
  static const tags = 'Tags';
}

const String kAyudasDeletePassword = 'ADMIN_ING_2024';

dynamic _firstKey(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k) && m[k] != null) return m[k];
  }
  return null;
}

String ayudasTituloDocumento(Map<String, dynamic> m) {
  final v = _firstKey(m, [
    AyudasJsonKeys.tituloDocumento,
    'titulo_documento',
    'Titulo',
  ]);
  if (v == null) return 'Sin título';
  return v.toString();
}

dynamic ayudasFechaSubida(Map<String, dynamic> m) =>
    _firstKey(m, [AyudasJsonKeys.fechaSubida, 'fecha_subida', 'Fecha_Revision']);

int ayudasIdAyuda(Map<String, dynamic> m) {
  final v = _firstKey(m, [AyudasJsonKeys.idAyuda, 'id_ayuda']);
  if (v is int) return v;
  return int.tryParse('$v') ?? 0;
}

int ayudasIdRevision(Map<String, dynamic> m) {
  final v = _firstKey(m, [AyudasJsonKeys.idRevision, 'id_revision']);
  if (v is int) return v;
  return int.tryParse('$v') ?? 0;
}

String ayudasNumeroRevision(Map<String, dynamic> m) {
  final v = _firstKey(m, [AyudasJsonKeys.numeroRevision, 'numero_revision']);
  return v?.toString() ?? '';
}

String ayudasVin(Map<String, dynamic> m) {
  final v = _firstKey(m, [AyudasJsonKeys.vin, 'vin']);
  return v?.toString().trim() ?? '';
}

String ayudasSubcategoriaProceso(Map<String, dynamic> m) {
  final v = _firstKey(m, [
    AyudasJsonKeys.subcategoriaProceso,
    'subcategoria',
    'subcategoria_proceso',
    'Subcategoria',
    'Subcategoria_Proceso',
  ]);
  return v?.toString().trim() ?? '';
}

/// Etiquetas tipo #hashtag guardadas como JSON array en backend.
List<String> ayudasTags(Map<String, dynamic> m) {
  final v = _firstKey(m, [
    AyudasJsonKeys.tags,
    'tags',
  ]);
  if (v == null) return [];
  if (v is List) {
    return v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  final s = v.toString().trim();
  if (s.isEmpty) return [];
  try {
    final decoded = jsonDecode(s);
    if (decoded is List) {
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
  } catch (_) {}
  return [];
}

bool ayudasEsVigente(Map<String, dynamic> m) {
  final v = _firstKey(m, [AyudasJsonKeys.esVigente, 'es_vigente']);
  if (v is bool) return v;
  if (v is int) return v == 1;
  if (v is num) return v != 0;
  return false;
}

/// Cierra el diálogo de carga si sigue abierto y muestra error (SnackBar rojo o InfoBar).
void showAyudasUploadError(BuildContext context, Object error) {
  final text = error is ApiException
      ? error.message
      : error.toString();
  final messenger = material.ScaffoldMessenger.maybeOf(context);
  if (messenger != null) {
    messenger.clearSnackBars();
    messenger.showSnackBar(
      material.SnackBar(
        content: material.Text(text),
        backgroundColor: material.Colors.red.shade800,
        behavior: material.SnackBarBehavior.floating,
      ),
    );
  } else {
    displayInfoBar(
      context,
      builder: (c, close) {
        return InfoBar(
          title: const Text('Error de subida'),
          content: Text(text),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      },
    );
  }
}
