import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class VersionNotesTimelineScreen extends StatefulWidget {
  const VersionNotesTimelineScreen({super.key});

  @override
  State<VersionNotesTimelineScreen> createState() =>
      _VersionNotesTimelineScreenState();
}

class _VersionNotesTimelineScreenState extends State<VersionNotesTimelineScreen> {
  static const int _fallbackBaseBuild = 327;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await rootBundle.loadString('assets/qa_version_notes.json');
      final decoded = json.decode(raw);
      final list = <Map<String, dynamic>>[];
      if (decoded is List) {
        for (final e in decoded) {
          if (e is! Map) continue;
          list.add(
            Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))),
          );
        }
      }
      list.sort((a, b) => _buildOf(b).compareTo(_buildOf(a)));
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  int _buildOf(Map<String, dynamic> m) {
    final raw = m['build'] ?? m['version_num'] ?? m['vnum'] ?? m['v'];
    return int.tryParse('$raw') ?? _fallbackBaseBuild;
  }

  String _versionLabelOf(Map<String, dynamic> m) {
    final raw = '${m['v'] ?? m['version'] ?? ''}'.trim();
    if (raw.isNotEmpty) return raw;
    return 'v${_buildOf(m)}';
  }

  String _tipoOf(Map<String, dynamic> m) {
    final t = '${m['tipo'] ?? m['kind'] ?? 'parche'}'.trim().toLowerCase();
    return t.isEmpty ? 'parche' : t;
  }

  int get _currentBuild =>
      _entries.isEmpty ? _fallbackBaseBuild : _buildOf(_entries.first);

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Notas de versión',
          style: FluentTheme.of(context).typography.title,
        ),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InfoLabel(
              label: 'Versión actual',
              child: Text(
                '$_currentBuild',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _loadNotes,
            ),
          ],
        ),
      ),
      content: Container(
        color: palette.surfaceBase,
        child: _loading
            ? const Center(child: ProgressRing())
            : _error != null
                ? Center(child: Text('Error cargando notas: $_error'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      final version = _versionLabelOf(e);
                      final build = _buildOf(e);
                      final fecha = '${e['fecha'] ?? ''}'.trim();
                      final notas = '${e['notas'] ?? e['texto'] ?? ''}'.trim();
                      final tipo = _tipoOf(e);
                      final tipoColor = tipo == 'actualizacion'
                          ? palette.actionInfo
                          : palette.actionEdit;
                      return Card(
                        padding: const EdgeInsets.all(12),
                        backgroundColor: palette.surfaceCard,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tipoColor.withValues(alpha: 0.22),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    tipo == 'actualizacion' ? 'Actualización' : 'Parche',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: tipoColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '$version  ·  Build $build',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: palette.textPrimary,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  fecha,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              notas.isEmpty ? 'Sin descripción.' : notas,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textPrimary,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
