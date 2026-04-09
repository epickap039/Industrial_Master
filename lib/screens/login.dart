import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/user_avatar_service.dart';
import 'widgets/user_color_picker_dialog.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback onLoginSuccess;

  const LoginScreen({super.key, required this.onLoginSuccess});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _isLoading = false;
  String _error = '';
  bool _isServerOnline = false;
  Uint8List? _avatarBytes;
  int _avatarReq = 0;
  String? _selectedColorHex;
  Map<String, String> _usedColorsByUser = {};

  @override
  void initState() {
    super.initState();
    _checkServerStatus();
    _userController.addListener(_handleUserInputForAvatar);
    _cargarColoresOcupados();
  }

  @override
  void dispose() {
    _userController.removeListener(_handleUserInputForAvatar);
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _handleUserInputForAvatar() async {
    final username = _userController.text.trim();
    final myReq = ++_avatarReq;
    if (username.isEmpty) {
      if (mounted) setState(() => _avatarBytes = null);
      return;
    }
    final bytes = await UserAvatarService.instance.loadAvatarForUser(username);
    if (!mounted || myReq != _avatarReq) return;
    setState(() => _avatarBytes = bytes);
  }

  Future<void> _pickAvatarForTypedUser() async {
    final username = _userController.text.trim();
    if (username.length < 2) {
      setState(() {
        _error = 'Escriba primero un usuario válido para subir la foto.';
      });
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    Uint8List? bytes = picked.files.single.bytes;
    final path = picked.files.single.path;
    if (bytes == null && path != null && path.isNotEmpty) {
      bytes = await File(path).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) return;
    await UserAvatarService.instance.saveAvatarForUser(username, bytes);
    if (!mounted) return;
    setState(() {
      _avatarBytes = bytes;
      _error = '';
    });
  }

  Future<void> _checkServerStatus() async {
    final online = await ApiClient.isReachable(
      '/',
      timeout: const Duration(seconds: 3),
    );
    if (mounted) {
      setState(() {
        _isServerOnline = online;
      });
    }
  }

  Future<void> _cargarColoresOcupados() async {
    try {
      final raw = await ApiClient.get('/api/usuarios/colores-ocupados');
      if (raw is! Map) return;
      final list = raw['ocupados'];
      if (list is! List) return;
      final map = <String, String>{};
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v)));
        final user = '${m['username'] ?? ''}'.trim().toLowerCase();
        final hex = '${m['color_hex'] ?? ''}'.trim().toUpperCase();
        if (user.isNotEmpty && hex.isNotEmpty) {
          map[user] = hex;
        }
      }
      if (mounted) setState(() => _usedColorsByUser = map);
    } catch (_) {}
  }

  bool _colorDisponibleParaUsuario(String colorHex, String username) {
    final target = username.trim().toLowerCase();
    final c = colorHex.trim().toUpperCase();
    for (final entry in _usedColorsByUser.entries) {
      if (entry.value.toUpperCase() != c) continue;
      if (entry.key != target) return false;
    }
    return true;
  }

  Future<void> _elegirColorPersonal() async {
    final current = (_selectedColorHex ?? '#FF8C00').toUpperCase();
    await showUserColorPickerDialog(
      context,
      currentHex: current,
      onColorSelected: (hexColor) {
        final user = _userController.text.trim();
        if (user.isNotEmpty && !_colorDisponibleParaUsuario(hexColor, user)) {
          setState(() {
            _error = 'Ese color ya está en uso por otro usuario.';
          });
          return;
        }
        setState(() {
          _selectedColorHex = hexColor.toUpperCase();
          _error = '';
        });
      },
    );
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final data = await ApiClient.post(
        '/api/usuarios/login',
        body: {
          'username': _userController.text.trim(),
          'password': _passController.text,
        },
      ) as Map<String, dynamic>;
      final String rol = data['rol'] ?? 'USER';
      final token = data['access_token'];
      final String? accessToken = token is String && token.isNotEmpty ? token : null;
      final uname = '${data['username'] ?? _userController.text}'.trim();
      final displayName =
          '${data['nombre'] ?? data['Nombre'] ?? data['display_name'] ?? data['full_name'] ?? ''}'
              .trim();
      final userGender =
          '${data['genero'] ?? data['Genero'] ?? data['sexo'] ?? data['Sexo'] ?? data['gender'] ?? ''}'
              .trim();
      final avatarB64 =
          '${data['avatar_base64'] ?? data['avatar'] ?? data['foto_base64'] ?? ''}'
              .trim();
      final uid = data['id'];
      final int? userId = uid is int ? uid : int.tryParse('$uid');

      // Guardar Sesión
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      await prefs.setString('loginDate', DateTime.now().toIso8601String());
      await prefs.setString('username', uname.isNotEmpty ? uname : _userController.text.trim());
      if (displayName.isNotEmpty) {
        await prefs.setString('display_name', displayName);
      } else {
        await prefs.remove('display_name');
      }
      if (userGender.isNotEmpty) {
        await prefs.setString('user_gender', userGender);
      } else {
        await prefs.remove('user_gender');
      }
      if (avatarB64.isNotEmpty) {
        try {
          final avatarBytes = base64Decode(avatarB64);
          await UserAvatarService.instance.saveAvatarForUser(uname, avatarBytes);
        } catch (_) {}
      }
      if (userId != null && userId > 0) {
        await prefs.setInt('user_id', userId);
      } else {
        await prefs.remove('user_id');
      }
      await prefs.setString('rol', rol);
      if (accessToken != null) {
        await prefs.setString('access_token', accessToken);
      } else {
        await prefs.remove('access_token');
      }

      if (_selectedColorHex != null && _selectedColorHex!.isNotEmpty) {
        final wanted = _selectedColorHex!.toUpperCase();
        if (_colorDisponibleParaUsuario(wanted, uname)) {
          try {
            await ApiClient.put(
              '/api/usuarios/$uname/color',
              body: {'color_hex': wanted},
            );
          } catch (_) {
            // No bloquear login por fallo de color.
          }
        }
      }
      if (_avatarBytes != null && _avatarBytes!.isNotEmpty) {
        try {
          await UserAvatarService.instance.saveAvatarForUser(uname, _avatarBytes!);
        } catch (_) {}
      }

      if (!mounted) return;
      widget.onLoginSuccess();
      Navigator.pushReplacementNamed(context, '/main');
    } on ApiException {
      if (mounted) {
        setState(() {
          _error = 'Credenciales incorrectas';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error de conexión: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      content: Stack(
        children: [
          Center(
            child: SizedBox(
              width: 300,
              child: Card(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35),
                          width: 2,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _avatarBytes != null
                          ? Image.memory(_avatarBytes!, fit: BoxFit.cover)
                          : Container(
                              color: const Color(0xFF1F77B4).withValues(alpha: 0.25),
                              alignment: Alignment.center,
                              child: const Icon(
                                FluentIcons.contact,
                                size: 30,
                                color: Color(0xFFE2E8F0),
                              ),
                            ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Iniciar Sesión',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    InfoLabel(
                      label: 'Usuario',
                      child: TextBox(controller: _userController),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Button(
                          onPressed: _pickAvatarForTypedUser,
                          child: const Text('Subir foto de perfil'),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          onPressed: _elegirColorPersonal,
                          child: Text(
                            _selectedColorHex == null
                                ? 'Elegir mi color'
                                : 'Color: ${_selectedColorHex!}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    InfoLabel(
                      label: 'Contraseña',
                      child: TextBox(
                        controller: _passController,
                        obscureText: true,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          _error,
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    if (_isLoading)
                      const ProgressRing()
                    else
                      FilledButton(
                        onPressed: _login,
                        child: const Text('Ingresar'),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.circle_shape_solid,
                    color: _isServerOnline ? Colors.green : Colors.red,
                    size: 12,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isServerOnline
                        ? "Servidor Conectado"
                        : "Servidor Desconectado",
                    style: TextStyle(
                      color: _isServerOnline ? Colors.green : Colors.red,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(FluentIcons.refresh),
                    onPressed: _checkServerStatus,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
