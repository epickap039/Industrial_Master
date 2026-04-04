import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:intl/intl.dart';

import '../../../services/notification_inbox_service.dart';

/// Diálogo modal del buzón de notificaciones (Centro de Comando).
Future<void> showNotificationInboxDialog(
  BuildContext context, {
  required VoidCallback onChanged,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _NotificationInboxDialogContent(onChanged: onChanged),
  );
}

class _NotificationInboxDialogContent extends StatefulWidget {
  const _NotificationInboxDialogContent({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_NotificationInboxDialogContent> createState() =>
      _NotificationInboxDialogContentState();
}

class _NotificationInboxDialogContentState extends State<_NotificationInboxDialogContent> {
  List<CmdInboxEntry> _items = [];
  bool _loading = true;
  final material.ScrollController _listScroll = material.ScrollController();

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
    final list = await CmdInboxStore.instance.loadAll();
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
                    child: ListView.separated(
                      controller: _listScroll,
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, rowIndex) {
                        final n = _items[rowIndex];
                        return material.Material(
                          color: Colors.transparent,
                          child: material.ListTile(
                            tileColor: n.leido
                                ? null
                                : theme.accentColor.withValues(alpha: 0.08),
                            title: Text(
                              n.title,
                              style: TextStyle(
                                fontWeight:
                                    n.leido ? FontWeight.w500 : FontWeight.w800,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    n.body,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    df.format(n.fecha.toLocal()),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.typography.body?.color
                                          ?.withValues(alpha: 0.65),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(FluentIcons.delete, size: 16),
                              onPressed: () => _eliminar(n),
                            ),
                            onTap: () => _tapItem(n),
                          ),
                        );
                      },
                    ),
                  ),
      ),
      actions: [
        Button(
          onPressed: _items.isEmpty
              ? null
              : () {
                  _vaciar();
                },
          child: const Text('Vaciar buzon'),
        ),
        Button(
          onPressed: _items.every((e) => e.leido)
              ? null
              : () {
                  _marcarTodas();
                },
          child: const Text('Marcar todas leidas'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
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
