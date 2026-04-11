import 'dart:convert';

String normEst(Map<String, dynamic> t) {
  return '${t['Estado'] ?? t['estado'] ?? ''}'.trim().toLowerCase();
}

bool esCancelada(Map<String, dynamic> t) => normEst(t).contains('cancel');

bool esPausada(Map<String, dynamic> t) => normEst(t).contains('paus');

/// Radar/Manual u otras misiones gestionadas en el Centro de Monitoreo.
bool esMisionCentroTablero(Map<String, dynamic> t) {
  var src =
      '${t['source_type'] ?? t['SourceType'] ?? ''}'.trim().toUpperCase();
  if (src.isEmpty) {
    src = 'MANUAL';
  }
  if (src == 'MANUAL' || src == 'RADAR') return true;
  final raw = t['tipo']?.toString().trim() ?? '';
  if (raw.isEmpty || raw == 'null') return false;
  final u = raw.toUpperCase();
  if (u == 'RADAR' || u == 'MANUAL') return true;
  return u.contains('RADAR') || u.contains('MANUAL');
}

/// Misión del centro aún en curso (pestaña Activas): no cancelada, no 100%, no terminada.
bool esMisionCentroActiva(Map<String, dynamic> t) {
  if (!esMisionCentroTablero(t)) return false;
  if (esCancelada(t)) return false;
  final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
  if (p >= 100) return false;
  final st = normEst(t);
  if (st.contains('terminad')) return false;
  return true;
}

/// Misión del centro cerrada o cancelada (pestaña Historial).
bool esMisionCentroHistorial(Map<String, dynamic> t) {
  if (!esMisionCentroTablero(t)) return false;
  if (esCancelada(t)) return true;
  final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
  if (p >= 100) return true;
  final st = normEst(t);
  if (st.contains('terminad')) return true;
  return false;
}

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

/// Texto libre al crear la misión (columna SQL o meta).
String descripcionMision(Map<String, dynamic> t) {
  String? norm(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  for (final key in [
    'descripcion',
    'Descripcion',
    'Detalle',
    'Descripcion_Tarea',
    'detalle_tarea',
  ]) {
    final s = norm(t[key]);
    if (s != null) return s;
  }
  final mm = metaMapTarea(t);
  if (mm != null) {
    for (final key in [
      'descripcion',
      'Descripcion',
      'detalle',
      'descripcion_mision',
      'texto_descripcion',
    ]) {
      final s = norm(mm[key]);
      if (s != null) return s;
    }
  }
  return '';
}

DateTime? _parseSoloDia(Object? raw) {
  if (raw == null) return null;
  try {
    final d = DateTime.parse(raw.toString());
    final l = d.isUtc ? d.toLocal() : d;
    return DateTime(l.year, l.month, l.day);
  } catch (_) {
    return null;
  }
}

/// Inicio de ciclo (ISO API) para franjas en calendario.
/// Si no hay ciclo explícito, usa fecha de creación como respaldo (API/SQL).
DateTime? fechaInicioHistorialDate(Map<String, dynamic> t) {
  Object? raw;
  for (final k in [
    'fecha_inicio_ciclo',
    'Fecha_Inicio_Ciclo',
    'Fecha_Inicio',
    'fecha_creacion',
    'Fecha_Creacion',
    'FechaCreacion',
    'CreatedAt',
    'created_at',
  ]) {
    final v = t[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') continue;
    raw = v;
    break;
  }
  return _parseSoloDia(raw);
}

DateTime? _parseFechaHoraCompleta(Object? raw) {
  if (raw == null) return null;
  try {
    final d = DateTime.parse(raw.toString());
    return d.isUtc ? d.toLocal() : d;
  } catch (_) {
    return null;
  }
}

Object? _rawFechaInicioLead(Map<String, dynamic> t) {
  for (final k in [
    'fecha_inicio_ciclo',
    'Fecha_Inicio_Ciclo',
    'Fecha_Inicio',
    'fecha_creacion',
    'Fecha_Creacion',
    'FechaCreacion',
    'CreatedAt',
    'created_at',
  ]) {
    final v = t[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') continue;
    return v;
  }
  return null;
}

/// Minutos desde medianoche (local) del inicio ciclo/creación — ordenar tareas el mismo día.
int minutosDesdeMedianocheInicioCiclo(Map<String, dynamic> t) {
  final full = _parseFechaHoraCompleta(_rawFechaInicioLead(t));
  if (full == null) return 0;
  return full.hour * 60 + full.minute;
}

/// Hora local de inicio HH:mm (para calendario mismo día).
String etiquetaHoraInicioCiclo(Map<String, dynamic> t) {
  final full = _parseFechaHoraCompleta(_rawFechaInicioLead(t));
  if (full == null) return '';
  final h = full.hour.toString().padLeft(2, '0');
  final m = full.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Lead time visible en tarjeta: activa → "En curso: …"; cerrada → "Cerrado en: …".
String etiquetaLeadTimeTarjeta(Map<String, dynamic> t) {
  final start = _parseFechaHoraCompleta(_rawFechaInicioLead(t));
  if (start == null) return '';
  final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
  final st = normEst(t);
  final cerrada = esCancelada(t) || p >= 100 || st.contains('terminad');
  final DateTime end;
  if (cerrada) {
    final rawC = _rawFechaCierre(t);
    final ep = _parseFechaHoraCompleta(rawC);
    if (ep == null) return '';
    end = ep;
  } else {
    end = DateTime.now();
  }
  final d = end.difference(start);
  if (d.isNegative) return '';
  if (cerrada) {
    if (d.inDays >= 1) return 'Cerrado en: ${d.inDays}d';
    if (d.inHours >= 1) return 'Cerrado en: ${d.inHours}h';
    return 'Cerrado en: ${d.inMinutes}m';
  }
  if (d.inDays >= 1) {
    return 'En curso: ${d.inDays}d ${d.inHours.remainder(24)}h';
  }
  return 'En curso: ${d.inHours}h';
}

/// Rango [inicio, cierre] en días calendario para barras mult día.
({DateTime start, DateTime end})? rangoHistorialCalendario(Map<String, dynamic> t) {
  final fin = fechaCierreHistorialDate(t);
  final ini = fechaInicioHistorialDate(t);
  if (fin == null && ini == null) return null;
  if (ini == null) {
    final f = fin!;
    return (start: f, end: f);
  }
  if (fin == null) {
    return (start: ini, end: ini);
  }
  if (fin.isBefore(ini)) {
    return (start: fin, end: ini);
  }
  return (start: ini, end: fin);
}

bool manualSinTiempoEstimado(Map<String, dynamic> t) {
  if (!esManualSource(t)) return false;
  final mm = metaMapTarea(t);
  if (mm == null) return false;
  final v = mm['sin_tiempo_estimado'];
  if (v == true) return true;
  final s = '$v'.toLowerCase();
  return s == 'true' || s == '1';
}

/// Presupuesto: Radar (`total_minutos` en meta) o manual (`minutos_estimados` en API).
int? totalMinutosPresupuestoCombinado(Map<String, dynamic> task) {
  final meta = totalMinutosPresupuestoMeta(task);
  if (meta != null && meta > 0) return meta;
  final m = int.tryParse('${task['minutos_estimados'] ?? ''}');
  if (m != null && m > 0) return m;
  return null;
}

/// Minutos restantes ~ presupuesto × (1 − progreso/100).
int? minutosRestantesEstimados(Map<String, dynamic> task) {
  if (manualSinTiempoEstimado(task)) return null;
  final totalMin = totalMinutosPresupuestoCombinado(task);
  if (totalMin == null) return null;
  final p = int.tryParse('${task['porcentaje_progreso'] ?? 0}') ?? 0;
  final pClamped = p.clamp(0, 100);
  final safeTotal = totalMin < 0 ? 0 : totalMin;
  return (safeTotal * (1.0 - pClamped / 100.0)).round().clamp(0, safeTotal);
}

bool _esDiaLaboral(DateTime d) => d.weekday >= DateTime.monday && d.weekday <= DateTime.saturday;

({DateTime start, DateTime end})? _ventanaLaboral(DateTime d) {
  if (!_esDiaLaboral(d)) return null;
  final start = DateTime(d.year, d.month, d.day, 8, 0);
  final end = d.weekday == DateTime.saturday
      ? DateTime(d.year, d.month, d.day, 14, 0)
      : DateTime(d.year, d.month, d.day, 17, 0);
  return (start: start, end: end);
}

DateTime? finLaboralDesde(DateTime base, int minutosPendientes) {
  if (minutosPendientes <= 0) return base;
  var rem = minutosPendientes;
  var cur = base;
  var guard = 0;
  while (rem > 0 && guard < 5000) {
    guard++;
    final win = _ventanaLaboral(cur);
    if (win == null) {
      cur = DateTime(cur.year, cur.month, cur.day + 1, 8, 0);
      continue;
    }
    if (cur.isBefore(win.start)) {
      cur = win.start;
    }
    if (!cur.isBefore(win.end)) {
      cur = DateTime(cur.year, cur.month, cur.day + 1, 8, 0);
      continue;
    }
    final disp = win.end.difference(cur).inMinutes;
    if (rem <= disp) return cur.add(Duration(minutes: rem));
    rem -= disp;
    cur = DateTime(cur.year, cur.month, cur.day + 1, 8, 0);
  }
  return cur;
}

String etiquetaFinLaboral(DateTime dt) {
  const dias = ['', 'lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado', 'domingo'];
  const meses = ['', 'ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${dias[dt.weekday]} ${dt.day} ${meses[dt.month]} $h:$m';
}

String? estimadoFinLaboralDesdeAhoraEtiqueta(int minutosPendientes) {
  if (minutosPendientes <= 0) return null;
  final fin = finLaboralDesde(DateTime.now(), minutosPendientes);
  if (fin == null) return null;
  return etiquetaFinLaboral(fin);
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
  final asignados = t['usuarios_asignados'];
  if (asignados is List && asignados.isNotEmpty) {
    final first = norm(asignados.first);
    if (first != null) return first;
  }

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
const String kGrupoJerarquiaIndefinida = 'Sin jerarquía definida';

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

Object? _rawFechaCierre(Map<String, dynamic> t) {
  const keys = [
    'fecha_cierre',
    'Fecha_Cierre',
    'fecha_Cierre',
    'Fecha_Completado',
    'Ultima_Modificacion',
    'Fecha_Modificacion',
    'Fecha_Actualizacion',
  ];
  for (final k in keys) {
    final v = t[k];
    if (v == null) continue;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') continue;
    return v;
  }
  final mm = metaMapTarea(t);
  if (mm != null) {
    for (final k in ['fecha_cierre', 'fecha_fin', 'Fecha_Cierre', 'fecha_completado']) {
      final v = mm[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isEmpty || s == 'null') continue;
      return v;
    }
  }
  return null;
}

/// Fecha de cierre / fin para tarjeta de historial (ISO desde API).
/// Fecha (solo día) para agrupar en calendario; null si no hay fecha válida.
DateTime? fechaCierreHistorialDate(Map<String, dynamic> t) {
  Object? raw = _rawFechaCierre(t);
  if (raw == null) {
    final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
    final st = normEst(t);
    if (p >= 100 || st.contains('terminad') || st.contains('cancel')) {
      for (final k in ['fecha_inicio_ciclo', 'Fecha_Inicio_Ciclo']) {
        final v = t[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isEmpty || s == 'null') continue;
        raw = v;
        break;
      }
    }
  }
  if (raw == null) return null;
  try {
    final d = DateTime.parse(raw.toString());
    final l = d.isUtc ? d.toLocal() : d;
    return DateTime(l.year, l.month, l.day);
  } catch (_) {
    return null;
  }
}

String fechaCierreHistorialLegible(Map<String, dynamic> t) {
  final raw = _rawFechaCierre(t);
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
  if (manualSinTiempoEstimado(task)) {
    return 'Tiempo estimado: no aplica';
  }
  final totalMin = totalMinutosPresupuestoCombinado(task);
  final p = int.tryParse('${task['porcentaje_progreso'] ?? 0}') ?? 0;
  final pClamped = p.clamp(0, 100);
  if (totalMin == null) {
    if (esManualSource(task)) {
      return 'Tiempo estimado: sin definir (indique minutos o no aplica)';
    }
    return 'Tiempo estimado: no disponible en metadata';
  }
  final safeTotal = totalMin < 0 ? 0 : totalMin;
  final rem = (safeTotal * (1.0 - pClamped / 100.0)).round().clamp(0, safeTotal);
  final d = rem ~/ (24 * 60);
  final h = (rem % (24 * 60)) ~/ 60;
  final m = rem % 60;
  if (d > 0) {
    return 'Tiempo estimado: ${d} d ${h} h ${m} min';
  }
  return 'Tiempo estimado: $h hrs $m min';
}
