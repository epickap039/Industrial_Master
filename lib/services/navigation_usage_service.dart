import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_telemetry_sync.dart';
import 'nav_pane.dart';

/// Fila agregada para tablas de ranking (suma todos los roles).
class UsageRankRow {
  const UsageRankRow({required this.label, required this.totalCount});
  final String label;
  final int totalCount;
}

/// Instantánea de contadores locales (navegación + eventos de producto).
class UsageAnalyticsBundle {
  UsageAnalyticsBundle({
    required this.navByKey,
    required this.featuresByKey,
    required this.navTotalsByPane,
    required this.featureTotalsById,
  });

  final Map<String, Map<String, dynamic>> navByKey;
  final Map<String, Map<String, dynamic>> featuresByKey;
  final List<UsageRankRow> navTotalsByPane;
  final List<UsageRankRow> featureTotalsById;
}

class NavigationUsageService {
  NavigationUsageService._();
  static final NavigationUsageService instance = NavigationUsageService._();

  static const String _kUsageKey = 'nav_usage_counts_v1';
  static const String _kFeatureUsageKey = 'app_feature_usage_counts_v1';

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
    final node = Map<String, dynamic>.from(
      (map[key] as Map?)?.map((k, v) => MapEntry('$k', v)) ?? {},
    );
    node['count'] = ((node['count'] as num?)?.toInt() ?? 0) + 1;
    node['pane'] = paneId.name;
    node['role'] = role;
    node['last_seen'] = now;
    map[key] = node;
    await p.setString(_kUsageKey, jsonEncode(map));
    AppTelemetrySync.reportNavPane(paneId: paneId, roleRaw: roleRaw);
  }

  /// Eventos de producto (bandeja, detalle en catálogo, etc.), clave `evento|ROL`.
  Future<void> recordFeature({
    required String featureId,
    required String roleRaw,
  }) async {
    final id = featureId.trim();
    if (id.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kFeatureUsageKey);
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
    final key = '$id|$role';
    final now = DateTime.now().toIso8601String();
    final node = Map<String, dynamic>.from(
      (map[key] as Map?)?.map((k, v) => MapEntry('$k', v)) ?? {},
    );
    node['count'] = ((node['count'] as num?)?.toInt() ?? 0) + 1;
    node['feature'] = id;
    node['role'] = role;
    node['last_seen'] = now;
    map[key] = node;
    await p.setString(_kFeatureUsageKey, jsonEncode(map));
    AppTelemetrySync.reportFeature(featureId: id, roleRaw: roleRaw);
  }

  Future<UsageAnalyticsBundle> loadBundle() async {
    final p = await SharedPreferences.getInstance();
    final nav = _decodeMap(p.getString(_kUsageKey));
    final feat = _decodeMap(p.getString(_kFeatureUsageKey));

    final byPane = <String, int>{};
    for (final e in nav.values) {
      final pane = '${e['pane'] ?? ''}'.trim();
      if (pane.isEmpty) continue;
      final c = (e['count'] as num?)?.toInt() ?? int.tryParse('${e['count']}') ?? 0;
      byPane[pane] = (byPane[pane] ?? 0) + c;
    }
    final navTotals = byPane.entries
        .map((e) => UsageRankRow(label: e.key, totalCount: e.value))
        .toList()
      ..sort((a, b) => b.totalCount.compareTo(a.totalCount));

    final byFeat = <String, int>{};
    for (final e in feat.values) {
      final f = '${e['feature'] ?? ''}'.trim();
      if (f.isEmpty) continue;
      final c = (e['count'] as num?)?.toInt() ?? int.tryParse('${e['count']}') ?? 0;
      byFeat[f] = (byFeat[f] ?? 0) + c;
    }
    final featTotals = byFeat.entries
        .map((e) => UsageRankRow(label: e.key, totalCount: e.value))
        .toList()
      ..sort((a, b) => b.totalCount.compareTo(a.totalCount));

    return UsageAnalyticsBundle(
      navByKey: nav,
      featuresByKey: feat,
      navTotalsByPane: navTotals,
      featureTotalsById: featTotals,
    );
  }

  Future<String> exportBundleJsonPretty(UsageAnalyticsBundle bundle) async {
    final payload = <String, dynamic>{
      'exported_at': DateTime.now().toIso8601String(),
      'schema': 'industrial_manager_usage_local_v1',
      'navigation_by_key': bundle.navByKey,
      'features_by_key': bundle.featuresByKey,
      'aggregates': {
        'navigation_totals_by_pane': {
          for (final r in bundle.navTotalsByPane) r.label: r.totalCount,
        },
        'feature_totals_by_id': {
          for (final r in bundle.featureTotalsById) r.label: r.totalCount,
        },
      },
    };
    const enc = JsonEncoder.withIndent('  ');
    return enc.convert(payload);
  }

  Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kUsageKey);
    await p.remove(_kFeatureUsageKey);
  }

  Map<String, Map<String, dynamic>> _decodeMap(String? raw) {
    final out = <String, Map<String, dynamic>>{};
    if (raw == null || raw.trim().isEmpty) return out;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return out;
      for (final e in parsed.entries) {
        final k = '${e.key}';
        final v = e.value;
        if (v is Map) {
          out[k] = v.map((k2, v2) => MapEntry('$k2', v2));
        }
      }
    } catch (_) {}
    return out;
  }
}
