import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import '../../widgets/compact_page_header.dart';
import 'ayudas_api_models.dart';
import 'ayudas_visor_screen.dart';

/// Pantalla 2: documentos de una categoría + nuevo documento.
class AyudasCategoriaScreen extends StatefulWidget {
  const AyudasCategoriaScreen({
    super.key,
    required this.idCategoria,
    required this.nombreCategoria,
    required this.canUpload,
  });

  final int idCategoria;
  final String nombreCategoria;
  final bool canUpload;

  @override
  State<AyudasCategoriaScreen> createState() => _AyudasCategoriaScreenState();
}

class _AyudasCategoriaScreenState extends State<AyudasCategoriaScreen> {
  bool _loading = true;
  String? _error;
  List<dynamic> _docs = [];

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
      final data = await ApiClient.get(
        '/api/ayudas/lista/${widget.idCategoria}',
      );
      setState(() {
        _docs = data is List ? data : [];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _dialogoNuevoDocumento() async {
    final tituloCtrl = TextEditingController();
    final revCtrl = TextEditingController(text: 'A');
    final vinCtrl = TextEditingController();
    String? pathPdf;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: const Text('Nuevo documento'),
          content: StatefulBuilder(
            builder: (context, setLocal) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Título'),
                    const SizedBox(height: 6),
                    TextBox(controller: tituloCtrl),
                    const SizedBox(height: 12),
                    const Text('VIN (opcional)'),
                    const SizedBox(height: 6),
                    TextBox(
                      controller: vinCtrl,
                      placeholder: 'Opcional',
                    ),
                    const SizedBox(height: 12),
                    const Text('Número de revisión'),
                    const SizedBox(height: 6),
                    TextBox(controller: revCtrl),
                    const SizedBox(height: 12),
                    Button(
                      child: Text(
                        pathPdf == null
                            ? 'Seleccionar PDF…'
                            : 'PDF: ${pathPdf!.split(RegExp(r'[\\/]')).last}',
                      ),
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['pdf'],
                        );
                        if (r != null && r.files.single.path != null) {
                          setLocal(() => pathPdf = r.files.single.path);
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(ctx),
            ),
            FilledButton(
              child: const Text('Subir'),
              onPressed: () async {
                final t = tituloCtrl.text.trim();
                if (t.isEmpty || pathPdf == null) return;
                final prefs = await SharedPreferences.getInstance();
                final user = prefs.getString('username')?.trim() ?? 'Operador';
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (lc) => const ContentDialog(
                    title: Text('Subiendo…'),
                    content: Center(
                      child: SizedBox(height: 80, child: ProgressRing()),
                    ),
                  ),
                );
                try {
                  final fields = <String, String>{
                    'id_categoria': '${widget.idCategoria}',
                    'titulo': t,
                    'numero_revision': revCtrl.text.trim(),
                    'usuario': user,
                  };
                  final v = vinCtrl.text.trim();
                  if (v.isNotEmpty) fields['vin'] = v;
                  await ApiClient.postMultipart(
                    '/api/ayudas/subir',
                    fields: fields,
                    files: {
                      'file': await ApiClient.fileField('file', pathPdf!),
                    },
                  );
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  Navigator.of(context, rootNavigator: true).pop();
                  await _cargar();
                  if (mounted) {
                    displayInfoBar(context, builder: (c, close) {
                      return InfoBar(
                        title: const Text('Listo'),
                        content: const Text('Documento creado.'),
                        severity: InfoBarSeverity.success,
                        onClose: close,
                      );
                    });
                  }
                } catch (e) {
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  showAyudasUploadError(context, e);
                }
              },
            ),
          ],
        );
      },
    );

    tituloCtrl.dispose();
    revCtrl.dispose();
    vinCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: CompactPageHeader(
        leading: IconButton(
          icon: const Icon(FluentIcons.back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.nombreCategoria),
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
                  ? Center(child: Text(_error!))
                  : _docs.isEmpty
                      ? const Center(child: Text('No hay documentos en esta categoría.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _docs.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final m = _docs[i] as Map<String, dynamic>;
                            final idAyuda = ayudasIdAyuda(m);
                            final titulo = ayudasTituloDocumento(m);
                            final idRev = ayudasIdRevision(m);
                            final numRev = ayudasNumeroRevision(m);
                            final vinTxt = ayudasVin(m);
                            return ListTile(
                              leading: const Icon(FluentIcons.pdf),
                              title: Text(titulo),
                              subtitle: Text(
                                vinTxt.isEmpty
                                    ? 'Rev. $numRev · Vigente'
                                    : 'VIN $vinTxt · Rev. $numRev',
                              ),
                              onPressed: () {
                                Navigator.of(context).push(
                                  material.MaterialPageRoute<void>(
                                    builder: (_) => AyudasVisorScreen(
                                      idAyuda: idAyuda,
                                      tituloDocumento: titulo,
                                      idRevisionInicial: idRev,
                                      canUpload: widget.canUpload,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
          if (widget.canUpload)
            Positioned(
              right: 20,
              bottom: 20,
              child: FilledButton(
                onPressed: _dialogoNuevoDocumento,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.add),
                    SizedBox(width: 8),
                    Text('Nuevo documento'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
