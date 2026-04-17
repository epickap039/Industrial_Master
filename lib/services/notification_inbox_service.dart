import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../screens/monitoreo/widgets/task_display_utils.dart';

const String _kPrefsKey = 'cmd_notification_inbox_v1';
const int _kMaxItems = 200;

// ─── Ritmos de actualización / recordatorios (buzón misiones) ─────────────
//
// El contador de la barra superior repolldea en [main.dart] con
// [kCmdInboxPollInterval] (prune + recuenta no leídas). Los recordatorios
// extra se generan en [addDueMissionReminders] cuando el Centro de monitoreo
// carga la lista de tareas (y el shell repite el sondeo de tareas).
//
// Reglas (hora local del equipo):
// - Misiones **pausadas**: un aviso al día con [tryAddDailyPausedMissionsDigest]
//   (leyenda fija «Tienes misiones pausadas»), no usan la cola por-misión.
// - Prioridad **normal** (rank 2) y **en progreso**: 10:00, 13:00 y 16:00.
// - Prioridad **alta** (rank 1), activas y no pausadas: 9:15, 10:30, 12:00,
//   13:30 y 15:00.
// - Prioridad **crítica** (rank 0), activas y no pausadas: cada 90 minutos.

/// Cada cuánto el shell vuelve a llamar a la API de tareas y poda el buzón local.
const Duration kCmdInboxPollInterval = Duration(seconds: 30);

/// Intervalo entre recordatorios de misión **crítica** (priority_rank 0).
const Duration kMissionCriticalReminderInterval = Duration(minutes: 90);

/// Franjas horarias (hora local) para prioridad **normal** en curso (rank 2).
const List<(int hour, int minute)> kMissionReminderSlotsPrioridadNormalEnProgreso =
    <(int, int)>[(10, 0), (13, 0), (16, 0)];

/// Franjas para prioridad **alta** (rank 1).
const List<(int hour, int minute)> kMissionReminderSlotsPrioridadAlta = <(int, int)>[
  (9, 15),
  (10, 30),
  (12, 0),
  (13, 30),
  (15, 0),
];

DateTime? _latestSlotTodayLeqNow(DateTime now, List<(int, int)> slots) {
  DateTime? best;
  for (final hm in slots) {
    final slot = DateTime(now.year, now.month, now.day, hm.$1, hm.$2);
    if (!slot.isAfter(now)) {
      if (best == null || slot.isAfter(best)) {
        best = slot;
      }
    }
  }
  return best;
}

/// Dispara si [last] es anterior a la última franja del día que ya pasó (≤ [now]).
bool missionSlotReminderShouldFire(
  DateTime last,
  DateTime now,
  List<(int, int)> slots,
) {
  final t = _latestSlotTodayLeqNow(now, slots);
  if (t == null) return false;
  return last.isBefore(t);
}

const String kMissionAssignedType = 'mission_assigned';
const String kMissionReminderType = 'mission_reminder';
const String kSystemNoticeType = 'system_notice';

class CmdInboxEntry {
  CmdInboxEntry._(
    this.id,
    this.tipo,
    this.title,
    this.body,
    this.fecha,
    this.idTarea,
    this.leido,
    this.lastReminderAt,
    this.assignedUser,
    this.priorityRank,
  );

  final String id;
  final String tipo;
  final String title;
  final String body;
  final DateTime fecha;
  final int? idTarea;
  bool leido;
  DateTime? lastReminderAt;
  final String assignedUser;
  final int priorityRank;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': tipo,
        'title': title,
        'body': body,
        'createdAt': fecha.toIso8601String(),
        'idTarea': idTarea,
        'read': leido,
        'lastReminderAt': lastReminderAt?.toIso8601String(),
        'assignedUser': assignedUser,
        'priorityRank': priorityRank,
      };

  static CmdInboxEntry fromJson(Map<String, dynamic> m) {
    final Object? idRaw = m['idTarea'];
    int? idTarea;
    if (idRaw is int) {
      idTarea = idRaw;
    } else if (idRaw != null) {
      idTarea = int.tryParse(idRaw.toString());
    }

    final Object? rv = m['read'];
    bool visto = false;
    if (rv == true || rv == 1) {
      visto = true;
    } else if (rv != null && rv.toString().trim() == '1') {
      visto = true;
    }

    final Object? ca = m['createdAt'];
    final String createdStr = ca == null ? '' : ca.toString();

    String sid = '';
    final Object? idv = m['id'];
    if (idv != null) {
      sid = idv.toString();
    }

    String stype = kMissionAssignedType;
    final Object? tv = m['type'];
    if (tv != null) {
      stype = tv.toString();
    }

    String stitle = '';
    final Object? tiv = m['title'];
    if (tiv != null) {
      stitle = tiv.toString();
    }

    String sbody = '';
    final Object? bv = m['body'];
    if (bv != null) {
      sbody = bv.toString();
    }

    DateTime when = DateTime.now();
    final DateTime? parsed = DateTime.tryParse(createdStr);
    if (parsed != null) {
      when = parsed;
    }

    DateTime? lastReminderAt;
    final Object? lra = m['lastReminderAt'];
    if (lra != null) {
      lastReminderAt = DateTime.tryParse(lra.toString());
    }

    String assignedUser = '';
    final Object? au = m['assignedUser'];
    if (au != null) {
      assignedUser = au.toString().trim();
    }

    int priorityRank = 2;
    final Object? pr = m['priorityRank'];
    if (pr is int) {
      priorityRank = pr;
    } else if (pr != null) {
      priorityRank = int.tryParse(pr.toString()) ?? 2;
    }

    return CmdInboxEntry._(
      sid,
      stype,
      stitle,
      sbody,
      when,
      idTarea,
      visto,
      lastReminderAt,
      assignedUser,
      priorityRank,
    );
  }
}

class CmdInboxStore {
  CmdInboxStore._();
  static final CmdInboxStore instance = CmdInboxStore._();

  Future<String> _prefsKeyForCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final user = (prefs.getString('username') ?? '').trim().toLowerCase();
    if (user.isEmpty) return _kPrefsKey;
    return '${_kPrefsKey}_$user';
  }

  Future<List<CmdInboxEntry>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _prefsKeyForCurrentUser();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) {
        return [];
      }
      final Object? decoded = json.decode(raw);
      if (decoded is! List) {
        return [];
      }
      final out = <CmdInboxEntry>[];
      for (final Object? item in decoded) {
        if (item is! Map) {
          continue;
        }
        try {
          final m = Map<String, dynamic>.from(item);
          out.add(CmdInboxEntry.fromJson(m));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<CmdInboxEntry> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = await _prefsKeyForCurrentUser();
      while (items.length > _kMaxItems) {
        items.removeLast();
      }
      await prefs.setString(
        key,
        json.encode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<int> unreadCount() async {
    final all = await loadAll();
    return all.where((e) => !e.leido).length;
  }

  Future<bool> hasMissionNotification(int idTarea) async {
    final all = await loadAll();
    for (final n in all) {
      if (n.idTarea == idTarea && n.tipo == kMissionAssignedType) {
        return true;
      }
    }
    return false;
  }

  Future<bool> addMissionAssigned({
    required int idTarea,
    required String titulo,
    String assignedUser = '',
    int priorityRank = 2,
  }) async {
    if (await hasMissionNotification(idTarea)) {
      return false;
    }
    final all = await loadAll();
    final String bodyText = titulo.isEmpty
        ? '#$idTarea — (sin titulo)'
        : '#$idTarea — $titulo';
    final n = CmdInboxEntry._(
      'm_${idTarea}_${DateTime.now().millisecondsSinceEpoch}',
      kMissionAssignedType,
      'Nueva mision asignada',
      bodyText,
      DateTime.now(),
      idTarea,
      false,
      DateTime.now(),
      assignedUser.trim(),
      priorityRank,
    );
    all.insert(0, n);
    await _save(all);
    return true;
  }

  String _tituloTarea(Map<String, dynamic> t) {
    final raw = '${t['titulo'] ?? t['Titulo'] ?? ''}'.trim();
    if (raw.isNotEmpty) return raw;
    return 'Mision pendiente';
  }

  String _responsableDe(Map<String, dynamic> t) {
    return '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? ''}'.trim();
  }

  int _priorityRankDe(Map<String, dynamic> t) {
    final raw = t['priority_rank'] ?? t['PriorityRank'];
    final n = raw is int ? raw : int.tryParse('$raw');
    if (n == null) return 2;
    return n.clamp(0, 2);
  }

  /// Recordatorios por prioridad y estado (ver comentarios al inicio del archivo).
  Future<List<CmdInboxEntry>> addDueMissionReminders(
    List<Map<String, dynamic>> pendingTasks,
  ) async {
    if (pendingTasks.isEmpty) return const [];
    final byId = <int, Map<String, dynamic>>{};
    for (final t in pendingTasks) {
      final rawId = t['id_tarea'] ?? t['Id_Tarea'] ?? t['id'];
      final id = rawId is int ? rawId : int.tryParse('$rawId');
      if (id == null || id <= 0) continue;
      byId[id] = t;
    }
    if (byId.isEmpty) return const [];

    final all = await loadAll();
    final created = <CmdInboxEntry>[];
    final now = DateTime.now();
    var mutated = false;

    for (final n in List<CmdInboxEntry>.from(all)) {
      if (n.tipo != kMissionAssignedType || n.idTarea == null) continue;
      final taskId = n.idTarea!;
      final task = byId[taskId];
      if (task == null) continue;
      if (esPausada(task)) continue;

      final base = n.lastReminderAt ?? n.fecha;
      final pr = _priorityRankDe(task);

      bool due = false;
      String tituloRecordatorio;
      if (pr == 0) {
        due = now.difference(base) >= kMissionCriticalReminderInterval;
        tituloRecordatorio = n.leido
            ? 'Recordatorio: mision critica pendiente'
            : 'Recordatorio: mision critica (sin leer)';
      } else if (pr == 1) {
        due = missionSlotReminderShouldFire(base, now, kMissionReminderSlotsPrioridadAlta);
        tituloRecordatorio = n.leido
            ? 'Recordatorio: prioridad alta pendiente'
            : 'Recordatorio: prioridad alta sin leer';
      } else {
        if (esEnProceso(task)) {
          due = missionSlotReminderShouldFire(
            base,
            now,
            kMissionReminderSlotsPrioridadNormalEnProgreso,
          );
          tituloRecordatorio = n.leido
              ? 'Recordatorio: mision en curso (normal)'
              : 'Recordatorio: mision en curso sin leer';
        } else {
          due = false;
          tituloRecordatorio = 'Recordatorio de mision';
        }
      }
      if (!due) continue;

      // Evita doble disparo si el shell y otra pantalla llaman casi a la vez, o dos
      // polls seguidos en el mismo minuto.
      const minGap = Duration(minutes: 2);
      final dupRecent = all.any(
        (e) =>
            e.tipo == kMissionReminderType &&
            e.idTarea == taskId &&
            now.difference(e.fecha) < minGap,
      );
      if (dupRecent) continue;

      final titulo = _tituloTarea(task);
      final reminder = CmdInboxEntry._(
        'r_${taskId}_${now.millisecondsSinceEpoch}',
        kMissionReminderType,
        tituloRecordatorio,
        '#$taskId — $titulo',
        now,
        taskId,
        false,
        now,
        _responsableDe(task),
        pr,
      );
      created.add(reminder);
      all.insert(0, reminder);
      n.lastReminderAt = now;
      mutated = true;
    }

    if (mutated) {
      await _save(all);
    }
    return created;
  }

  static const String _kPrefsPausedNoticeDay = 'cmd_paused_missions_notice_day_v1';

  /// Un aviso al día (texto fijo) si el usuario tiene misiones del centro pausadas.
  Future<void> tryAddDailyPausedMissionsDigest({
    required List<Map<String, dynamic>> tasks,
    required String currentUsername,
  }) async {
    final u = currentUsername.trim().toLowerCase();
    if (u.isEmpty) return;
    var paused = 0;
    for (final t in tasks) {
      if (!esMisionCentroActiva(t)) continue;
      if (!esPausada(t)) continue;
      if (!tareaVisibleParaUsuario(t, currentUsername)) continue;
      paused++;
    }
    if (paused == 0) return;

    final prefs = await SharedPreferences.getInstance();
    final dayKey = '${_kPrefsPausedNoticeDay}_$u';
    final today = DateTime.now().toIso8601String().split('T').first;
    if ((prefs.getString(dayKey) ?? '') == today) return;

    final digestId = 'paused_digest_${today}_$u';
    final added = await addSystemNoticeUniqueId(
      id: digestId,
      title: 'Misiones pausadas',
      body: 'Tienes misiones pausadas.',
    );
    if (added) {
      await prefs.setString(dayKey, today);
    }
  }

  /// IDs de tareas del centro (Radar/Manual) **activas** y asignadas al usuario.
  static Set<int> pendingCentroMissionIdsForUser(
    List<Map<String, dynamic>> tasks,
    String username,
  ) {
    final u = username.trim().toLowerCase();
    if (u.isEmpty) return {};
    final out = <int>{};
    for (final t in tasks) {
      if (!esMisionCentroActiva(t)) continue;
      if (!tareaVisibleParaUsuario(t, username)) continue;
      final idRaw = t['id_tarea'] ?? t['Id_Tarea'] ?? t['id'];
      final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
      if (id != null && id > 0) out.add(id);
    }
    return out;
  }

  /// Quita del buzón notificaciones de misión que ya no están pendientes (completadas,
  /// canceladas, borradas en servidor o reasignadas).
  Future<bool> pruneMissionEntriesNotIn(Set<int> activePendingTaskIds) async {
    final all = await loadAll();
    final filtered = all.where((e) {
      if (e.idTarea == null) return true;
      if (e.tipo != kMissionAssignedType && e.tipo != kMissionReminderType) {
        return true;
      }
      return activePendingTaskIds.contains(e.idTarea!);
    }).toList();
    if (filtered.length == all.length) return false;
    await _save(filtered);
    return true;
  }

  /// Alinea el buzón con [tasks] y el usuario actual (misma regla que recordatorios).
  Future<bool> pruneMissionInboxAgainstTaskList(
    List<Map<String, dynamic>> tasks,
    String currentUsername,
  ) {
    final ids = CmdInboxStore.pendingCentroMissionIdsForUser(
      tasks,
      currentUsername,
    );
    return pruneMissionEntriesNotIn(ids);
  }

  Future<void> markRead(String id) async {
    final all = await loadAll();
    for (final n in all) {
      if (n.id == id) {
        n.leido = true;
      }
    }
    await _save(all);
  }

  Future<void> markAllRead() async {
    final all = await loadAll();
    for (final n in all) {
      n.leido = true;
    }
    await _save(all);
  }

  Future<void> remove(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await _save(all);
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final key = await _prefsKeyForCurrentUser();
    await prefs.remove(key);
  }

  /// Aviso del sistema con [id] estable (evita duplicados al repollar).
  Future<bool> addSystemNoticeUniqueId({
    required String id,
    required String title,
    required String body,
  }) async {
    final all = await loadAll();
    if (all.any((e) => e.id == id)) {
      return false;
    }
    final now = DateTime.now();
    all.insert(
      0,
      CmdInboxEntry._(
        id,
        kSystemNoticeType,
        title.trim().isEmpty ? 'Notificacion del sistema' : title.trim(),
        body.trim(),
        now,
        null,
        false,
        now,
        '',
        2,
      ),
    );
    await _save(all);
    return true;
  }

  Future<void> addSystemNotice({
    required String title,
    required String body,
  }) async {
    final all = await loadAll();
    final now = DateTime.now();
    all.insert(
      0,
      CmdInboxEntry._(
        's_${now.millisecondsSinceEpoch}',
        kSystemNoticeType,
        title.trim().isEmpty ? 'Notificacion del sistema' : title.trim(),
        body.trim(),
        now,
        null,
        false,
        now,
        '',
        2,
      ),
    );
    await _save(all);
  }
}
