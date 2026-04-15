import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/chat_windows_notification_service.dart';

class InternalChatScreen extends StatefulWidget {
  const InternalChatScreen({super.key});

  @override
  State<InternalChatScreen> createState() => _InternalChatScreenState();
}

class _InternalChatScreenState extends State<InternalChatScreen> {
  static const String _groupChatToken = '__chat_grupal__';
  static const String _groupChatTitle = 'Chat grupal';
  final TextEditingController _messageCtrl = TextEditingController();
  final ScrollController _messagesScrollCtrl = ScrollController();
  final List<Map<String, dynamic>> _users = [];
  final List<Map<String, dynamic>> _conversations = [];
  final List<Map<String, dynamic>> _messages = [];
  String _currentUser = '';
  String? _selectedUser;
  bool _loading = true;
  bool _sending = false;
  bool _buzzFlash = false;
  int _buzzShakeTick = 0;
  Timer? _buzzShakeTimer;
  Timer? _polling;
  Timer? _wsReconnectTimer;
  Timer? _wsRefreshDebounce;
  WebSocketChannel? _ws;
  bool _isRefreshing = false;
  String _userFilter = '';
  bool get _isGroupSelected => _selectedUser == _groupChatToken;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _polling?.cancel();
    _wsReconnectTimer?.cancel();
    _buzzShakeTimer?.cancel();
    _wsRefreshDebounce?.cancel();
    _ws?.sink.close();
    _messagesScrollCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  String _safeText(dynamic v) => '${v ?? ''}'.trim();

  String _formatChatTime(dynamic rawIso) {
    final s = _safeText(rawIso);
    if (s.isEmpty) return '';
    final dt = DateTime.tryParse(s)?.toLocal();
    if (dt == null) return '';
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Color _avatarColor(String key) {
    final k = _chatUserKey(key);
    var h = 0;
    for (final c in k.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    const palette = <Color>[
      Color(0xFF5C6BC0),
      Color(0xFF7B1FA2),
      Color(0xFF00897B),
      Color(0xFFE65100),
      Color(0xFFC62828),
      Color(0xFF0277BD),
      Color(0xFF6D4C41),
      Color(0xFF2E7D32),
    ];
    return palette[h % palette.length];
  }

  String _avatarLetter(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    return t.substring(0, 1).toUpperCase();
  }

  Widget _buildChatAvatar(BuildContext context, String displayName, String colorKey) {
    final bg = _avatarColor(colorKey);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        _avatarLetter(displayName),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _typingDot(BuildContext context, int index) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF505050);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Interval(index * 0.2, (index + 1) * 0.2, curve: Curves.easeInOut),
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, -2 * value),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: fill,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }

  Widget _buildSendingTypingRow(BuildContext context) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final bubble = isDark ? const Color(0xFF2D2D2D) : const Color(0xFFE8E8E8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubble,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _typingDot(context, 0),
                const SizedBox(width: 4),
                _typingDot(context, 1),
                const SizedBox(width: 4),
                _typingDot(context, 2),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildChatAvatar(context, _currentUser, _currentUser),
        ],
      ),
    );
  }

  void _scrollMessagesToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messagesScrollCtrl.hasClients) return;
      final target = _messagesScrollCtrl.position.maxScrollExtent;
      if (animated) {
        _messagesScrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      } else {
        _messagesScrollCtrl.jumpTo(target);
      }
    });
  }

  void _triggerBuzzVisual() {
    _buzzShakeTimer?.cancel();
    setState(() {
      _buzzFlash = true;
      _buzzShakeTick = 0;
    });
    _buzzShakeTimer = Timer.periodic(const Duration(milliseconds: 45), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (t.tick >= 14) {
        t.cancel();
        setState(() {
          _buzzFlash = false;
          _buzzShakeTick = 0;
        });
        return;
      }
      setState(() => _buzzShakeTick = t.tick);
    });
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    _currentUser = (prefs.getString('username') ?? '').trim();
    await ChatWindowsNotificationService.instance.init();
    await _loadUsers();
    await _loadConversations();
    if (!mounted) return;
    _connectWs();
    _polling = Timer.periodic(const Duration(seconds: 12), (_) {
      _scheduleRefresh(loadCurrentThread: _selectedUser != null);
    });
    setState(() => _loading = false);
  }

  String _wsUrl() {
    final base = kApiBaseUrl.trim().replaceFirst(RegExp(r'^http'), 'ws');
    return '$base/ws/chat/${Uri.encodeComponent(_currentUser)}';
  }

  String _chatUserKey(String v) => v.trim().toLowerCase();

  void _scheduleWsReconnect() {
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _connectWs();
    });
  }

  void _connectWs() {
    if (_currentUser.isEmpty) return;
    try {
      _wsReconnectTimer?.cancel();
      _ws = WebSocketChannel.connect(Uri.parse(_wsUrl()));
      _ws!.stream.listen((raw) {
        if (!mounted) return;
        try {
          final data = json.decode('$raw');
          if (data is! Map) return;
          final m = Map<String, dynamic>.from(data.map((k, v) => MapEntry('$k', v)));
          final kind = '${m['kind'] ?? ''}';
          final emisor = '${m['emisor'] ?? ''}';
          final receptor = '${m['receptor'] ?? ''}';
          final me = _chatUserKey(_currentUser);
          final incomingForMe =
              _chatUserKey(receptor) == me && _chatUserKey(emisor) != me;
          final incomingGroup =
              kind == 'chat_group_message' && _chatUserKey(emisor) != me;
          final selectedKey = _chatUserKey(_selectedUser ?? '');
          final affectsOpenThread = (incomingForMe &&
                  !_isGroupSelected &&
                  selectedKey == _chatUserKey(emisor)) ||
              (incomingGroup && _isGroupSelected);
          if (incomingForMe) {
            if (kind == 'chat_buzz') {
              _triggerBuzzVisual();
              displayInfoBar(
                context,
                builder: (c, close) => InfoBar(
                  title: const Text('Zumbido recibido'),
                  content: Text('$emisor te pidió atención inmediata.'),
                  severity: InfoBarSeverity.warning,
                  onClose: close,
                ),
              );
              ChatWindowsNotificationService.instance.showMessage(
                title: 'Zumbido de $emisor',
                body: 'Te pidió atención en el chat interno.',
              );
            } else {
              final body = '${m['mensaje'] ?? ''}'.trim();
              if (!affectsOpenThread) {
                ChatWindowsNotificationService.instance.showMessage(
                  title: 'Mensaje de $emisor',
                  body: body.isEmpty ? '(sin contenido)' : body,
                );
              }
            }
          }
          if (incomingGroup) {
            final body = '${m['mensaje'] ?? ''}'.trim();
            if (!affectsOpenThread) {
              ChatWindowsNotificationService.instance.showMessage(
                title: 'Chat grupal · $emisor',
                body: body.isEmpty ? '(sin contenido)' : body,
              );
            }
          }
          _scheduleRefresh(loadCurrentThread: affectsOpenThread);
        } catch (e) {
          debugPrint('Chat WS payload error: $e');
        }
      }, onDone: () {
        debugPrint('Chat WS closed, scheduling reconnect');
        _scheduleWsReconnect();
      }, onError: (e) {
        debugPrint('Chat WS stream error: $e');
        _scheduleWsReconnect();
      });
    } catch (e) {
      debugPrint('Chat WS connect error: $e');
      _scheduleWsReconnect();
    }
  }

  Future<void> _refreshData() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    try {
      await _loadConversations();
      if (_selectedUser != null) {
        if (_isGroupSelected) {
          await _loadGroupMessages();
        } else {
          await _loadMessages(_selectedUser!);
        }
        _scrollMessagesToBottom(animated: false);
      }
    } finally {
      _isRefreshing = false;
    }
  }

  void _scheduleRefresh({required bool loadCurrentThread}) {
    _wsRefreshDebounce?.cancel();
    _wsRefreshDebounce = Timer(const Duration(milliseconds: 260), () async {
      if (!mounted) return;
      if (_isRefreshing) return;
      if (loadCurrentThread) {
        await _refreshData();
      } else {
        await _loadConversations();
      }
    });
  }

  Future<void> _loadUsers() async {
    final raw = await ApiClient.get('/api/chat/usuarios');
    _users
      ..clear()
      ..add({
        'username': _groupChatToken,
        'nombre': _groupChatTitle,
      })
      ..addAll(
        (raw is List)
            ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
                .where((u) => '${u['username'] ?? ''}'.trim().isNotEmpty)
                .where((u) => '${u['username']}'.trim() != _currentUser)
                .toList()
            : [],
      );
  }

  Future<void> _loadConversations() async {
    if (_currentUser.isEmpty) return;
    final raw = await ApiClient.get('/api/chat/conversaciones/${Uri.encodeComponent(_currentUser)}');
    _conversations
      ..clear()
      ..addAll(
        (raw is List)
            ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
                .toList()
            : [],
      );
    if (mounted) setState(() {});
  }

  Future<void> _loadMessages(String otherUser) async {
    if (otherUser == _groupChatToken) {
      await _loadGroupMessages();
      return;
    }
    final raw = await ApiClient.get(
      '/api/chat/mensajes',
      queryParameters: {
        'u1': _currentUser,
        'u2': otherUser,
        'limit': '220',
      },
    );
    _messages
      ..clear()
      ..addAll(
        (raw is List)
            ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
                .toList()
            : [],
      );
    await ApiClient.put('/api/chat/leidos', body: {'lector': _currentUser, 'otro_usuario': otherUser});
    if (mounted) {
      setState(() {});
      _scrollMessagesToBottom(animated: false);
    }
  }

  Future<void> _loadGroupMessages() async {
    final raw = await ApiClient.get(
      '/api/chat/grupal/mensajes',
      queryParameters: {'limit': '220'},
    );
    _messages
      ..clear()
      ..addAll(
        (raw is List)
            ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
                .toList()
            : [],
      );
    if (mounted) {
      setState(() {});
      _scrollMessagesToBottom(animated: false);
    }
  }

  Future<void> _selectUser(String user) async {
    setState(() => _selectedUser = user);
    await _loadMessages(user);
  }

  Future<void> _sendMessage() async {
    final text = _messageCtrl.text.trim();
    if (_sending || text.isEmpty || _selectedUser == null) return;
    setState(() => _sending = true);
    try {
      if (_isGroupSelected) {
        await ApiClient.post(
          '/api/chat/grupal/mensajes',
          body: {
            'emisor': _currentUser,
            'mensaje': text,
          },
        );
      } else {
        await ApiClient.post(
          '/api/chat/mensajes',
          body: {
            'emisor': _currentUser,
            'receptor': _selectedUser,
            'mensaje': text,
          },
        );
      }
      _messageCtrl.clear();
      await _refreshData();
      _scrollMessagesToBottom();
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Error'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendBuzz() async {
    if (_selectedUser == null || _isGroupSelected) return;
    try {
      await ApiClient.post(
        '/api/chat/zumbido',
        body: {
          'emisor': _currentUser,
          'receptor': _selectedUser,
          'mensaje': '(zumbido)',
        },
      );
      await _refreshData();
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Zumbido'),
          content: Text('$e'),
          severity: InfoBarSeverity.warning,
          onClose: close,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ScaffoldPage(content: Center(child: ProgressRing()));
    }
    final shakeX =
        _buzzShakeTick == 0 ? 0.0 : (_buzzShakeTick.isEven ? -7.0 : 7.0);
    final userFilter = _userFilter.trim().toLowerCase();
    final visibleUsers = _users.where((u) {
      if (userFilter.isEmpty) return true;
      final usr = _safeText(u['username']).toLowerCase();
      final name = _safeText(u['nombre']).toLowerCase();
      return usr.contains(userFilter) || name.contains(userFilter);
    }).toList(growable: false);
    return ScaffoldPage(
      header: const PageHeader(title: Text('Chat interno')),
      content: Row(
        children: [
          SizedBox(
            width: 320,
            child: Card(
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  const Text('Usuarios', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  TextBox(
                    placeholder: 'Buscar usuario...',
                    onChanged: (v) => setState(() => _userFilter = v),
                  ),
                  const SizedBox(height: 8),
                  ...visibleUsers.map((u) {
                    final usr = '${u['username']}';
                    final isGroup = usr == _groupChatToken;
                    final conv = _conversations.firstWhere(
                      (c) => '${c['otro_usuario']}' == usr,
                      orElse: () => <String, dynamic>{},
                    );
                    final unread = int.tryParse('${conv['no_leidos'] ?? 0}') ?? 0;
                    return ListTile.selectable(
                      selected: _selectedUser == usr,
                      title: Text('${u['nombre'] ?? usr}'),
                      subtitle: Text(isGroup ? 'Sala general' : usr),
                      trailing: unread > 0
                          ? InfoBadge(source: Text('$unread'))
                          : null,
                      onPressed: () => _selectUser(usr),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Transform.translate(
              offset: Offset(shakeX, 0),
              child: Card(
                borderColor: _buzzFlash ? const Color(0xFFD32F2F) : null,
                child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selectedUser == null
                                ? 'Selecciona un usuario'
                                : (_isGroupSelected
                                    ? '$_groupChatTitle (sala general)'
                                    : 'Conversación con $_selectedUser'),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (_selectedUser != null && !_isGroupSelected)
                          Button(
                            onPressed: _sendBuzz,
                            child: const Text('Zumbido'),
                          ),
                      ],
                    ),
                  ),
                  const Divider(),
                  Expanded(
                    child: ListView.builder(
                      controller: _messagesScrollCtrl,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: _messages.length + (_sending ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _messages.length) {
                          return _buildSendingTypingRow(context);
                        }
                        final m = _messages[i];
                        final mine = '${m['emisor']}' == _currentUser;
                        final tipo = '${m['tipo'] ?? 'texto'}';
                        final baseText = tipo == 'zumbido'
                            ? '🔔 Zumbido'
                            : '${m['mensaje'] ?? ''}';
                        final emisorLabel = _safeText(m['emisor']);
                        final showSenderName =
                            !mine && _isGroupSelected && tipo != 'zumbido' && emisorLabel.isNotEmpty;
                        final text = baseText;
                        final ts = _formatChatTime(m['fecha_envio']);
                        final isDark = FluentTheme.of(context).brightness == Brightness.dark;
                        final accent = FluentTheme.of(context).accentColor;
                        final bubbleOther = isDark
                            ? const Color(0xFF2D2D2D)
                            : const Color(0xFFE8E8E8);
                        final bubbleMine = accent;
                        final textMine = Colors.white;
                        final textOther =
                            isDark ? Colors.white : Colors.black;
                        final avatarKey = mine ? _currentUser : emisorLabel;
                        final avatarLabel = mine ? _currentUser : emisorLabel;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            mainAxisAlignment:
                                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!mine) ...[
                                _buildChatAvatar(context, avatarLabel, avatarKey),
                                const SizedBox(width: 8),
                              ],
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: mine
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    if (showSenderName)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8, bottom: 4),
                                        child: Text(
                                          emisorLabel,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      constraints: const BoxConstraints(maxWidth: 520),
                                      decoration: BoxDecoration(
                                        color: mine ? bubbleMine : bubbleOther,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: mine
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            text,
                                            style: TextStyle(
                                              color: mine ? textMine : textOther,
                                            ),
                                          ),
                                          if (ts.isNotEmpty) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              ts,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: mine
                                                    ? textMine.withValues(alpha: 0.85)
                                                    : (isDark
                                                        ? Colors.white.withValues(alpha: 0.65)
                                                        : Colors.black.withValues(alpha: 0.55)),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (mine) ...[
                                const SizedBox(width: 8),
                                _buildChatAvatar(context, avatarLabel, avatarKey),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: FluentTheme.of(context).brightness == Brightness.dark
                          ? FluentTheme.of(context).scaffoldBackgroundColor
                          : Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: FluentTheme.of(context).brightness == Brightness.dark
                                ? 0.28
                                : 0.08,
                          ),
                          spreadRadius: 0,
                          blurRadius: 4,
                          offset: const Offset(0, -1),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextBox(
                            controller: _messageCtrl,
                            enabled: _selectedUser != null,
                            placeholder: 'Escribe un mensaje...',
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(
                            FluentIcons.send,
                            size: 20,
                            color: (_selectedUser == null || _sending)
                                ? Colors.grey
                                : FluentTheme.of(context).accentColor,
                          ),
                          onPressed: (_selectedUser == null || _sending) ? null : _sendMessage,
                        ),
                      ],
                    ),
                  ),
                ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
