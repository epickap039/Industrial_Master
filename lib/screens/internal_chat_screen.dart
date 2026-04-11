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
  WebSocketChannel? _ws;
  bool get _isGroupSelected => _selectedUser == _groupChatToken;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _polling?.cancel();
    _buzzShakeTimer?.cancel();
    _ws?.sink.close();
    _messageCtrl.dispose();
    super.dispose();
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
    _polling = Timer.periodic(const Duration(seconds: 4), (_) {
      _refreshData();
    });
    setState(() => _loading = false);
  }

  String _wsUrl() {
    final base = kApiBaseUrl.trim().replaceFirst(RegExp(r'^http'), 'ws');
    return '$base/ws/chat/${Uri.encodeComponent(_currentUser)}';
  }

  void _connectWs() {
    if (_currentUser.isEmpty) return;
    try {
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
          final incomingForMe = receptor == _currentUser && emisor != _currentUser;
          final incomingGroup =
              kind == 'chat_group_message' && emisor != _currentUser;
          if (incomingForMe) {
            if (kind == 'chat_buzz') {
              if (_selectedUser == emisor) {
                _triggerBuzzVisual();
              }
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
              ChatWindowsNotificationService.instance.showMessage(
                title: 'Mensaje de $emisor',
                body: body.isEmpty ? '(sin contenido)' : body,
              );
            }
          }
          if (incomingGroup) {
            final body = '${m['mensaje'] ?? ''}'.trim();
            ChatWindowsNotificationService.instance.showMessage(
              title: 'Chat grupal · $emisor',
              body: body.isEmpty ? '(sin contenido)' : body,
            );
          }
          _refreshData();
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> _refreshData() async {
    await _loadConversations();
    if (_selectedUser != null) {
      if (_isGroupSelected) {
        await _loadGroupMessages();
      } else {
        await _loadMessages(_selectedUser!);
      }
    }
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
    if (mounted) setState(() {});
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
    if (mounted) setState(() {});
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
                  ..._users.map((u) {
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
                      padding: const EdgeInsets.all(10),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final m = _messages[i];
                        final mine = '${m['emisor']}' == _currentUser;
                        final tipo = '${m['tipo'] ?? 'texto'}';
                        final baseText = tipo == 'zumbido'
                            ? '🔔 Zumbido'
                            : '${m['mensaje'] ?? ''}';
                        final text =
                            (!mine && _isGroupSelected && tipo != 'zumbido')
                                ? '${m['emisor']}: $baseText'
                                : baseText;
                        return Align(
                          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: mine
                                  ? FluentTheme.of(context).accentColor.withValues(alpha: 0.16)
                                  : FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(text),
                          ),
                        );
                      },
                    ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.all(10),
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
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: (_selectedUser == null || _sending) ? null : _sendMessage,
                          child: const Text('Enviar'),
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
