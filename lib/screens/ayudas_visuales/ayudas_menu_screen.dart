import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import '../../theme/app_themes.dart';
import '../../widgets/compact_page_header.dart';
import 'ayudas_categoria_screen.dart';

IconData _obtenerIcono(String? codigo) {
  switch (codigo?.toLowerCase().trim()) {
    case 'build':
      return material.Icons.build;
    case 'bolt':
      return material.Icons.bolt;
    case 'format_paint':
      return material.Icons.format_paint;
    case 'water_drop':
      return material.Icons.water_drop;
    case 'whatshot':
      return material.Icons.whatshot;
    case 'brush':
      return material.Icons.brush;
    case 'security':
      return material.Icons.security;
    case 'info':
      return material.Icons.info;
    default:
      return material.Icons.folder_copy_outlined;
  }
}

/// Pantalla 1: menú de categorías (grid grande con iconos).
class AyudasMenuScreen extends StatefulWidget {
  const AyudasMenuScreen({super.key, required this.canUpload});

  final bool canUpload;

  @override
  State<AyudasMenuScreen> createState() => _AyudasMenuScreenState();
}

class _AyudasMenuScreenState extends State<AyudasMenuScreen> {
  bool _loading = true;
  String? _error;
  List<dynamic> _categorias = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/categorias');
      setState(() {
        _categorias = data is List ? data : [];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _dialogoNuevaCategoria() async {
    final nombreCtrl = TextEditingController();
    final iconoCtrl = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return ContentDialog(
            title: const Text('Nueva categoría'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Nombre'),
                const SizedBox(height: 6),
                TextBox(controller: nombreCtrl, placeholder: 'Ej. Mecánico'),
                const SizedBox(height: 12),
                const Text('Código de icono (opcional)'),
                const SizedBox(height: 6),
                TextBox(
                  controller: iconoCtrl,
                  placeholder: 'mecanico, electrico…',
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(ctx),
              ),
              FilledButton(
                child: const Text('Crear'),
                onPressed: () async {
                  final n = nombreCtrl.text.trim();
                  if (n.isEmpty) return;
                  final prefs = await SharedPreferences.getInstance();
                  final user =
                      prefs.getString('username')?.trim() ?? 'Operador';
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (lc) => const ContentDialog(
                      title: Text('Guardando…'),
                      content: Center(
                        child: SizedBox(height: 80, child: ProgressRing()),
                      ),
                    ),
                  );
                  try {
                    await ApiClient.post(
                      '/api/ayudas/categorias',
                      body: {
                        'nombre': n,
                        'icono': iconoCtrl.text.trim(),
                      },
                      headers: {'X-Usuario': user},
                    );
                    if (!mounted) return;
                    Navigator.of(context, rootNavigator: true).pop();
                    Navigator.of(context, rootNavigator: true).pop();
                    await _cargar();
                    if (mounted) {
                      displayInfoBar(context, builder: (c, close) {
                        return InfoBar(
                          title: const Text('Listo'),
                          content: const Text('Categoría creada.'),
                          severity: InfoBarSeverity.success,
                          onClose: close,
                        );
                      });
                    }
                  } catch (e) {
                    if (!mounted) return;
                    Navigator.of(context, rootNavigator: true).pop();
                    material.ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      material.SnackBar(
                        content: Text('$e'),
                        backgroundColor: material.Colors.red.shade800,
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      );
    } finally {
      nombreCtrl.dispose();
      iconoCtrl.dispose();
    }
  }

  bool _esModoCiberpunk(BuildContext context) {
    if (appTheme.currentMode == AppThemeMode.cyberpunk) return true;
    final theme = FluentTheme.of(context);
    return theme.brightness == Brightness.dark &&
        theme.typography.body?.fontFamily == 'Consolas';
  }

  @override
  Widget build(BuildContext context) {
    final isCyberpunk = _esModoCiberpunk(context);
    return ScaffoldPage(
      header: CompactPageHeader(
        title: const Text('Ayudas visuales'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _loading ? null : _cargar,
            ),
          ],
        ),
      ),
      content: Stack(
        children: [
          _loading
              ? const Center(child: ProgressRing())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: TextStyle(color: Colors.red)),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _cargar,
                              child: const Text('Reintentar'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, c) {
                        final cols = c.maxWidth >= 1000
                            ? 4
                            : c.maxWidth >= 700
                                ? 3
                                : 2;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          child: GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: cols,
                              mainAxisSpacing: 16,
                              crossAxisSpacing: 16,
                              childAspectRatio: 1.15,
                            ),
                            itemCount: _categorias.length,
                            itemBuilder: (context, i) {
                              final row =
                                  _categorias[i] as Map<String, dynamic>;
                              final id = row['ID_Categoria'];
                              final nombre = (row['Nombre_Categoria'] ??
                                      'Sin nombre')
                                  .toString();
                              final icono = row['Icono_Codigo']?.toString();
                              return _CategoriaTile(
                                titulo: nombre,
                                icon: _obtenerIcono(icono),
                                isCyberpunk: isCyberpunk,
                                onTap: () {
                                  Navigator.of(context).push(
                                    material.MaterialPageRoute<void>(
                                      builder: (_) => AyudasCategoriaScreen(
                                        idCategoria: id is int
                                            ? id
                                            : int.tryParse('$id') ?? 0,
                                        nombreCategoria: nombre,
                                        canUpload: widget.canUpload,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        );
                      },
                    ),
          if (widget.canUpload)
            Positioned(
              right: 20,
              bottom: 20,
              child: material.FloatingActionButton.extended(
                onPressed: _dialogoNuevaCategoria,
                shape: material.RoundedRectangleBorder(
                  borderRadius: material.BorderRadius.circular(24.0),
                ),
                icon: const Icon(material.Icons.add),
                label: const Text('Nueva categoría'),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoriaTile extends StatelessWidget {
  const _CategoriaTile({
    required this.titulo,
    required this.icon,
    required this.isCyberpunk,
    required this.onTap,
  });

  final String titulo;
  final IconData icon;
  final bool isCyberpunk;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderRadius = material.BorderRadius.circular(
      isCyberpunk ? 4.0 : 24.0,
    );
    final neonColors = <Color>[
      const Color(0xFF00E5FF), // cyan
      const Color(0xFFFF00D4), // magenta
      const Color(0xFFB7FF00), // lima
    ];
    final neonIndex = titulo.runes.fold<int>(0, (a, b) => a + b) %
        neonColors.length;
    final iconColor = isCyberpunk
        ? neonColors[neonIndex]
        : material.Theme.of(context).primaryColor;

    return material.Card(
      elevation: 4.0,
      shape: material.RoundedRectangleBorder(
        borderRadius: borderRadius,
      ),
      child: material.InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 56.0,
                color: iconColor,
              ),
              const SizedBox(height: 12),
              Text(
                titulo,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: FluentTheme.of(context).typography.bodyStrong,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
