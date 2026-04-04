import 'package:fluent_ui/fluent_ui.dart';

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

/// Alta y listado sobre `Tbl_Usuarios` (`GET/POST /api/usuarios/*`).
class ConfiguracionUsuariosScreen extends StatefulWidget {
  const ConfiguracionUsuariosScreen({super.key});

  @override
  State<ConfiguracionUsuariosScreen> createState() =>
      _ConfiguracionUsuariosScreenState();
}

class _ConfiguracionUsuariosScreenState extends State<ConfiguracionUsuariosScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _lista = [];
  final _usuario = TextEditingController();
  final _password = TextEditingController();
  String _rol = 'USER';
  bool _enviando = false;

  static const List<String> _roles = ['USER', 'INGENIERIA', 'ADMIN'];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _usuario.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    try {
      final raw = await ApiClient.get('/api/usuarios/lista');
      if (raw is List && mounted) {
        setState(() {
          _lista = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
          _loading = false;
        });
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _crear() async {
    final u = _usuario.text.trim();
    final p = _password.text;
    if (u.length < 2 || p.length < 4) {
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Formulario'),
          content: const Text('Usuario (≥2) y contraseña (≥4) son obligatorios.'),
          severity: InfoBarSeverity.warning,
          onClose: close,
        ),
      );
      return;
    }
    setState(() => _enviando = true);
    try {
      await ApiClient.post(
        '/api/usuarios/crear',
        body: {
          'username': u,
          'password': p,
          'rol': _rol,
        },
      );
      if (!mounted) return;
      _password.clear();
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Usuario creado'),
          content: const Text('Ya puede usarse en login y como responsable en misiones.'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
      await _cargar();
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
            title: const Text('Error'),
            content: Text('$e'),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: ProgressRing());

    return ScaffoldPage(
      header: const CompactPageHeader(
        title: Text('Usuarios del sistema'),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Usuarios registrados en Tbl_Usuarios',
              style: FluentTheme.of(context).typography.subtitle?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'El responsable en Radar y misiones manuales es el nombre de usuario (login).',
              style: TextStyle(
                color: FluentTheme.of(context)
                    .typography
                    .body
                    ?.color
                    ?.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 20),
            InfoLabel(
              label: 'Usuario (login)',
              child: TextBox(
                controller: _usuario,
                placeholder: 'Único, sin espacios',
              ),
            ),
            const SizedBox(height: 12),
            InfoLabel(
              label: 'Contraseña',
              child: PasswordBox(
                controller: _password,
                placeholder: 'Mínimo 4 caracteres',
              ),
            ),
            const SizedBox(height: 12),
            InfoLabel(
              label: 'Rol',
              child: ComboBox<String>(
                value: _rol,
                items: _roles
                    .map(
                      (e) => ComboBoxItem(
                        value: e,
                        child: Text(e),
                      ),
                    )
                    .toList(),
                onChanged:
                    _enviando ? null : (v) => setState(() => _rol = v ?? 'USER'),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _enviando ? null : _crear,
              child: _enviando
                  ? const ProgressRing(strokeWidth: 2)
                  : const Text('Crear usuario'),
            ),
            const SizedBox(height: 28),
            Text(
              'Registrados (${_lista.length})',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 10),
            if (_lista.isEmpty)
              Text(
                'No hay usuarios o no se pudo cargar la lista.',
                style: TextStyle(
                  color: FluentTheme.of(context)
                      .typography
                      .body
                      ?.color
                      ?.withValues(alpha: 0.75),
                ),
              )
            else
              ..._lista.map((u) {
                final log = '${u['username'] ?? ''}';
                final rol = '${u['rol'] ?? ''}';
                final id = '${u['id'] ?? ''}';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(
                      log,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('id $id · $rol'),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
