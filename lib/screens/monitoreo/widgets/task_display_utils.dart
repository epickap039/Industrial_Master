import 'dart:convert';

String normEst(Map<String, dynamic> t) {
  return '${t['Estado'] ?? t['estado'] ?? ''}'.trim().toLowerCase();
}

bool esCancelada(Map<String, dynamic> t) => normEst(t).contains('cancel');

bool esPausada(Map<String, dynamic> t) => normEst(t).contains('paus');

bool esManualSource(Map<String, dynamic> t) {
  final st = '${t['source_type'] ?? t['SourceType'] ?? ''}'.trim().toLowerCase();
  if (st == 'manual') return true;
  final tipo = '${t['tipo'] ?? ''}'.trim().toUpperCase();
  return tipo == 'MANUAL' || tipo.contains('MANUAL');
}

bool esCritica(Map<String, dynamic> t) {
  final c = t['critico'];
  if (c == true || '$c' == '1' || '$c'.toLowerCase() == 'true') return true;
  return false;
}

bool esEnProceso(Map<String, dynamic> t) {
  if (esCancelada(t) || esPausada(t)) return false;
  final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
  if (p <= 0 || p >= 100) return false;
  final st = normEst(t);
  return st.contains('proceso') || st == 'en proceso';
}

String? motivoCancelacion(Map<String, dynamic> t) {
  final d = t['motivo_cancelacion']?.toString().trim();
  if (d != null && d.isNotEmpty) return d;
  final meta = t['meta'];
  if (meta is Map) {
    final m = meta['motivo_cancelacion'] ?? meta['Motivo_Cancelacion'];
    final s = m?.toString().trim();
    if (s != null && s.isNotEmpty) return s;
  } else if (meta is String && meta.isNotEmpty) {
    try {
      final m = json.decode(meta) as Map<String, dynamic>?;
      final s = m?['motivo_cancelacion']?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    } catch (_) {}
  }
  return null;
}

String tituloMision(Map<String, dynamic> t) {
  String? norm(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  final idStr = t['id_tarea']?.toString();
  for (final key in <String>['titulo', 'Titulo', 'Titulo_Cambio', 'titulo_cambio']) {
    final s = norm(t[key]);
    if (s != null) {
      if (idStr != null && s == idStr) continue;
      if (s.isNotEmpty && int.tryParse(s) == int.tryParse(idStr ?? '')) continue;
      return s;
    }
  }
  final meta = t['meta'];
  if (meta is Map) {
    for (final key in ['titulo_cambio', 'Titulo_Cambio', 'titulo']) {
      final s = norm(meta[key]);
      if (s != null && (idStr == null || s != idStr)) return s;
    }
  } else if (meta is String && meta.isNotEmpty) {
    try {
      final m = json.decode(meta) as Map<String, dynamic>?;
      if (m != null) {
        for (final key in ['titulo_cambio', 'Titulo_Cambio', 'titulo']) {
          final s = norm(m[key]);
          if (s != null && (idStr == null || s != idStr)) return s;
        }
      }
    } catch (_) {}
  }
  return 'Mision sin titulo';
}

String asignadoMision(Map<String, dynamic> t) {
  String? norm(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  final ad = norm(t['asignado_display']);
  if (ad != null) return ad;

  for (final key in ['CurrentAssignee', 'current_assignee', 'Usuario_Asignado', 'usuario_asignado']) {
    final s = norm(t[key]);
    if (s != null) return s;
  }
  final meta = t['meta'];
  if (meta is Map) {
    final s = norm(meta['usuario_asignado']);
    if (s != null) return s;
  } else if (meta is String && meta.isNotEmpty) {
    try {
      final m = json.decode(meta) as Map<String, dynamic>?;
      final s = norm(m?['usuario_asignado']);
      if (s != null) return s;
    } catch (_) {}
  }
  return 'Sin asignar';
}

int? _idCheckFromMap(Map<String, dynamic> m) {
  for (final k in ['id_check', 'ID_Check', 'Id_Check', 'ID_CHECK', 'idCheck']) {
    final r = m[k];
    if (r == null) continue;
    if (r is int) return r;
    final p = int.tryParse('$r');
    if (p != null) return p;
  }
  return null;
}

int? idCheckDe(Map<String, dynamic> check) {
  final direct = _idCheckFromMap(check);
  if (direct != null) return direct;
  final raw = check['raw'];
  if (raw is Map) {
    return _idCheckFromMap(Map<String, dynamic>.from(raw.map((k, v) => MapEntry('$k', v))));
  }
  return null;
}

/// Grupo legado (antes: cierre documental global). Puede aparecer en tareas antiguas.
const String kGrupoCierreDocumental = 'Global';

/// Coincide con `engineering._GRUPO_INDEFINIDO_SW`: checklist sin grupo no cae en Global (Radar/SW).
const String kGrupoJerarquiaIndefinida = '[Indefinido] > [Indefinido] > [Indefinido]';

/// Impacto de material (no mezclar con cierre).
const String kGrupoImpactoMaterial = 'Impacto de material';

/// Encabezado de sección checklist: evita el placeholder «Global» en UI.
String tituloEncabezadoGrupoChecklist(String grupoRaw) {
  final t = grupoRaw.trim();
  if (t.isEmpty) return kGrupoJerarquiaIndefinida;
  if (t == kGrupoCierreDocumental || t.toLowerCase() == 'global') {
    return 'Tareas Globales';
  }
  return t;
}

String grupoDeCheck(Map<String, dynamic> c) {
  final top = c['grupo']?.toString().trim();
  if (top != null && top.isNotEmpty) {
    if (top.toLowerCase() == 'global') {
      final raw = c['raw'];
      if (raw is Map && (raw['ID_Ensamble'] != null || raw['id_ensamble'] != null)) {
        return kGrupoJerarquiaIndefinida;
      }
    }
    return top;
  }
  final raw = c['raw'];
  if (raw is Map) {
    for (final k in ['Grupo', 'grupo', 'GRUPO', 'Grupo_Item', 'Categoria']) {
      final v = raw[k]?.toString().trim();
      if (v != null && v.isNotEmpty) {
        if (v.toLowerCase() == 'global' &&
            (raw['ID_Ensamble'] != null || raw['id_ensamble'] != null)) {
          return kGrupoJerarquiaIndefinida;
        }
        return v;
      }
    }
    for (final metaKey in [
      'Meta_JSON',
      'Meta_Item',
      'Datos_JSON',
      'Contexto_JSON',
      'Observaciones_JSON',
    ]) {
      final col = raw[metaKey];
      if (col is! String) continue;
      final s = col.trim();
      if (s.length < 2 || !s.startsWith('{')) continue;
      try {
        final m = json.decode(s) as Map<String, dynamic>?;
        if (m == null) continue;
        for (final gk in ['grupo', 'categoria', '_grupo']) {
          final gv = m[gk]?.toString().trim();
          if (gv != null && gv.isNotEmpty) return gv;
        }
      } catch (_) {}
    }
  }
  return kGrupoJerarquiaIndefinida;
}

/// Jerarquía SW / Indefinido primero; impacto de material; al final Global (legado).
int compareGrupoChecklist(String a, String b) {
  int rank(String x) {
    if (x == kGrupoCierreDocumental) return 2;
    if (x == kGrupoImpactoMaterial) return 1;
    return 0;
  }

  final ra = rank(a);
  final rb = rank(b);
  if (ra != rb) return ra.compareTo(rb);
  return a.toLowerCase().compareTo(b.toLowerCase());
}

/// Meta de tarea como Map (JSON en string o mapa ya parseado).
Map<String, dynamic>? metaMapTarea(Map<String, dynamic> t) {
  final m = t['meta'];
  if (m is Map) {
    return Map<String, dynamic>.from(m.map((k, v) => MapEntry('$k', v)));
  }
  if (m is String && m.trim().startsWith('{')) {
    try {
      final d = json.decode(m);
      if (d is Map) {
        return Map<String, dynamic>.from(d.map((k, v) => MapEntry('$k', v)));
      }
    } catch (_) {}
  }
  return null;
}

/// Base64 crudo de imagen guardada en meta (alta manual u otras extensiones).
String? imagenAdjuntaBase64Tarea(Map<String, dynamic> t) {
  final mm = metaMapTarea(t);
  if (mm == null) return null;
  for (final k in ['imagen_adjunta_base64', 'imagen_base64']) {
    final s = mm[k]?.toString().trim();
    if (s != null && s.isNotEmpty) return s;
  }
  return null;
}

bool _truthyCell(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  final s = '$v'.toLowerCase().trim();
  return s == 'true' || s == '1' || s == 'si' || s == 'sí';
}

/// Subtítulo (p. ej. clientes afectados) desde API o JSON de meta en fila SQL (`raw`).
String? textoSecundarioCheck(Map<String, dynamic> c) {
  final d = c['texto_secundario']?.toString().trim();
  if (d != null && d.isNotEmpty) return d;
  final raw = c['raw'];
  if (raw is Map) {
    for (final key in <String>[
      'Meta_JSON',
      'Meta_Item',
      'Datos_JSON',
      'Contexto_JSON',
      'Observaciones_JSON',
    ]) {
      final col = raw[key];
      if (col is! String) continue;
      final s = col.trim();
      if (s.length < 2 || !s.startsWith('{')) continue;
      try {
        final m = json.decode(s) as Map<String, dynamic>?;
        final x = m?['texto_secundario'] ?? m?['Texto_Secundario'];
        final t = x?.toString().trim();
        if (t != null && t.isNotEmpty) return t;
      } catch (_) {}
    }
  }
  return null;
}

bool checkItemHecho(Map<String, dynamic> c) {
  if (_truthyCell(c['completado'])) return true;
  final raw = c['raw'];
  if (raw is Map) {
    for (final k in ['Completado', 'completado', 'Hecho', 'HECHO']) {
      if (_truthyCell(raw[k])) return true;
    }
  }
  return false;
}

int calcularProgresoDesdeChecklist(List<Map<String, dynamic>> list) {
  if (list.isEmpty) return 0;
  var done = 0;
  for (final c in list) {
    if (checkItemHecho(c)) done++;
  }
  return ((done * 100) / list.length).round().clamp(0, 100);
}

int? totalMinutosPresupuestoMeta(Map<String, dynamic> task) {
  final meta = task['meta'];
  if (meta is Map) {
    return int.tryParse('${meta['total_minutos'] ?? ''}');
  }
  if (meta is String && meta.trim().isNotEmpty) {
    try {
      final m = json.decode(meta) as Map<String, dynamic>?;
      if (m != null) return int.tryParse('${m['total_minutos'] ?? ''}');
    } catch (_) {}
  }
  return null;
}

/// Fecha de cierre / fin para tarjeta de historial (ISO desde API).
String fechaCierreHistorialLegible(Map<String, dynamic> t) {
  final raw = t['fecha_cierre'];
  if (raw == null) return '';
  var s = '$raw'.trim();
  if (s.isEmpty || s == 'null') return '';
  final tIdx = s.indexOf('T');
  if (tIdx > 0 && s.length > tIdx + 1) {
    final time = s.substring(tIdx + 1);
    final dot = time.indexOf('.');
    final hhmm = dot > 0 ? time.substring(0, dot) : time;
    final shortTime = hhmm.length >= 5 ? hhmm.substring(0, 5) : hhmm;
    return '${s.substring(0, tIdx)} $shortTime';
  }
  return s.length > 32 ? '${s.substring(0, 32)}…' : s;
}

/// Usuario que cerró la tarea (columna opcional en SQL).
String usuarioCompletoHistorialLegible(Map<String, dynamic> t) {
  final u = t['usuario_completado']?.toString().trim();
  if (u != null && u.isNotEmpty && u != 'null') return u;
  return '';
}

/// `entregables_agrupados` desde meta de simulación Radar (orden de grupos en UI).
List<Map<String, dynamic>>? entregablesAgrupadosDesdeMeta(Map<String, dynamic> task) {
  final mm = metaMapTarea(task);
  if (mm == null) return null;
  final raw = mm['entregables_agrupados'];
  if (raw is! List || raw.isEmpty) return null;
  final out = <Map<String, dynamic>>[];
  for (final e in raw) {
    if (e is! Map) continue;
    out.add(Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))));
  }
  return out.isEmpty ? null : out;
}

/// Primera línea del nombre de ítem checklist (evita mezclar con texto pegado en columna única).
String nombrePrimeraLineaCheck(Map<String, dynamic> c) {
  final n = '${c['nombre'] ?? ''}'.trim();
  if (n.isEmpty) return '';
  return n.split(RegExp(r'\r?\n')).first.trim();
}

/// Etiqueta principal: nombre de ensamble si el ítem sigue el patrón Radar; si no, la primera línea.
String etiquetaPrincipalChecklistUI(Map<String, dynamic> c) {
  final first = nombrePrimeraLineaCheck(c);
  final re = RegExp(r'^\[(.+?)\]\s*-\s*Modificar plano\s*$');
  final m = re.firstMatch(first);
  if (m != null) {
    return m.group(1)!.trim();
  }
  return first.isEmpty ? 'Item' : first;
}

/// Texto secundario del checklist sin mención a clientes (datos legados).
String? textoSecundarioChecklistUI(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  final parts = s.split(' · ').map((e) => e.trim()).where((e) => e.isNotEmpty).where(
        (e) => !e.toLowerCase().startsWith('clientes:'),
      );
  final joined = parts.join(' · ');
  return joined.isEmpty ? null : joined;
}

/// Tiempo restante estimado: total_meta × (1 − progreso/100).
String tiempoEstimadoEtiqueta(Map<String, dynamic> task) {
  final totalMin = totalMinutosPresupuestoMeta(task);
  final p = int.tryParse('${task['porcentaje_progreso'] ?? 0}') ?? 0;
  final pClamped = p.clamp(0, 100);
  if (totalMin == null) {
    if (esManualSource(task)) {
      return 'Tiempo estimado: misión manual (sin simulación Radar)';
    }
    return 'Tiempo estimado: no disponible en metadata';
  }
  final safeTotal = totalMin < 0 ? 0 : totalMin;
  final rem = (safeTotal * (1.0 - pClamped / 100.0)).round().clamp(0, safeTotal);
  final h = rem ~/ 60;
  final m = rem % 60;
  return 'Tiempo estimado: $h hrs $m min';
}
