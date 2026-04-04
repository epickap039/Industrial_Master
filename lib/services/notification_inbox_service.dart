import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String _kPrefsKey = 'cmd_notification_inbox_v1';
const int _kMaxItems = 200;

const String kMissionAssignedType = 'mission_assigned';

class CmdInboxEntry {
  CmdInboxEntry._(
    this.id,
    this.tipo,
    this.title,
    this.body,
    this.fecha,
    this.idTarea,
    this.leido,
  );

  final String id;
  final String tipo;
  final String title;
  final String body;
  final DateTime fecha;
  final int? idTarea;
  bool leido;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': tipo,
        'title': title,
        'body': body,
        'createdAt': fecha.toIso8601String(),
        'idTarea': idTarea,
        'read': leido,
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

    return CmdInboxEntry._(sid, stype, stitle, sbody, when, idTarea, visto);
  }
}

class CmdInboxStore {
  CmdInboxStore._();
  static final CmdInboxStore instance = CmdInboxStore._();

  Future<List<CmdInboxEntry>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey);
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
      while (items.length > _kMaxItems) {
        items.removeLast();
      }
      await prefs.setString(
        _kPrefsKey,
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
    );
    all.insert(0, n);
    await _save(all);
    return true;
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
    await prefs.remove(_kPrefsKey);
  }
}