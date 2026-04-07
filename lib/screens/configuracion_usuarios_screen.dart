import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/app_role.dart';
import '../widgets/compact_page_header.dart';

const String _kDeletePassword = 'ADMIN_ING_2024';

/// Alta y listado sobre `Tbl_Usuarios` (`GET/POST/DELETE /api/usuarios/*`).
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
  String _currentUsername = '';
  AppRole _currentRole = AppRole.userLegacy;

  static const List<String> _roles = [
    'ADMINISTRADOR',
    'CALIDAD',
    'PRODUCCION',
    'INGENIERIA_METODOS',
    'GESTION',
    'COMPRAS',
    'DIRECCION',
    'USER',
    'QA',
  ];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _cargar();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _currentUsername = (prefs.getString('username') ?? '').trim();
      _currentRole = parseAppRole(prefs.getString('rol'));
    });
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
      final raw = await ApiClient.get('/api/usuarios/all');
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

  material.Color _rolBadgeColor(String rol) {
    final r = rol.toUpperCase();
    if (r == 'ADMINISTRADOR' || r == 'ADMIN') {
      return material.Colors.red.shade700;
    }
    if (r == 'CALIDAD') return material.Colors.blue.shade700;
    if (r == 'PRODUCCION' || r == 'PRODUCCIÓN') {
      return material.Colors.green.shade700;
    }
    if (r.contains('INGENIERIA')) return material.Colors.deepPurple.shade600;
    if (r == 'GESTION' || r == 'GESTIÓN') return material.Colors.teal.shade700;
    if (r == 'COMPRAS') return material.Colors.orange.shade800;
    if (r == 'DIRECCION' || r == 'DIRECCIÓN') {
      return material.Colors.indigo.shade700;
    }
    return material.Colors.grey.shade700;
  }

  void _snackError(String msg) {
    final m = material.ScaffoldMessenger.maybeOf(context);
    if (m != null) {
      m.showSnackBar(
        material.SnackBar(content: material.Text(msg)),
      );
    } else {
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Error'),
          content: Text(msg),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    }
  }

  Future<void> _abrirEliminar(Map<String, dynamic> u) async {
    final id = u['id'];
    final login = '${u['username'] ?? ''}'.trim();
    if (id == null) return;
    final idInt = id is int ? id : int.tryParse('$id');
    if (idInt == null) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => _EliminarUsuarioDialog(
        username: login,
        onConfirmar: (password) async {
          if (password != _kDeletePassword) {
            Navigator.of(ctx).pop();
            _snackError('Contraseña incorrecta.');
            return;
          }
          Navigator.of(ctx).pop();
          try {
            await ApiClient.delete('/api/usuarios/$idInt');
            if (!mounted) return;
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('Usuario eliminado'),
                content: Text('Se eliminó $login.'),
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
          }
        },
      ),
    );
  }

  bool get _puedeEliminarOtros =>
      _currentRole == AppRole.administrador;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: ProgressRing());

    return material.ScaffoldMessenger(
      child: ScaffoldPage(
        header: CompactPageHeader(
          title: Row(
            children: [
              Icon(FluentIcons.people, size: 28, color: FluentTheme.of(context).accentColor),
              const SizedBox(width: 12),
              const Text('Gestión de Usuarios'),
            ],
          ),
        ),
        content: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Sección: Crear Nuevo Usuario
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: FluentTheme.of(context).inactiveColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(FluentIcons.add_field, size: 22, color: FluentTheme.of(context).accentColor),
                        const SizedBox(width: 10),
                        Text(
                          'Crear Nuevo Usuario',
                          style: FluentTheme.of(context).typography.title?.copyWith(fontSize: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Agregue un nuevo usuario al sistema. El login será usado como responsable en misiones.',
                      style: TextStyle(
                        fontSize: 13,
                        color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 20),
                    material.Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        material.SizedBox(
                          width: 300,
                          child: InfoLabel(
                            label: 'Usuario (login)',
                            child: TextBox(
                              controller: _usuario,
                              placeholder: 'Único, sin espacios',
                            ),
                          ),
                        ),
                        material.SizedBox(
                          width: 300,
                          child: InfoLabel(
                            label: 'Contraseña',
                            child: PasswordBox(
                              controller: _password,
                              placeholder: 'Mínimo 4 caracteres',
                            ),
                          ),
                        ),
                        material.SizedBox(
                          width: 200,
                          child: InfoLabel(
                            label: 'Rol',
                            child: ComboBox<String>(
                              value: _rol,
                              items: _roles
                                  .map(
                                    (e) => ComboBoxItem(
                                      value: e,
                                      child: material.Text(e),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _enviando
                                  ? null
                                  : (v) => setState(() => _rol = v ?? 'USER'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    material.SizedBox(
                      width: 200,
                      height: 44,
                      child: FilledButton(
                        onPressed: _enviando ? null : _crear,
                        child: _enviando
                            ? const ProgressRing(strokeWidth: 2)
                            : const material.Text('Crear usuario'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              // Sección: Usuarios Registrados
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(FluentIcons.contact_list, size: 22, color: FluentTheme.of(context).accentColor),
                          const SizedBox(width: 10),
                          Text(
                            'Usuarios Registrados',
                            style: FluentTheme.of(context).typography.title?.copyWith(fontSize: 18),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: FluentTheme.of(context).accentColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: material.Text(
                          '${_lista.length} usuario${_lista.length != 1 ? 's' : ''}',
                          style: material.TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: FluentTheme.of(context).accentColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_lista.isEmpty)
                material.Center(
                  child: material.Padding(
                    padding: const EdgeInsets.symmetric(vertical: 40),
                    child: material.Column(
                      children: [
                        material.Icon(material.Icons.person_outline, size: 48, color: FluentTheme.of(context).inactiveColor),
                        const material.SizedBox(height: 12),
                        material.Text(
                          'No hay usuarios registrados',
                          style: material.TextStyle(
                            fontSize: 16,
                            color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                material.ListView.separated(
                  shrinkWrap: true,
                  physics: const material.NeverScrollableScrollPhysics(),
                  itemCount: _lista.length,
                  separatorBuilder: (_, __) => const material.SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final u = _lista[index];
                    final username = '${u['username'] ?? ''}'.trim();
                    final rol = '${u['rol'] ?? ''}'.trim();
                    final isCurrentUser = username.toLowerCase() == _currentUsername.toLowerCase();

                    return material.Material(
                      color: material.Colors.transparent,
                      child: material.InkWell(
                        onTap: null,
                        child: material.AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.all(16),
                          decoration: material.BoxDecoration(
                            color: FluentTheme.of(context).cardColor,
                            borderRadius: material.BorderRadius.circular(10),
                            border: material.Border.all(
                              color: FluentTheme.of(context).inactiveColor.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: material.Row(
                            children: [
                              // Avatar
                              material.Container(
                                width: 48,
                                height: 48,
                                decoration: material.BoxDecoration(
                                  color: FluentTheme.of(context).accentColor.withValues(alpha: 0.2),
                                  borderRadius: material.BorderRadius.circular(10),
                                ),
                                child: material.Center(
                                  child: material.Icon(
                                    FluentIcons.contact,
                                    size: 24,
                                    color: FluentTheme.of(context).accentColor,
                                  ),
                                ),
                              ),
                              const material.SizedBox(width: 16),
                              // Información del usuario
                              material.Expanded(
                                child: material.Column(
                                  crossAxisAlignment: material.CrossAxisAlignment.start,
                                  children: [
                                    material.Row(
                                      children: [
                                        material.Text(
                                          username,
                                          style: const material.TextStyle(
                                            fontWeight: material.FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                        if (isCurrentUser) ...[
                                          const material.SizedBox(width: 8),
                                          material.Container(
                                            padding: const material.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: material.BoxDecoration(
                                              color: FluentTheme.of(context).accentColor.withValues(alpha: 0.2),
                                              borderRadius: material.BorderRadius.circular(4),
                                            ),
                                            child: material.Text(
                                              'Tú',
                                              style: material.TextStyle(
                                                fontSize: 11,
                                                fontWeight: material.FontWeight.w600,
                                                color: FluentTheme.of(context).accentColor,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const material.SizedBox(height: 6),
                                    material.Row(
                                      mainAxisAlignment: material.MainAxisAlignment.spaceBetween,
                                      children: [
                                        _RolBadge(
                                          rol: rol,
                                          color: _rolBadgeColor(rol),
                                        ),
                                        _ColorCell(
                                          username: username,
                                          onColorChanged: _cargar,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const material.SizedBox(width: 16),
                              // Acciones
                              if (_puedeEliminarOtros && !isCurrentUser)
                                material.IconButton(
                                  icon: const material.Icon(
                                    material.Icons.delete_outline,
                                    color: material.Colors.red,
                                    size: 20,
                                  ),
                                  onPressed: () => _abrirEliminar(u),
                                )
                              else
                                material.SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: material.Center(
                                    child: material.Icon(
                                      material.Icons.lock_outline,
                                      size: 18,
                                      color: FluentTheme.of(context).inactiveColor,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorCell extends StatefulWidget {
  const _ColorCell({
    required this.username,
    required this.onColorChanged,
  });

  final String username;
  final VoidCallback onColorChanged;

  @override
  State<_ColorCell> createState() => _ColorCellState();
}

class _ColorCellState extends State<_ColorCell> {
  String _colorHex = '#1F77B4';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cargarColor();
  }

  Future<void> _cargarColor() async {
    try {
      final resp = await ApiClient.get('/api/usuarios/${widget.username}/color');
      if (resp is Map && mounted) {
        final hex = resp['color_hex'] ?? resp['colorHex'] ?? '#1F77B4';
        setState(() {
          _colorHex = hex.toString().toUpperCase();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cambiarColor() async {
    // Mostrar el diálogo de selección de color
    showDialog(
      context: context,
      barrierColor: material.Theme.of(context).brightness == material.Brightness.dark
          ? const material.Color(0xFF121212)
          : material.Colors.white,
      builder: (ctx) => _SimpleColorPickerDialog(
        currentColor: _colorHex,
        onColorSelected: (newColor) async {
          if (!mounted) return;
          Navigator.of(ctx).pop();
          try {
            await ApiClient.put(
              '/api/usuarios/${widget.username}/color',
              body: {'color_hex': newColor},
            );
            if (mounted) {
              await _cargarColor();
              widget.onColorChanged();
            }
          } catch (e) {
            if (mounted) {
              displayInfoBar(
                context,
                builder: (c, close) => InfoBar(
                  title: const Text('Error'),
                  content: Text('No se pudo cambiar el color: $e'),
                  severity: InfoBarSeverity.error,
                  onClose: close,
                ),
              );
            }
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 48,
        height: 32,
        child: ProgressRing(strokeWidth: 1),
      );
    }

    return material.Material(
      color: material.Colors.transparent,
      child: material.InkWell(
        onTap: _cambiarColor,
        hoverColor: material.Colors.transparent,
        child: material.Tooltip(
          message: 'Click para cambiar color',
          child: material.AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 48,
            height: 32,
            decoration: material.BoxDecoration(
              color: material.Color(int.parse('0xFF${_colorHex.replaceFirst('#', '')}')),
              borderRadius: material.BorderRadius.circular(8),
              border: material.Border.all(
                color: FluentTheme.of(context).inactiveColor.withValues(alpha: 0.5),
                width: 2,
              ),
              boxShadow: [
                material.BoxShadow(
                  color: material.Color(int.parse('0xFF${_colorHex.replaceFirst('#', '')}'))
                      .withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const material.Offset(0, 2),
                ),
              ],
            ),
            child: material.Center(
              child: material.Icon(
                material.Icons.palette,
                size: 16,
                color: _getContrastColor(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  material.Color _getContrastColor() {
    final color = material.Color(int.parse('0xFF${_colorHex.replaceFirst('#', '')}'));
    final luminance = color.computeLuminance();
    return luminance > 0.5 ? material.Colors.black87 : material.Colors.white70;
  }
}

class _SimpleColorPickerDialog extends StatefulWidget {
  const _SimpleColorPickerDialog({
    required this.currentColor,
    required this.onColorSelected,
  });

  final String currentColor;
  final Function(String) onColorSelected;

  @override
  State<_SimpleColorPickerDialog> createState() =>
      _SimpleColorPickerDialogState();
}

class _SimpleColorPickerDialogState extends State<_SimpleColorPickerDialog> {
  static const Map<String, String> _colors = {
    '#1F77B4': 'Azul',
    '#FF7F0E': 'Naranja',
    '#2CA02C': 'Verde',
    '#D62728': 'Rojo',
    '#9467BD': 'Púrpura',
    '#8C564B': 'Marrón',
    '#E377C2': 'Rosa',
    '#7F7F7F': 'Gris',
    '#BCBD22': 'Amarillo',
    '#17BECF': 'Cian',
    '#1B9E77': 'Verde oscuro',
    '#D95F02': 'Naranja oscuro',
  };

  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentColor.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final selectedColor = material.Color(int.parse('0xFF${_selected.replaceFirst('#', '')}'));
    final selectedName = _colors[_selected] ?? _selected;

    return material.AlertDialog(
      title: const material.Text('Seleccionar color para el usuario'),
      content: material.SingleChildScrollView(
        child: material.SizedBox(
          width: 360,
          child: material.Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Preview area
              material.Container(
                padding: const material.EdgeInsets.all(20),
                decoration: material.BoxDecoration(
                  color: selectedColor.withValues(alpha: 0.1),
                  border: material.Border.all(
                    color: selectedColor.withValues(alpha: 0.3),
                    width: 2,
                  ),
                  borderRadius: material.BorderRadius.circular(12),
                ),
                child: material.Column(
                  children: [
                    material.Container(
                      width: 80,
                      height: 80,
                      decoration: material.BoxDecoration(
                        color: selectedColor,
                        borderRadius: material.BorderRadius.circular(10),
                        boxShadow: [
                          material.BoxShadow(
                            color: selectedColor.withValues(alpha: 0.4),
                            blurRadius: 8,
                            offset: const material.Offset(0, 4),
                          ),
                        ],
                      ),
                    ),
                    const material.SizedBox(height: 12),
                    material.Text(
                      selectedName,
                      style: const material.TextStyle(
                        fontSize: 16,
                        fontWeight: material.FontWeight.w600,
                      ),
                    ),
                    const material.SizedBox(height: 4),
                    material.Text(
                      _selected,
                      style: material.TextStyle(
                        fontSize: 12,
                        color: material.Colors.grey[600],
                        fontFamily: 'Courier New',
                      ),
                    ),
                  ],
                ),
              ),
              const material.SizedBox(height: 20),
              // Color grid
              material.Text(
                'Colores disponibles',
                style: const material.TextStyle(
                  fontSize: 13,
                  fontWeight: material.FontWeight.w600,
                ),
              ),
              const material.SizedBox(height: 12),
              material.GridView.count(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                shrinkWrap: true,
                physics: const material.NeverScrollableScrollPhysics(),
                children: [
                  for (final entry in _colors.entries)
                    material.GestureDetector(
                      onTap: () => setState(() => _selected = entry.key),
                      child: material.AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: material.BoxDecoration(
                          color: material.Color(
                              int.parse('0xFF${entry.key.replaceFirst('#', '')}')),
                          borderRadius: material.BorderRadius.circular(8),
                          border: material.Border.all(
                            color: _selected == entry.key
                                ? material.Colors.white
                                : material.Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: _selected == entry.key
                              ? [
                                  material.BoxShadow(
                                    color: material.Color(int.parse(
                                            '0xFF${entry.key.replaceFirst('#', '')}'))
                                        .withValues(alpha: 0.5),
                                    blurRadius: 8,
                                    offset: const material.Offset(0, 4),
                                  ),
                                ]
                              : [],
                        ),
                        child: _selected == entry.key
                            ? material.Center(
                                child: material.Icon(
                                  material.Icons.check,
                                  color: _getContrastColor(entry.key),
                                  size: 20,
                                ),
                              )
                            : const material.SizedBox(),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        material.TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const material.Text('Cancelar'),
        ),
        material.FilledButton(
          onPressed: () => widget.onColorSelected(_selected),
          child: const material.Text('Aceptar'),
        ),
      ],
    );
  }

  material.Color _getContrastColor(String hexColor) {
    final color = material.Color(int.parse('0xFF${hexColor.replaceFirst('#', '')}'));
    final luminance = color.computeLuminance();
    return luminance > 0.5 ? material.Colors.black87 : material.Colors.white;
  }
}

class _RolBadge extends StatelessWidget {
  const _RolBadge({required this.rol, required this.color});

  final String rol;
  final material.Color color;

  @override
  Widget build(BuildContext context) {
    final t = rol.trim().isEmpty ? 'Sin rol' : rol;
    return material.Container(
      padding: const material.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: material.BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: material.Border.all(
          color: color.withValues(alpha: 0.4),
          width: 1.5,
        ),
        borderRadius: material.BorderRadius.circular(6),
      ),
      child: material.Text(
        t,
        style: material.TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: material.FontWeight.w600,
        ),
      ),
    );
  }
}

class _EliminarUsuarioDialog extends StatefulWidget {
  const _EliminarUsuarioDialog({
    required this.username,
    required this.onConfirmar,
  });

  final String username;
  final Future<void> Function(String password) onConfirmar;

  @override
  State<_EliminarUsuarioDialog> createState() => _EliminarUsuarioDialogState();
}

class _EliminarUsuarioDialogState extends State<_EliminarUsuarioDialog> {
  final _pwd = material.TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return material.AlertDialog(
      backgroundColor: FluentTheme.of(context).cardColor,
      title: material.Row(
        children: [
          material.Container(
            padding: const material.EdgeInsets.all(8),
            decoration: material.BoxDecoration(
              color: material.Colors.red.withValues(alpha: 0.1),
              borderRadius: material.BorderRadius.circular(6),
            ),
            child: const material.Icon(
              material.Icons.warning_amber_rounded,
              color: material.Colors.redAccent,
              size: 24,
            ),
          ),
          const material.SizedBox(width: 12),
          const material.Text('Eliminar usuario'),
        ],
      ),
      content: material.Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          material.Container(
            padding: const material.EdgeInsets.all(12),
            decoration: material.BoxDecoration(
              color: material.Colors.red.withValues(alpha: 0.08),
              border: material.Border.all(
                color: material.Colors.red.withValues(alpha: 0.2),
              ),
              borderRadius: material.BorderRadius.circular(8),
            ),
            child: material.Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                material.Text(
                  'Esta acción es permanente',
                  style: const material.TextStyle(
                    fontWeight: material.FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const material.SizedBox(height: 6),
                material.Text(
                  'Se eliminará permanentemente el usuario «${widget.username}» de la base de datos. Esta acción no se puede deshacer.',
                  style: material.TextStyle(
                    fontSize: 12,
                    color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const material.SizedBox(height: 16),
          material.Text(
            'Confirме con su contraseña:',
            style: const material.TextStyle(
              fontWeight: material.FontWeight.w500,
              fontSize: 13,
            ),
          ),
          const material.SizedBox(height: 8),
          material.TextField(
            controller: _pwd,
            obscureText: _obscurePassword,
            autofocus: true,
            decoration: material.InputDecoration(
              labelText: 'Contraseña',
              hintText: 'Ingrese su contraseña',
              border: const material.OutlineInputBorder(),
              suffixIcon: material.IconButton(
                icon: material.Icon(
                  _obscurePassword
                      ? material.Icons.visibility_off
                      : material.Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          ),
        ],
      ),
      actions: [
        material.TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const material.Text('Cancelar'),
        ),
        material.FilledButton(
          style: material.FilledButton.styleFrom(
            backgroundColor: material.Colors.red.shade700,
          ),
          onPressed: () async {
            await widget.onConfirmar(_pwd.text);
          },
          child: const material.Text('Eliminar usuario'),
        ),
      ],
    );
  }
}
