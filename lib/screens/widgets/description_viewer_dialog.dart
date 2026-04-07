/// Diálogo para visualizar descripciones completas de misiones.
///
/// MEJORA INTEGRAL v15.5: Permite leer descripciones largas con
/// estadísticas y funcionalidad de copiar al portapapeles.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

/// Muestra diálogo con descripción completa
Future<void> showDescriptionViewerDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String? imagenBase64,
}) async {
  showDialog(
    context: context,
    builder:
        (BuildContext ctx) => DescriptionViewerDialog(
          title: title,
          description: description,
          imagenBase64: imagenBase64,
        ),
  );
}

class DescriptionViewerDialog extends StatefulWidget {
  final String title;
  final String description;
  final String? imagenBase64;

  const DescriptionViewerDialog({
    super.key,
    required this.title,
    required this.description,
    this.imagenBase64,
  });

  @override
  State<DescriptionViewerDialog> createState() =>
      _DescriptionViewerDialogState();
}

class _DescriptionViewerDialogState extends State<DescriptionViewerDialog> {
  bool _copiedToClipboard = false;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Copiar descripción al portapapeles
  void _copyToClipboard() {
    Clipboard.setData(ClipboardData(text: widget.description)).then((_) {
      setState(() => _copiedToClipboard = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() => _copiedToClipboard = false);
        }
      });
    });
  }

  /// Obtener estadísticas de la descripción
  Map<String, dynamic> _getStats() {
    final desc = widget.description;
    final words = desc.split(RegExp(r'\s+'));
    final lines = desc.split('\n');

    return {
      'characters': desc.length,
      'charactersNoSpaces': desc.replaceAll(RegExp(r'\s+'), '').length,
      'words': words.where((w) => w.isNotEmpty).length,
      'lines': lines.length,
      'paragraphs':
          desc.split(RegExp(r'\n\n+')).where((p) => p.trim().isNotEmpty).length,
    };
  }

  @override
  Widget build(BuildContext context) {
    final stats = _getStats();

    return ContentDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.document, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 700,
        height: 600,
        child: Column(
          children: [
            // Descripción con scroll
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  controller: _scrollController,
                  children: [
                    SelectableText(
                      widget.description,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.6,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Estadísticas
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[700], width: 1),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _StatItem(
                    icon: FluentIcons.text_field,
                    label: 'Caracteres',
                    value: '${stats['characters']}',
                  ),
                  _StatItem(
                    icon: FluentIcons.text_field,
                    label: 'Palabras',
                    value: '${stats['words']}',
                  ),
                  _StatItem(
                    icon: FluentIcons.align_left,
                    label: 'Líneas',
                    value: '${stats['lines']}',
                  ),
                  _StatItem(
                    icon: FluentIcons.document,
                    label: 'Párrafos',
                    value: '${stats['paragraphs']}',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
        FilledButton(
          onPressed: _copyToClipboard,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _copiedToClipboard ? FluentIcons.check_mark : FluentIcons.copy,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(_copiedToClipboard ? 'Copiado' : 'Copiar'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Widget para mostrar una estadística individual
class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.blue, size: 20),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
      ],
    );
  }
}
