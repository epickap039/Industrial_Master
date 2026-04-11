import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/app_role.dart';
import '../services/user_avatar_service.dart';
import '../widgets/compact_page_header.dart';

/// Alta y listado sobre `Tbl_Usuarios` (`GET/POST/DELETE /api/usuarios/*`).
class ConfiguracionUsuariosScreen extends StatefulWidget {
  const ConfiguracionUsuariosScreen({super.key});

  @override
  State<ConfiguracionUsuariosScreen> createState() =>
      _ConfiguracionUsuariosScreenState();
}

class _ConfiguracionUsuariosScreenState extends State<ConfiguracionUsuariosScreen> {
  bool _loading = true;
  bool _roleResolved = false;
  List<Map<String, dynamic>> _lista = [];
  final _usuario = TextEditingController();
  final _password = TextEditingController();
  String _rol = 'CALIDAD';
  String _genero = 'N';
  Uint8List? _avatarNuevoUsuario;
  bool _enviando = false;
  String _currentUsername = '';
  AppRole _currentRole = AppRole.userLegacy;

  static const List<String> _roles = [
    'ADMINISTRADOR',
    'DESARROLLADOR',
    'CALIDAD',
    'PRODUCCION',
    'INGENIERIA_METODOS',
    'GESTION',
    'COMPRAS',
    'DIRECCION',
  ];

  static const List<Map<String, String>> _generos = [
    {'value': 'F', 'label': 'Femenino'},
    {'value': 'M', 'label': 'Masculino'},
    {'value': 'N', 'label': 'Prefiero no especificar'},
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
      _roleResolved = true;
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

  Future<void> _pickAvatarNuevoUsuario() async {
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
    if (!mounted) return;
    setState(() => _avatarNuevoUsuario = bytes);
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
      final baseBody = <String, dynamic>{
        'username': u,
        'password': p,
        'rol': _rol,
      };
      try {
        await ApiClient.post(
          '/api/usuarios/crear',
          body: {...baseBody, 'genero': _genero},
        );
      } catch (_) {
        // Compatibilidad con backends que aún no aceptan "genero".
        await ApiClient.post('/api/usuarios/crear', body: baseBody);
      }
      if (!mounted) return;
      if (_avatarNuevoUsuario != null && _avatarNuevoUsuario!.isNotEmpty) {
        await UserAvatarService.instance.saveAvatarForUser(u, _avatarNuevoUsuario!);
      }
      _password.clear();
      _avatarNuevoUsuario = null;
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
          Navigator.of(ctx).pop();
          try {
            await ApiClient.delete(
              '/api/usuarios/$idInt',
              headers: {ApiClient.adminMasterPasswordHeader: password},
            );
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

  bool get _puedeGestionarUsuarios =>
      _currentRole == AppRole.administrador ||
      _currentRole == AppRole.desarrollador;

  String _rolParaCombo(String? raw) {
    final x = (raw ?? '').trim().toUpperCase();
    if (x == 'ADMIN') return 'ADMINISTRADOR';
    if (x == 'USER' || x == 'QA') return 'CALIDAD';
    for (final e in _roles) {
      if (e == x) return e;
    }
    if (x.contains('INGENIERIA')) return 'INGENIERIA_METODOS';
    return _roles.contains(x) ? x : 'CALIDAD';
  }

  String _generoParaCombo(String? raw) {
    final x = (raw ?? '').trim().toUpperCase();
    if (x == 'F' || x == 'FEMENINO' || x == 'MUJER' || x == 'FEMALE') {
      return 'F';
    }
    if (x == 'M' || x == 'MASCULINO' || x == 'HOMBRE' || x == 'MALE') {
      return 'M';
    }
    return 'N';
  }

  String _generoLabel(String raw) {
    final v = _generoParaCombo(raw);
    if (v == 'F') return 'Femenino';
    if (v == 'M') return 'Masculino';
    return 'No especificado';
  }

  Future<void> _abrirEditarRol(Map<String, dynamic> u) async {
    final id = u['id'];
    final login = '${u['username'] ?? ''}'.trim();
    if (id == null || login.isEmpty) return;
    final idInt = id is int ? id : int.tryParse('$id');
    if (idInt == null) return;
    if (login.toLowerCase() == _currentUsername.toLowerCase()) {
      _snackError('No puede cambiar el rol de su propia cuenta aquí.');
      return;
    }

    var rolSel = _rolParaCombo('${u['rol']}');
    var generoSel = _generoParaCombo(
      '${u['genero'] ?? u['Genero'] ?? u['sexo'] ?? u['Sexo'] ?? ''}',
    );
    final nuevo = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return ContentDialog(
              title: const Text('Editar rol y perfil'),
              content: SizedBox(
                width: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      login,
                      style: FluentTheme.of(context).typography.subtitle,
                    ),
                    const SizedBox(height: 12),
                    InfoLabel(
                      label: 'Rol en el sistema',
                      child: ComboBox<String>(
                        value: rolSel,
                        items: [
                          for (final e in _roles)
                            ComboBoxItem(
                              value: e,
                              child: Text(e),
                            ),
                        ],
                        onChanged: (v) => setLocal(() => rolSel = v ?? rolSel),
                      ),
                    ),
                    const SizedBox(height: 10),
                    InfoLabel(
                      label: 'Género (saludo)',
                      child: ComboBox<String>(
                        value: generoSel,
                        items: const [
                          ComboBoxItem(value: 'F', child: Text('Femenino')),
                          ComboBoxItem(value: 'M', child: Text('Masculino')),
                          ComboBoxItem(
                            value: 'N',
                            child: Text('Prefiero no especificar'),
                          ),
                        ],
                        onChanged:
                            (v) => setLocal(() => generoSel = v ?? generoSel),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Rol define accesos. Género se usa para el saludo en el Lobby.',
                      style: TextStyle(
                        fontSize: 12,
                        color: FluentTheme.of(context)
                            .typography
                            .caption
                            ?.color,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Button(
                  child: const Text('Cancelar'),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
                FilledButton(
                  child: const Text('Guardar'),
                  onPressed:
                      () => Navigator.of(ctx).pop({
                        'rol': rolSel,
                        'genero': generoSel,
                      }),
                ),
              ],
            );
          },
        );
      },
    );
    if (nuevo == null || !mounted) return;
    final rolNuevo = (nuevo['rol'] ?? rolSel).trim();
    final generoNuevo = (nuevo['genero'] ?? generoSel).trim();
    final rolActual = _rolParaCombo('${u['rol']}');
    final generoActual = _generoParaCombo(
      '${u['genero'] ?? u['Genero'] ?? u['sexo'] ?? u['Sexo'] ?? ''}',
    );

    try {
      if (rolNuevo != rolActual) {
        await ApiClient.put(
          '/api/usuarios/$idInt/rol',
          body: {'rol': rolNuevo},
        );
      }

      var generoActualizado = false;
      if (generoNuevo != generoActual) {
        try {
          await ApiClient.put(
            '/api/usuarios/$idInt/genero',
            body: {'genero': generoNuevo},
          );
          generoActualizado = true;
        } catch (_) {
          try {
            await ApiClient.put(
              '/api/usuarios/$idInt',
              body: {'genero': generoNuevo},
            );
            generoActualizado = true;
          } catch (_) {}
        }
      }

      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Usuario actualizado'),
          content: Text(
            generoNuevo != generoActual && !generoActualizado
                ? 'Rol: $rolNuevo. Género no se pudo guardar con este backend.'
                : 'Usuario $login → Rol: $rolNuevo · Género: ${_generoLabel(generoNuevo)}',
          ),
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
  }

  @override
  Widget build(BuildContext context) {
    if (!_roleResolved || _loading) {
      return const ScaffoldPage(content: Center(child: ProgressRing()));
    }

    if (!_puedeGestionarUsuarios) {
      return ScaffoldPage(
        header: CompactPageHeader(
          leading: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: IconButton(
              icon: const Icon(FluentIcons.back, size: 18),
              onPressed: () => Navigator.maybePop(context),
            ),
          ),
          title: const Text('Gestión de Usuarios'),
        ),
        content: Center(
          child: Text(
            'No tiene permiso para gestionar usuarios.',
            style: FluentTheme.of(context).typography.body,
          ),
        ),
      );
    }

    return material.ScaffoldMessenger(
      child: ScaffoldPage(
        header: CompactPageHeader(
          leading: Padding(
            padding: const EdgeInsetsDirectional.only(end: 4),
            child: IconButton(
              icon: const Icon(FluentIcons.back, size: 18),
              onPressed: () => Navigator.maybePop(context),
            ),
          ),
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
                              onChanged: (_) => setState(() {}),
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
                                  : (v) => setState(() => _rol = v ?? 'CALIDAD'),
                            ),
                          ),
                        ),
                        material.SizedBox(
                          width: 260,
                          child: InfoLabel(
                            label: 'Género (saludo)',
                            child: ComboBox<String>(
                              value: _genero,
                              items: _generos
                                  .map(
                                    (g) => ComboBoxItem(
                                      value: g['value'],
                                      child: material.Text(g['label'] ?? g['value'] ?? ''),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _enviando
                                  ? null
                                  : (v) => setState(() => _genero = v ?? 'N'),
                            ),
                          ),
                        ),
                        material.SizedBox(
                          width: 340,
                          child: InfoLabel(
                            label: 'Foto de perfil',
                            child: Row(
                              children: [
                                _AvatarCirclePreview(
                                  bytes: _avatarNuevoUsuario,
                                  fallbackLabel: _usuario.text.trim().isEmpty
                                      ? 'U'
                                      : _usuario.text.trim(),
                                  size: 44,
                                ),
                                const SizedBox(width: 10),
                                Button(
                                  onPressed:
                                      _enviando ? null : _pickAvatarNuevoUsuario,
                                  child: const Text('Subir foto'),
                                ),
                                const SizedBox(width: 8),
                                if (_avatarNuevoUsuario != null)
                                  IconButton(
                                    icon: const Icon(FluentIcons.clear, size: 14),
                                    onPressed:
                                        _enviando
                                            ? null
                                            : () => setState(
                                              () => _avatarNuevoUsuario = null,
                                            ),
                                  ),
                              ],
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
                              _AvatarCell(
                                username: username,
                                canEdit: _puedeGestionarUsuarios,
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
                              // Acciones: editar rol / borrar (misma política que backend)
                              if (_puedeGestionarUsuarios && !isCurrentUser)
                                material.Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message: 'Editar rol y permisos',
                                      child: IconButton(
                                        icon: Icon(
                                          FluentIcons.edit,
                                          size: 18,
                                          color: FluentTheme.of(context).accentColor,
                                        ),
                                        onPressed: () => _abrirEditarRol(u),
                                      ),
                                    ),
                                    Tooltip(
                                      message: 'Eliminar usuario',
                                      child: material.IconButton(
                                        icon: const material.Icon(
                                          material.Icons.delete_outline,
                                          color: material.Colors.red,
                                          size: 20,
                                        ),
                                        onPressed: () => _abrirEliminar(u),
                                      ),
                                    ),
                                  ],
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

class _AvatarCell extends StatefulWidget {
  const _AvatarCell({
    required this.username,
    required this.canEdit,
  });

  final String username;
  final bool canEdit;

  @override
  State<_AvatarCell> createState() => _AvatarCellState();
}

class _AvatarCellState extends State<_AvatarCell> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await UserAvatarService.instance.loadAvatarForUser(widget.username);
    if (!mounted) return;
    setState(() {
      _bytes = b;
      _loading = false;
    });
  }

  Future<void> _reloadFromServer() async {
    setState(() => _loading = true);
    final b = await UserAvatarService.instance.refreshAvatarFromServer(widget.username);
    if (!mounted) return;
    setState(() {
      _bytes = b;
      _loading = false;
    });
  }

  Future<void> _pickAndSave() async {
    if (!widget.canEdit) return;
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
    await UserAvatarService.instance.saveAvatarForUser(widget.username, bytes);
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: ProgressRing(strokeWidth: 2),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        material.Tooltip(
          message: widget.canEdit ? 'Click para cambiar foto' : 'Foto de perfil',
          child: material.InkWell(
            onTap: widget.canEdit ? _pickAndSave : null,
            borderRadius: material.BorderRadius.circular(10),
            child: _AvatarCirclePreview(
              bytes: _bytes,
              fallbackLabel: widget.username,
              size: 48,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: widget.canEdit ? 'Editar foto' : 'Sin permiso',
              child: IconButton(
                icon: const Icon(FluentIcons.camera, size: 14),
                onPressed: widget.canEdit ? _pickAndSave : null,
              ),
            ),
            Tooltip(
              message: 'Recargar foto',
              child: IconButton(
                icon: const Icon(FluentIcons.refresh, size: 14),
                onPressed: _reloadFromServer,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AvatarCirclePreview extends StatelessWidget {
  const _AvatarCirclePreview({
    required this.bytes,
    required this.fallbackLabel,
    required this.size,
  });

  final Uint8List? bytes;
  final String fallbackLabel;
  final double size;

  String _initials() {
    final parts = fallbackLabel
        .split(RegExp(r'[\s._-]+'))
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
    if (parts.isEmpty) return 'U';
    if (parts.length == 1) {
      final p = parts.first.toUpperCase();
      return p.length >= 2 ? p.substring(0, 2) : p;
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: FluentTheme.of(context).inactiveColor.withValues(alpha: 0.45),
          width: 1.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes != null
          ? Image.memory(bytes!, fit: BoxFit.cover)
          : Container(
              color: FluentTheme.of(context).accentColor.withValues(alpha: 0.22),
              alignment: Alignment.center,
              child: Text(
                _initials(),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: FluentTheme.of(context).accentColor,
                ),
              ),
            ),
    );
  }
}

class _ColorCellState extends State<_ColorCell> {
  String _colorHex = '#7F7F7F';
  bool _loading = true;

  material.Color _safeHexToColor(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '').toUpperCase();
    final ok = RegExp(r'^[0-9A-F]{6}$').hasMatch(cleaned);
    if (!ok) return const material.Color(0xFF7F7F7F);
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return const material.Color(0xFF7F7F7F);
    return material.Color(0xFF000000 | parsed);
  }

  @override
  void initState() {
    super.initState();
    _cargarColor();
  }

  Future<void> _cargarColor() async {
    try {
      final resp = await ApiClient.get('/api/usuarios/${widget.username}/color');
      if (!mounted) return;
      if (resp is Map) {
        final hex = (resp['color_hex'] ?? resp['colorHex'] ?? '#7F7F7F')
            .toString()
            .toUpperCase();
        final cleaned = hex.startsWith('#') ? hex : '#$hex';
        setState(() {
          _colorHex = RegExp(r'^#[0-9A-F]{6}$').hasMatch(cleaned)
              ? cleaned
              : '#7F7F7F';
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
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
        username: widget.username,
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
              color: _safeHexToColor(_colorHex),
              borderRadius: material.BorderRadius.circular(8),
              border: material.Border.all(
                color: FluentTheme.of(context).inactiveColor.withValues(alpha: 0.5),
                width: 2,
              ),
              boxShadow: [
                material.BoxShadow(
                  color: _safeHexToColor(_colorHex).withValues(alpha: 0.3),
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
    final color = _safeHexToColor(_colorHex);
    final luminance = color.computeLuminance();
    return luminance > 0.5 ? material.Colors.black87 : material.Colors.white70;
  }
}

class _SimpleColorPickerDialog extends StatefulWidget {
  const _SimpleColorPickerDialog({
    required this.username,
    required this.currentColor,
    required this.onColorSelected,
  });

  final String username;
  final String currentColor;
  final Function(String) onColorSelected;

  @override
  State<_SimpleColorPickerDialog> createState() =>
      _SimpleColorPickerDialogState();
}

class _SimpleColorPickerDialogState extends State<_SimpleColorPickerDialog> {
  static const List<MapEntry<String, String>> _colors = [
    MapEntry('#7F7F7F', 'Gris temporal'),
    MapEntry('#42A5F5', 'Azul eléctrico'),
    MapEntry('#64B5F6', 'Azul cielo'),
    MapEntry('#5C6BC0', 'Índigo'),
    MapEntry('#7E57C2', 'Violeta'),
    MapEntry('#9575CD', 'Lavanda'),
    MapEntry('#AB47BC', 'Magenta violeta'),
    MapEntry('#BA68C8', 'Lila neón'),
    MapEntry('#26C6DA', 'Cian intenso'),
    MapEntry('#00ACC1', 'Turquesa profundo'),
    MapEntry('#29B6F6', 'Azul agua'),
    MapEntry('#4FC3F7', 'Celeste frío'),
    MapEntry('#FF8A65', 'Coral suave'),
    MapEntry('#FF7043', 'Coral intenso'),
    MapEntry('#F06292', 'Rosa frambuesa'),
    MapEntry('#7986CB', 'Índigo suave'),
    MapEntry('#4DD0E1', 'Turquesa claro'),
    MapEntry('#81D4FA', 'Azul hielo'),
  ];

  late String _selected;
  Uint8List? _avatarBytes;
  bool _loadingAvatar = true;

  material.Color _safeHexToColor(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '').toUpperCase();
    final ok = RegExp(r'^[0-9A-F]{6}$').hasMatch(cleaned);
    if (!ok) return const material.Color(0xFF7F7F7F);
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return const material.Color(0xFF7F7F7F);
    return material.Color(0xFF000000 | parsed);
  }

  Future<void> _loadAvatar() async {
    final b = await UserAvatarService.instance.loadAvatarForUser(widget.username);
    if (!mounted) return;
    setState(() {
      _avatarBytes = b;
      _loadingAvatar = false;
    });
  }

  @override
  void initState() {
    super.initState();
    final normalized = widget.currentColor.toUpperCase();
    final exists = _colors.any((e) => e.key == normalized);
    _selected = exists ? normalized : '#7F7F7F';
    _loadAvatar();
  }

  @override
  Widget build(BuildContext context) {
    final selectedColor = _safeHexToColor(_selected);
    final selectedName = _colors
        .firstWhere(
          (entry) => entry.key == _selected,
          orElse: () => const MapEntry('#7F7F7F', 'Gris temporal'),
        )
        .value;

    return material.AlertDialog(
      title: material.Text('Color de ${widget.username}'),
      content: material.SingleChildScrollView(
        child: material.SizedBox(
          width: 430,
          child: material.Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              material.Container(
                padding: const material.EdgeInsets.all(16),
                decoration: material.BoxDecoration(
                  color: selectedColor.withValues(alpha: 0.12),
                  border: material.Border.all(
                    color: selectedColor.withValues(alpha: 0.45),
                    width: 2,
                  ),
                  borderRadius: material.BorderRadius.circular(12),
                ),
                child: material.Row(
                  children: [
                    material.Container(
                      width: 76,
                      height: 76,
                      padding: const material.EdgeInsets.all(3),
                      decoration: material.BoxDecoration(
                        shape: material.BoxShape.circle,
                        border: material.Border.all(color: selectedColor, width: 3),
                      ),
                      child: _loadingAvatar
                          ? const Center(child: SizedBox(width: 20, height: 20, child: ProgressRing(strokeWidth: 2)))
                          : _AvatarCirclePreview(
                              bytes: _avatarBytes,
                              fallbackLabel: widget.username,
                              size: 70,
                            ),
                    ),
                    const material.SizedBox(width: 14),
                    Expanded(
                      child: material.Column(
                        crossAxisAlignment: material.CrossAxisAlignment.start,
                        children: [
                          material.Text(
                            selectedName,
                            style: const material.TextStyle(
                              fontSize: 16,
                              fontWeight: material.FontWeight.w700,
                            ),
                          ),
                          const material.SizedBox(height: 4),
                          material.Text(
                            _selected,
                            style: material.TextStyle(
                              fontSize: 12,
                              color: material.Colors.grey[600],
                              fontFamily: 'Consolas',
                            ),
                          ),
                          const material.SizedBox(height: 4),
                          const material.Text(
                            'Si aún no eliges color, usa Gris temporal.',
                            style: material.TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const material.SizedBox(height: 20),
              material.Text(
                'Colores disponibles',
                style: const material.TextStyle(
                  fontSize: 13,
                  fontWeight: material.FontWeight.w600,
                ),
              ),
              const material.SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final entry in _colors)
                    material.Tooltip(
                      message: '${entry.value} (${entry.key})',
                      child: material.InkWell(
                        onTap: () => setState(() => _selected = entry.key),
                        borderRadius: material.BorderRadius.circular(999),
                        child: material.AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 32,
                          height: 32,
                          decoration: material.BoxDecoration(
                            shape: material.BoxShape.circle,
                            color: _safeHexToColor(entry.key),
                            border: material.Border.all(
                              color: _selected == entry.key
                                  ? material.Colors.white
                                  : material.Colors.white.withValues(alpha: 0.25),
                              width: _selected == entry.key ? 3 : 1.2,
                            ),
                            boxShadow: _selected == entry.key
                                ? [
                                    material.BoxShadow(
                                      color: _safeHexToColor(entry.key).withValues(alpha: 0.55),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : const [],
                          ),
                          child: _selected == entry.key
                              ? Center(
                                  child: material.Icon(
                                    material.Icons.check,
                                    color: _getContrastColor(entry.key),
                                    size: 16,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
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
            'Introduzca la contraseña maestra de borrado:',
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
              labelText: 'Contraseña de administración',
              hintText: 'La definida para eliminar usuarios',
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
