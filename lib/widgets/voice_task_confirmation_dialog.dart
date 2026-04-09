import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';

import '../theme/ui_tokens.dart';

/// Dialog de confirmación para tareas creadas por voz.
/// Permite editar título y asignado antes de confirmar.
/// Incluye selector obligatorio de usuario si no se detecta.
class VoiceTaskConfirmationDialog extends StatefulWidget {
  /// Datos de la tarea desde el backend
  final Map<String, dynamic> taskData;

  /// Lista de operarios disponibles para asignación
  final List<String> operarios;

  /// Callback cuando se confirma la tarea
  final Function(Map<String, dynamic>) onConfirm;

  /// Callback cuando se cancela
  final Function() onCancel;

  /// Callback para editar la tarea (abre formulario manual)
  final Function(Map<String, dynamic>) onEdit;

  /// Callback para cargar archivo de audio (modo debug)
  final Function(String)? onLoadAudioFile;

  const VoiceTaskConfirmationDialog({
    Key? key,
    required this.taskData,
    required this.operarios,
    required this.onConfirm,
    required this.onCancel,
    required this.onEdit,
    this.onLoadAudioFile,
  }) : super(key: key);

  @override
  State<VoiceTaskConfirmationDialog> createState() =>
      _VoiceTaskConfirmationDialogState();
}

class _VoiceTaskConfirmationDialogState
    extends State<VoiceTaskConfirmationDialog> {
  late TextEditingController _titleController;
  late TextEditingController _assigneeController;
  late int _priorityRank;
  String? _selectedOperario;
  bool _showOperarioDropdown = false;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.taskData['titulo'] ?? '');
    _assigneeController = TextEditingController(
      text: widget.taskData['usuario_asignado'] ?? 'PENDIENTE',
    );
    _priorityRank = widget.taskData['priority_rank'] ?? 2;

    // Determinar si mostrar dropdownButtonde operarios
    final usuarioAsignado = widget.taskData['usuario_asignado'] ?? '';
    _showOperarioDropdown = usuarioAsignado == 'PENDIENTE' ||
        usuarioAsignado.isEmpty ||
        !widget.operarios.contains(usuarioAsignado);

    if (_showOperarioDropdown && widget.operarios.isNotEmpty) {
      _selectedOperario = null;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _assigneeController.dispose();
    super.dispose();
  }

  /// Get color for priority badge
  material.Color _getPriorityColor() {
    const colores = {
      0: material.Color(0xFFE53935), // Rojo para urgente
      1: material.Color(0xFF1976D2), // Azul para importante
      2: material.Color(0xFF616161), // Gris para normal
    };
    return colores[_priorityRank] ?? material.Colors.grey;
  }

  /// Get label for priority
  String _getPriorityLabel() {
    const labels = {
      0: 'URGENTE',
      1: 'IMPORTANTE',
      2: 'NORMAL',
    };
    return labels[_priorityRank] ?? 'NORMAL';
  }

  /// Check if confirmation button should be enabled
  bool _isConfirmButtonEnabled() {
    if (_titleController.text.isEmpty) return false;

    // Si se muestra dropdown, requiere que se seleccione un operario
    if (_showOperarioDropdown) {
      return _selectedOperario != null && _selectedOperario != 'PENDIENTE';
    }

    // Si no, requiere que el campo de asignado no sea "PENDIENTE"
    final assignee = _assigneeController.text.trim();
    return assignee.isNotEmpty && assignee != 'PENDIENTE';
  }

  /// Cargar archivo de audio manualmente (modo debug)
  Future<void> _loadAudioFileDebug() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowedExtensions: ['m4a', 'wav', 'mp3'],
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        debugPrint('[VoiceDialog] Archivo cargado: $filePath');

        if (widget.onLoadAudioFile != null) {
          widget.onLoadAudioFile!(filePath);
        }
      }
    } catch (e) {
      debugPrint('[VoiceDialog] Error al cargar archivo: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: const Text('Confirmar Tarea desde Voz'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Información de la transcripción original
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FluentTheme.of(context)
                    .accentColor
                    .withValues(alpha: 0.08),
                border: Border.all(
                  color: FluentTheme.of(context)
                      .accentColor
                      .withValues(alpha: 0.3),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Transcripción original:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: material.Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.taskData['transcripcion_procesada'] ?? '',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Campo de Título (Editable)
            Text(
              'Título (editable)',
              style: FluentTheme.of(context).typography.subtitle,
            ),
            const SizedBox(height: 6),
            TextBox(
              controller: _titleController,
              placeholder: 'Título de la tarea',
              maxLines: 2,
              onChanged: (value) => setState(() {}),
            ),
            const SizedBox(height: 16),

            // Selector de Usuario (Obligatorio si se detectó "PENDIENTE")
            if (_showOperarioDropdown && widget.operarios.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: material.Colors.orange.shade50,
                  border: Border.all(
                    color: material.Colors.orange.shade300,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          FluentIcons.warning,
                          size: 16,
                          color: material.Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Seleccionar responsable (OBLIGATORIO)*',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: material.Colors.orange.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ComboBox<String>(
                      value: _selectedOperario,
                      items: widget.operarios
                          .map(
                            (op) => ComboBoxItem<String>(
                              value: op,
                              child: Text(op),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedOperario = value;
                          if (value != null) {
                            _assigneeController.text = value;
                          }
                        });
                      },
                      placeholder: Text(
                        'Selecciona un operario de la lista',
                        style: TextStyle(color: fluentSecondaryTextColor(context)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              // Campo de Asignado (TextBox si no es dropdown)
              Text(
                'Asignado a (editable)',
                style: FluentTheme.of(context).typography.subtitle,
              ),
              const SizedBox(height: 6),
              TextBox(
                controller: _assigneeController,
                placeholder: 'Nombre del usuario',
                onChanged: (value) => setState(() {}),
              ),
              const SizedBox(height: 16),
            ],

            // Prioridad (Badge visual)
            Text(
              'Prioridad detectada',
              style: FluentTheme.of(context).typography.subtitle,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _getPriorityColor().withValues(alpha: 0.12),
                border: Border.all(
                  color: _getPriorityColor().withValues(alpha: 0.5),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _getPriorityColor(),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getPriorityLabel(),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _getPriorityColor(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Minutos estimados: ${widget.taskData['minutos_estimados'] ?? 0}',
              style: fluentSecondaryTextStyle(context, fontSize: 12),
            ),
            const SizedBox(height: 16),

            // Botón para cargar audio manualmente (modo debug)
            if (widget.onLoadAudioFile != null)
              Button(
                onPressed: _loadAudioFileDebug,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.open_file, size: 14),
                    const SizedBox(width: 6),
                    const Text('Cargar audio (.m4a)'),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        // Botón CANCELAR (Rojo)
        FilledButton(
          style: ButtonStyle(
            backgroundColor: material.WidgetStateProperty.all(
              material.Colors.red.shade500,
            ),
          ),
          onPressed: () {
            widget.onCancel();
            Navigator.pop(context);
          },
          child: const Text('CANCELAR',
              style: TextStyle(color: material.Colors.white)),
        ),

        // Botón EDITAR (Abre formulario)
        FilledButton(
          style: ButtonStyle(
            backgroundColor: material.WidgetStateProperty.all(
              material.Colors.orange.shade500,
            ),
          ),
          onPressed: () {
            // Actualizar datos con cambios del usuario
            final editedData = Map<String, dynamic>.from(widget.taskData);
            editedData['titulo'] = _titleController.text;
            editedData['usuario_asignado'] = _selectedOperario ??
                _assigneeController.text; // Usa selected o textbox

            widget.onEdit(editedData);
            Navigator.pop(context);
          },
          child: const Text('EDITAR',
              style: TextStyle(color: material.Colors.white)),
        ),

        // Botón CONFIRMAR (Verde, deshabilitado si faltan datos)
        FilledButton(
          style: ButtonStyle(
            backgroundColor: material.WidgetStateProperty.all(
              _isConfirmButtonEnabled()
                  ? material.Colors.green.shade500
                  : material.Colors.grey.shade400,
            ),
          ),
          onPressed: _isConfirmButtonEnabled()
              ? () {
                  // Aplicar cambios editados
                  final confirmedData =
                      Map<String, dynamic>.from(widget.taskData);
                  confirmedData['titulo'] = _titleController.text;
                  confirmedData['usuario_asignado'] = _selectedOperario ??
                      _assigneeController.text;

                  widget.onConfirm(confirmedData);
                  Navigator.pop(context);
                }
              : null,
          child: const Text('CONFIRMAR',
              style: TextStyle(color: material.Colors.white)),
        ),
      ],
    );
  }
}

/// Helper para mostrar el dialog
Future<Map<String, dynamic>?> showVoiceTaskConfirmation(
  BuildContext context, {
  required Map<String, dynamic> taskData,
  required List<String> operarios,
  required Function(Map<String, dynamic>) onConfirm,
  required Function(Map<String, dynamic>) onEdit,
  Function(String)? onLoadAudioFile,
}) async {
  return showDialog<Map<String, dynamic>?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => VoiceTaskConfirmationDialog(
      taskData: taskData,
      operarios: operarios,
      onConfirm: onConfirm,
      onCancel: () {},
      onEdit: onEdit,
      onLoadAudioFile: onLoadAudioFile,
    ),
  );
}
