import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';

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

  @override
  void initState() {
    super.initState();
    _checkServerStatus();
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

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final data = await ApiClient.post(
        '/api/login',
        body: {
          'username': _userController.text,
          'password': _passController.text,
        },
      ) as Map<String, dynamic>;
      final String rol = data['rol'] ?? 'USER';

      // Guardar Sesión
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      await prefs.setString('loginDate', DateTime.now().toIso8601String());
      await prefs.setString('username', _userController.text);
      await prefs.setString('rol', rol);

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
      content: Stack(
        children: [
          Center(
            child: SizedBox(
              width: 300,
              child: Card(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
