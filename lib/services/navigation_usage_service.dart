import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'nav_pane.dart';

class NavigationUsageService {
  NavigationUsageService._();
  static final NavigationUsageService instance = NavigationUsageService._();

  static const String _kUsageKey = 'nav_usage_counts_v1';

  Future<void> record({required NavPaneId paneId, required String roleRaw}) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kUsageKey);
    final map = <String, dynamic>{};
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          map.addAll(parsed.map((k, v) => MapEntry('$k', v)));
        }
      } catch (_) {}
    }
    final role = roleRaw.trim().toUpperCase();
    final key = '${paneId.name}|$role';
    final now = DateTime.now().toIso8601String();
    final node = Map<String, dynamic>.from((map[key] as Map?)?.map((k, v) => MapEntry('$k', v)) ?? {});
    node['count'] = ((node['count'] as num?)?.toInt() ?? 0) + 1;
    node['pane'] = paneId.name;
    node['role'] = role;
    node['last_seen'] = now;
    map[key] = node;
    await p.setString(_kUsageKey, jsonEncode(map));
  }
}
