import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'; // Para acceso a navegación si es necesario (o main gestiona)

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

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });

    try {
      final response = await http.post(
        Uri.parse('http://127.0.0.1:8001/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'username': _userController.text,
          'password': _passController.text,
        }),
      );

      if (response.statusCode == 200) {
        // Guardar Sesión
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('isLoggedIn', true);
        await prefs.setString('loginDate', DateTime.now().toIso8601String());
        await prefs.setString('username', _userController.text);

        widget.onLoginSuccess();
      } else {
        setState(() {
          _error = 'Credenciales incorrectas';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error de conexión: $e';
      });
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
      content: Center(
        child: SizedBox(
          width: 300,
          child: Card(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Iniciar Sesión', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
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
                    child: Text(_error, style: TextStyle(color: Colors.red)),
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
    );
  }
}
