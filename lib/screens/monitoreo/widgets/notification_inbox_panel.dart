import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/api_client.dart';
import '../../../services/notification_inbox_service.dart';
import '../../../services/user_avatar_service.dart';

/// Diálogo modal del buzón de notificaciones (Centro de Comando).
Future<void> showNotificationInboxDialog(
  BuildContext context, {
  required VoidCallback onChanged,
  VoidCallback? onOpenMonitoring,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _NotificationInboxDialogContent(
      onChanged: onChanged,
      onOpenMonitoring: onOpenMonitoring,
    ),
  );
}

class _NotificationInboxDialogContent extends StatefulWidget {
  const _NotificationInboxDialogContent({
    required this.onChanged,
    this.onOpenMonitoring,
  });

  final VoidCallback onChanged;
  final VoidCallback? onOpenMonitoring;

  @override
  State<_NotificationInboxDialogContent> createState() =>
      _NotificationInboxDialogContentState();
}

class _NotificationInboxDialogContentState extends State<_NotificationInboxDialogContent> {
  List<CmdInboxEntry> _items = [];
  bool _loading = true;
  final material.ScrollController _listScroll = material.ScrollController();
  final Map<String, Color> _userColorMap = <String, Color>{};
  final Map<String, Uint8List?> _userAvatarMap = <String, Uint8List?>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final inboxUser = (prefs.getString('username') ?? '').trim();
      if (inboxUser.isNotEmpty) {
        try {
          final data = await ApiClient.get('/api/tareas/lista');
          if (data is List) {
            final taskRows =
                data.whereType<Map<String, dynamic>>().toList();
            await CmdInboxStore.instance.pruneMissionInboxAgainstTaskList(
              taskRows,
              inboxUser,
            );
          }
        } catch (_) {}
      }
    } catch (_) {}
    final list = await CmdInboxStore.instance.loadAll();
    await _loadUserColors(list);
    if (mounted) {
      setState(() {
        _items = list;
        _loading = false;
      });
    }
  }

  Future<void> _tapItem(CmdInboxEntry n) async {
    if (!n.leido) {
      await CmdInboxStore.instance.markRead(n.id);
      widget.onChanged();
      await _reload();
    }
  }

  Future<void> _marcarTodas() async {
    await CmdInboxStore.instance.markAllRead();
    widget.onChanged();
    await _reload();
  }

  Future<void> _vaciar() async {
    await CmdInboxStore.instance.clearAll();
    widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _eliminar(CmdInboxEntry n) async {
    await CmdInboxStore.instance.remove(n.id);
    widget.onChanged();
    await _reload();
  }

  Future<void> _loadUserColors(List<CmdInboxEntry> list) async {
    final users = <String>{
      for (final n in list)
        if (n.assignedUser.trim().isNotEmpty) n.assignedUser.trim(),
    };
    for (final user in users) {
      if (_userColorMap.containsKey(user)) continue;
      try {
        final resp = await ApiClient.get('/api/usuarios/$user/color');
        if (resp is Map) {
          final hex = '${resp['color_hex'] ?? resp['colorHex'] ?? '#1F77B4'}';
          _userColorMap[user] = _parseHexColor(hex);
        } else {
          _userColorMap[user] = const Color(0xFF1F77B4);
        }
      } catch (_) {
        _userColorMap[user] = const Color(0xFF1F77B4);
      }
    }
    for (final user in users) {
      if (_userAvatarMap.containsKey(user)) continue;
      _userAvatarMap[user] = await UserAvatarService.instance.loadAvatarForUser(
        user,
      );
    }
  }

  Color _parseHexColor(String hex) {
    final clean = hex.trim().replaceAll('#', '');
    final use = clean.length == 6 ? 'FF$clean' : clean;
    final value = int.tryParse(use, radix: 16) ?? 0xFF1F77B4;
    return Color(value);
  }

  String _initials(String name) {
    final parts = name
        .split(RegExp(r'[\s._-]+'))
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final p = parts.first;
      return p.length >= 2 ? p.substring(0, 2).toUpperCase() : p.toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  Widget _inboxActionButton({required String label, VoidCallback? onPressed}) {
    return Button(
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(label),
      ),
    );
  }

  String _priorityLabel(int rank) {
    if (rank <= 0) return 'Crítica';
    if (rank == 1) return 'Alta';
    return 'Normal';
  }

  Color _priorityColor(int rank) {
    if (rank <= 0) return const Color(0xFFE53935);
    if (rank == 1) return const Color(0xFFFF9800);
    return const Color(0xFF43A047);
  }

  List<MapEntry<String, List<CmdInboxEntry>>> _groupedByUser(
    List<CmdInboxEntry> list,
  ) {
    final grouped = <String, List<CmdInboxEntry>>{};
    final order = <String>[];
    for (final n in list) {
      final user = n.assignedUser.trim().isEmpty
          ? 'Sin responsable'
          : n.assignedUser.trim();
      if (!grouped.containsKey(user)) {
        grouped[user] = <CmdInboxEntry>[];
        order.add(user);
      }
      grouped[user]!.add(n);
    }
    return [
      for (final key in order) MapEntry(key, grouped[key]!),
    ];
  }

  Widget _notificationCard(
    BuildContext context,
    CmdInboxEntry n,
    DateFormat df,
  ) {
    final theme = FluentTheme.of(context);
    final user =
        n.assignedUser.trim().isEmpty ? 'Sin responsable' : n.assignedUser.trim();
    final userColor = _userColorMap[user] ?? const Color(0xFF1F77B4);
    final userAvatar = _userAvatarMap[user];
    final prColor = _priorityColor(n.priorityRank);
    final unread = !n.leido;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: unread
            ? userColor.withValues(alpha: 0.14)
            : theme.resources.subtleFillColorSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: unread
              ? prColor.withValues(alpha: 0.95)
              : theme.resources.controlStrokeColorDefault.withValues(alpha: 0.45),
          width: unread ? 1.6 : 1.0,
        ),
      ),
      child: material.Material(
        type: material.MaterialType.transparency,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: material.InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _tapItem(n),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: userColor,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      clipBehavior: Clip.antiAlias,
                      child: userAvatar != null
                          ? Image.memory(userAvatar, fit: BoxFit.cover)
                          : Text(
                              _initials(user),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        user,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                          color: theme.typography.body?.color,
                        ),
                      ),
                    ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: userColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'Nuevo',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: userColor,
                          ),
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: prColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _priorityLabel(n.priorityRank),
                        style: TextStyle(
                          color: prColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(FluentIcons.delete, size: 14),
                      onPressed: () => _eliminar(n),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  n.title,
                  style: TextStyle(
                    fontWeight: unread ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  n.body,
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 4),
                Text(
                  df.format(n.fecha.toLocal()),
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.typography.body?.color?.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final df = DateFormat('dd/MM/yyyy HH:mm');

    return ContentDialog(
      title: Row(
        children: [
          const Icon(FluentIcons.mail, size: 22),
          const SizedBox(width: 10),
          Text(
            'Buzon de notificaciones',
            style: theme.typography.title,
          ),
        ],
      ),
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: _loading
            ? const Center(child: ProgressRing())
            : _items.isEmpty
                ? Center(
                    child: Text(
                      'No hay notificaciones guardadas.\n'
                      'Las nuevas misiones asignadas a usted apareceran aqui al detectarse en segundo plano.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.typography.body?.color?.withValues(alpha: 0.75),
                        height: 1.35,
                      ),
                    ),
                  )
                : material.Scrollbar(
                    controller: _listScroll,
                    thumbVisibility: true,
                    child: ListView(
                      controller: _listScroll,
                      children: [
                        for (final section in _groupedByUser(_items)) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
                            child: Row(
                              children: [
                                Text(
                                  section.key,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: theme.accentColor,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${section.value.length} tarea(s)',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: theme.typography.caption?.color,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          for (final n in section.value) _notificationCard(context, n, df),
                        ],
                      ],
                    ),
                  ),
      ),
      actions: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                _inboxActionButton(
                  label: 'Ir a monitoreo',
                  onPressed:
                      widget.onOpenMonitoring == null
                          ? null
                          : () {
                            Navigator.of(context).pop();
                            widget.onOpenMonitoring?.call();
                          },
                ),
                _inboxActionButton(
                  label: 'Vaciar buzon',
                  onPressed: _items.isEmpty ? null : _vaciar,
                ),
                _inboxActionButton(
                  label: 'Marcar todas leidas',
                  onPressed: _items.every((e) => e.leido) ? null : _marcarTodas,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Text('Cerrar'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Botón campana + contador para la barra del Centro de Comando.
class NotificationInboxButton extends StatelessWidget {
  const NotificationInboxButton({
    super.key,
    required this.unreadCount,
    required this.onOpen,
  });

  final int unreadCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: unreadCount > 0
          ? 'Buzon: $unreadCount sin leer'
          : 'Buzon de notificaciones',
      child: IconButton(
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(FluentIcons.ringer, size: 20),
            if (unreadCount > 0)
              Positioned(
                right: -6,
                top: -6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: const material.Color(0xFFE53935),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: material.Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
        onPressed: onOpen,
      ),
    );
  }
}
