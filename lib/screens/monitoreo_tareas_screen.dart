import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/audio_recording_service.dart';
import '../services/notification_inbox_service.dart';
import '../theme/ui_tokens.dart';
import '../widgets/bitacora_calendario_panel.dart';
import '../widgets/voice_task_confirmation_dialog.dart';
import 'monitoreo/widgets/directive_mission_card.dart';
import 'monitoreo/widgets/manual_mission_form_dialog.dart';
import 'monitoreo/widgets/mission_meta_sheet.dart';
import 'monitoreo/widgets/task_display_utils.dart';
import '../services/app_role.dart';

const List<String> _kMotivosPausa = [
  'Prioridad baja',
  'Falta de tiempo',
  'No definido',
];

/// Centro de Comando Directivo Industrial (Radar + Manual, sin IA predictiva).
class MonitoreoTareasScreen extends StatefulWidget {
  const MonitoreoTareasScreen({super.key, required this.effectiveRole});

  /// Rol efectivo (incluye simulacion admin desde [MainNav] / main.dart).
  final String effectiveRole;

  @override
  State<MonitoreoTareasScreen> createState() => _MonitoreoTareasScreenState();
}

class _MonitoreoTareasScreenState extends State<MonitoreoTareasScreen>
    with SingleTickerProviderStateMixin {
  static const String _kFiltroTodos = '__ALL__';
  static const String _kFiltroMisTareas = '__MINE__';

  bool _loading = true;
  bool _vistaCompacta = false;
  List<Map<String, dynamic>> _tareas = [];
  List<Map<String, dynamic>> _activasOrdenadas = [];

  /// Tracks which swimlane rows are collapsed. Key = usuario label.
  final Set<String> _swimlanesColapsadas = {};
  String _currentUserName = '';
  final Set<int> _checkEnProceso = {};
  final Set<int> _seenTaskIds = {};
  String _filtroUsuario = _kFiltroTodos;
  Timer? _refreshTimer;
  final material.ScrollController _activasScrollController =
      material.ScrollController();
  late final material.TabController _tabController;

  /// Estado de grabación de audio para voz
  bool _isRecordingAudio = false;
  bool _isProcessingAudio = false;
  /// null = sin verificar, true = disponible, false = no disponible
  bool? _vozWhisperDisponible;

  @override
  void initState() {
    super.initState();
    _tabController = material.TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      if (!mounted) return;
      setState(() {});
    });
    _initSesion();
    _cargar();
    _verificarVozDisponible();

    // Auto-refresco más ágil para recibir notificaciones con menor latencia.
    _refreshTimer = Timer.periodic(const Duration(seconds: 12), (timer) {
      if (mounted) _cargar(silent: true);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _refreshTimer?.cancel();
    _activasScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MonitoreoTareasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effectiveRole != widget.effectiveRole) {
      setState(() {});
    }
  }

  Future<void> _mostrarGuiaOperaciones() async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => ContentDialog(
            title: const Text('Guia de Operaciones'),
            content: const SingleChildScrollView(
              child: Text(
                'Pestana Activas: misiones en curso. Tarjetas rojas = criticas. '
                'Tarjetas amarillas = pausadas.\n\n'
                'Pestana Historial: misiones finalizadas o canceladas. '
                'Indexadas por fecha de cierre.\n\n'
                'Botones de tarjeta:\n'
                '• Pausa: pausar o reanudar la mision.\n'
                '• Checklist: ver y marcar pasos del trabajo.\n'
                '• Finalizar: cerrar una mision manual completada.\n',
              ),
            ),
            actions: [
              FilledButton(
                child: const Text('Entendido'),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
    );
  }

  Future<void> _initSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _currentUserName = (prefs.getString('username') ?? '').trim();
        });
      }
    } catch (_) {}
  }

  bool get _puedeControlarMisiones {
    final role = parseAppRole(widget.effectiveRole);
    // Desarrollador tiene todos los permisos sin limitación
    if (role == AppRole.desarrollador) return true;
    // Otros admins solo si tienen permisos de control
    return role.monitoreoCanControlMisiones;
  }

  bool get _esModoSoloLectura => !_puedeControlarMisiones;

  Future<List<Map<String, dynamic>>> _cargarBitacora(int idTarea) async {
    try {
      final raw = await ApiClient.get('/api/tareas/bitacora/$idTarea');
      if (raw is List) {
        return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  Map<String, dynamic> _normalizarTareaDeApi(Map<String, dynamic> src) {
    final t = Map<String, dynamic>.from(src);
    int? p;
    for (final k in const [
      'porcentaje_progreso',
      'Porcentaje_Progreso',
      'Progreso',
      'porcentaje',
    ]) {
      final v = t[k];
      final n = v is int ? v : int.tryParse('$v');
      if (n != null) {
        p = n;
        break;
      }
    }
    if (p == null) {
      final rawChecks = t['checklist'];
      if (rawChecks is List && rawChecks.isNotEmpty) {
        final checks = <Map<String, dynamic>>[];
        for (final e in rawChecks) {
          if (e is Map<String, dynamic>) {
            checks.add(Map<String, dynamic>.from(e));
          } else if (e is Map) {
            checks.add(
              Map<String, dynamic>.from(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        }
        if (checks.isNotEmpty) {
          p = calcularProgresoDesdeChecklist(checks);
        }
      }
    }
    final pct = (p ?? 0).clamp(0, 100);
    t['porcentaje_progreso'] = pct;
    t['Porcentaje_Progreso'] = pct;
    return t;
  }

  Future<void> _cargar({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final data = await ApiClient.get('/api/tareas/lista');
      if (data is! List) {
        if (mounted && !silent) {
          displayInfoBar(
            context,
            builder:
                (context, close) => InfoBar(
                  title: const Text('Error'),
                  content: const Text(
                    'Respuesta invalida del servidor (lista de tareas).',
                  ),
                  severity: InfoBarSeverity.error,
                  action: IconButton(
                    icon: const Icon(FluentIcons.clear),
                    onPressed: close,
                  ),
                ),
          );
        }
        setState(() {
          _tareas = [];
          _activasOrdenadas = [];
          if (!silent) _loading = false;
        });
        return;
      }
      final list = data
          .whereType<Map<String, dynamic>>()
          .map(_normalizarTareaDeApi)
          .toList();

      if (_currentUserName.isNotEmpty) {
        await CmdInboxStore.instance.pruneMissionInboxAgainstTaskList(
          list,
          _currentUserName,
        );
      }

      final pendientesMias = <Map<String, dynamic>>[];
      if (_currentUserName.isNotEmpty) {
        final u = _currentUserName.toLowerCase();
        for (final t in list) {
          if (!esMisionCentroActiva(t)) continue;
          final asignado =
              '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? ''}'.trim();
          if (asignado.isEmpty) continue;
          if (asignado.toLowerCase() != u) continue;
          pendientesMias.add(t);
        }
      }

      // Notificaciones: solo misiones **activas** del centro; primera carga rellena
      // el buzón sin incluir historial ni tareas ya cerradas.
      final primeraLectura = _seenTaskIds.isEmpty;
      for (final t in list) {
        if (!esMisionCentroActiva(t)) continue;
        final idRaw = t['id_tarea'];
        final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
        if (id == null) continue;
        final esNueva = !_seenTaskIds.contains(id);
        if (!primeraLectura && !esNueva) continue;

        final asignado =
            '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? ''}'.trim();
        final soyYo =
            asignado.isNotEmpty &&
            _currentUserName.isNotEmpty &&
            asignado.toLowerCase() == _currentUserName.toLowerCase();

        if (soyYo && mounted) {
          try {
            final titulo = '${t['titulo'] ?? ''}';
            final prRaw = t['priority_rank'] ?? t['PriorityRank'];
            final pr = prRaw is int ? prRaw : int.tryParse('$prRaw') ?? 2;
            final agregada = await CmdInboxStore.instance.addMissionAssigned(
              idTarea: id,
              titulo: titulo,
              assignedUser: asignado,
              priorityRank: pr.clamp(0, 2),
            );
            if (agregada) {
              if (!primeraLectura && mounted) {
                displayInfoBar(
                  context,
                  builder:
                      (c, close) => InfoBar(
                        title: const Text('Nueva Misión Asignada'),
                        content: Text('ID: #$id - $titulo · Guardado en el buzón'),
                        severity: InfoBarSeverity.info,
                        action: IconButton(
                          icon: const Icon(FluentIcons.clear),
                          onPressed: close,
                        ),
                      ),
                );
              }
            }
          } catch (_) {}
        }
      }

      // Actualizar IDs vistos
      for (final t in list) {
        final idRaw = t['id_tarea'];
        final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
        if (id != null) _seenTaskIds.add(id);
      }

      // Recordatorios automáticos:
      // - cada 4h si la notificación base sigue sin leer
      // - cada 24h si ya se leyó pero la misión sigue pendiente
      if (pendientesMias.isNotEmpty) {
        final reminders = await CmdInboxStore.instance.addDueMissionReminders(
          pendientesMias,
        );
        if (reminders.isNotEmpty && mounted) {
          displayInfoBar(
            context,
            builder:
                (c, close) => InfoBar(
                  title: const Text('Recordatorio de misión'),
                  content: Text(
                    reminders.length == 1
                        ? 'Tiene 1 misión pendiente por atender.'
                        : 'Tiene ${reminders.length} misiones pendientes por atender.',
                  ),
                  severity: InfoBarSeverity.warning,
                  action: IconButton(
                    icon: const Icon(FluentIcons.clear),
                    onPressed: close,
                  ),
                ),
          );
        }
      }

      final activas =
          list
              .where(esMisionCentroActiva)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
      setState(() {
        _tareas = list;
        _activasOrdenadas = activas;
        if (!silent) _loading = false;
      });
    } catch (e) {
      if (mounted && !silent) {
        displayInfoBar(
          context,
          builder:
              (context, close) => InfoBar(
                title: const Text('Error'),
                content: Text('No se pudieron cargar las tareas: $e'),
                severity: InfoBarSeverity.error,
                action: IconButton(
                  icon: const Icon(FluentIcons.clear),
                  onPressed: close,
                ),
              ),
        );
      }
      setState(() {
        _tareas = [];
        _activasOrdenadas = [];
        _loading = false;
      });
    }
  }

  void _aplicarEstadoLocalPorProgreso(Map<String, dynamic> task, int p) {
    if (esCancelada(task)) return;
    if (esPausada(task)) return;
    if (p <= 0) {
      task['estado'] = 'Pendiente';
    } else if (p >= 100) {
      task['estado'] = 'Terminado';
    } else {
      task['estado'] = 'En Proceso';
    }
    task['Estado'] = task['estado'];
  }

  Future<void> _marcarChecklistItem(
    int idTarea,
    Map<String, dynamic> check,
    bool? nuevoValor,
  ) async {
    final idCheck = idCheckDe(check);
    if (idCheck == null) return;
    if (_checkEnProceso.contains(idCheck)) return;
    final hecho = nuevoValor ?? false;
    Map<String, dynamic>? snapshotTask;
    int snapshotTaskIndex = -1;
    setState(() {
      _checkEnProceso.add(idCheck);
      final ti = _tareas.indexWhere((x) {
        final id = x['id_tarea'];
        final a = id is int ? id : int.tryParse('$id');
        return a == idTarea;
      });
      if (ti < 0) return;
      snapshotTaskIndex = ti;
      snapshotTask = Map<String, dynamic>.from(_tareas[ti]);
      final task = Map<String, dynamic>.from(_tareas[ti]);
      final rawList = task['checklist'] as List<dynamic>? ?? [];
      final list = <Map<String, dynamic>>[];
      for (final e in rawList) {
        if (e is Map<String, dynamic>) {
          list.add(Map<String, dynamic>.from(e));
        } else if (e is Map) {
          list.add(
            Map<String, dynamic>.from(
              e.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
      final ci = list.indexWhere((c) => idCheckDe(c) == idCheck);
      if (ci >= 0) {
        list[ci] = Map<String, dynamic>.from(list[ci])..['completado'] = hecho ? 1 : 0;
        task['checklist'] = list;
        final pct = calcularProgresoDesdeChecklist(list);
        task['porcentaje_progreso'] = pct;
        _aplicarEstadoLocalPorProgreso(task, pct);
        _tareas[ti] = task;
      }
      _activasOrdenadas =
          _tareas
              .where(esMisionCentroActiva)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
    });
    try {
      await ApiClient.put(
        '/api/tareas/check/$idCheck',
        body: {'completado': hecho},
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          if (snapshotTask != null && snapshotTaskIndex >= 0) {
            _tareas[snapshotTaskIndex] = Map<String, dynamic>.from(snapshotTask!);
            _activasOrdenadas =
                _tareas
                    .where(esMisionCentroActiva)
                    .map((x) => Map<String, dynamic>.from(x))
                    .toList();
          }
        });
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text('$e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _checkEnProceso.remove(idCheck));
      } else {
        _checkEnProceso.remove(idCheck);
      }
    }
  }

  int _nivelPrioridadUiDesdeRank(Map<String, dynamic> t) {
    final r = t['priority_rank'] ?? t['PriorityRank'];
    final n = r is int ? r : int.tryParse('$r');
    if (n == null) return 3;
    if (n <= 0) return 1;
    if (n == 1) return 2;
    return 3;
  }

  Future<void> _dialogoAsignarPrioridad(int idTarea) async {
    if (!_puedeControlarMisiones) return;
    final t = _tareaActivaPorId(idTarea);
    if (t == null) return;
    final r = await showAsignarPrioridadMissionDialog(
      context,
      nivelInicial: _nivelPrioridadUiDesdeRank(t),
    );
    if (r == null || !mounted) return;
    await _aplicarPrioridadMision(idTarea, r.nivel, r.suspenderOtras);
  }

  Future<void> _dialogoEditarMisionManual(int idTarea) async {
    final idx = _tareas.indexWhere((x) {
      final id = x['id_tarea'];
      final a = id is int ? id : int.tryParse('$id');
      return a == idTarea;
    });
    if (idx < 0) return;
    final task = Map<String, dynamic>.from(_tareas[idx]);
    if (!esManualSource(task)) return;

    var responsablesLista = List<String>.from(kResponsablesMisionFallback);
    try {
      dynamic raw;
      try {
        raw = await ApiClient.get('/api/usuarios/all');
      } catch (_) {
        raw = await ApiClient.get('/api/usuarios/lista');
      }
      if (raw is List && raw.isNotEmpty) {
        final nom =
            raw
                .map((e) => Map<String, dynamic>.from(e as Map))
                .map((u) {
                  final w = '${u['username'] ?? ''}'.trim();
                  if (w.isNotEmpty) return w;
                  return '${u['nombre'] ?? ''}'.trim();
                })
                .where((s) => s.isNotEmpty)
                .toList();
        if (nom.isNotEmpty) responsablesLista = nom;
      }
    } catch (_) {}

    if (!mounted) return;

    final tituloCtrl = TextEditingController(text: tituloMision(task));
    final descCtrl = TextEditingController(text: descripcionMision(task));
    final minsRaw = task['minutos_estimados'] ?? task['Duracion_Minutos'] ?? 0;
    final minsVal = minsRaw is int ? minsRaw : int.tryParse('$minsRaw') ?? 0;
    final d = minsVal ~/ (24 * 60);
    final rem = minsVal % (24 * 60);
    final h = rem ~/ 60;
    final mi = rem % 60;
    final daysCtrl = TextEditingController(text: '$d');
    final horasCtrl = TextEditingController(text: '$h');
    final minsCtrl = TextEditingController(text: '$mi');
    final rawChecks = (task['checklist'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from((e as Map).map((k, v) => MapEntry('$k', v))))
        .toList();
    final checksCtrl = TextEditingController(
      text: rawChecks
          .map((e) => (e['nombre'] ?? '').toString().trim())
          .where((e) => e.isNotEmpty)
          .join('\n'),
    );
    final meta = metaMapTarea(task) ?? <String, dynamic>{};
    var sinTiempo = meta['sin_tiempo_estimado'] == true;
    var quitarImagen = false;
    String? nuevaImagen;

    final asignadosLista = usuariosAsignadosLista(task);
    final asignadoTxt = asignadoMision(task);
    final upperTodos = kTodosResponsablesToken.toUpperCase();
    var asignarATodos = asignadosLista.any(
      (u) =>
          u.trim().toUpperCase() == upperTodos ||
          u.trim().toUpperCase() == 'TODOS',
    );
    final seleccionados = <String>{
      for (final u in asignadosLista)
        if (u.trim().toUpperCase() != '__TODOS__' &&
            u.trim().toUpperCase() != 'TODOS')
          u.trim(),
    };
    for (final u in asignadosLista) {
      if (!responsablesLista.contains(u)) {
        responsablesLista = [...responsablesLista, u];
      }
    }
    String? responsableSel;
    if (asignarATodos) {
      responsableSel =
          responsablesLista.contains(kTodosResponsablesToken)
              ? kTodosResponsablesToken
              : (responsablesLista.isNotEmpty ? responsablesLista.first : null);
    } else if (asignadoTxt.isNotEmpty && asignadoTxt != 'Sin asignar') {
      responsableSel = asignadoTxt;
    } else if (seleccionados.isNotEmpty) {
      responsableSel = seleccionados.first;
    } else if (responsablesLista.isNotEmpty) {
      responsableSel = responsablesLista.first;
    }
    if (responsableSel != null &&
        !responsablesLista.contains(responsableSel)) {
      responsablesLista = [responsableSel!, ...responsablesLista];
    }
    var asignarMultiples = asignarATodos || seleccionados.length > 1;

    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              return ContentDialog(
                title: Text('Editar misión manual #$idTarea'),
                content: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextBox(controller: tituloCtrl, placeholder: 'Título'),
                        const SizedBox(height: 8),
                        TextBox(
                          controller: descCtrl,
                          placeholder: 'Descripción',
                          maxLines: 3,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tiempo estimado',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: FluentTheme.of(ctx).typography.body?.color,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Días',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: FluentTheme.of(
                                        ctx,
                                      ).inactiveColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  TextBox(
                                    controller: daysCtrl,
                                    enabled: !sinTiempo,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Horas',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: FluentTheme.of(
                                        ctx,
                                      ).inactiveColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  TextBox(
                                    controller: horasCtrl,
                                    enabled: !sinTiempo,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Minutos',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: FluentTheme.of(
                                        ctx,
                                      ).inactiveColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  TextBox(
                                    controller: minsCtrl,
                                    enabled: !sinTiempo,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Checkbox(
                          checked: sinTiempo,
                          content: const Text('No aplica tiempo'),
                          onChanged:
                              (v) => setLocal(() => sinTiempo = v ?? false),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Responsable (usuario de sistema)',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: FluentTheme.of(ctx).inactiveColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        ComboBox<String>(
                          value: responsableSel,
                          isExpanded: true,
                          placeholder: const Text('Seleccione'),
                          items:
                              responsablesLista
                                  .map(
                                    (e) => ComboBoxItem(
                                      value: e,
                                      child: Text(e),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (v) {
                            setLocal(() {
                              responsableSel = v;
                              final sv = (v ?? '').trim();
                              if (sv.isNotEmpty) {
                                seleccionados.add(sv);
                              }
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        Checkbox(
                          checked: asignarMultiples,
                          content: const Text('Asignar a más de una persona'),
                          onChanged:
                              (v) => setLocal(() => asignarMultiples = v ?? false),
                        ),
                        if (asignarMultiples) ...[
                          Checkbox(
                            checked: asignarATodos,
                            content: const Text(
                              'Asignar a todos los usuarios del sistema',
                            ),
                            onChanged:
                                (v) => setLocal(() => asignarATodos = v ?? false),
                          ),
                          if (!asignarATodos)
                            Container(
                              constraints: const BoxConstraints(maxHeight: 140),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: FluentTheme.of(ctx).resources.dividerStrokeColorDefault,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: ListView(
                                shrinkWrap: true,
                                children: [
                                  for (final usr in responsablesLista)
                                    Checkbox(
                                      checked: seleccionados.contains(usr),
                                      content: Text(usr),
                                      onChanged:
                                          (v) => setLocal(() {
                                            if (v == true) {
                                              seleccionados.add(usr);
                                            } else {
                                              seleccionados.remove(usr);
                                            }
                                          }),
                                    ),
                                ],
                              ),
                            ),
                        ],
                        const SizedBox(height: 8),
                        TextBox(
                          controller: checksCtrl,
                          placeholder: 'Checklist (1 línea por ítem)',
                          maxLines: 7,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Button(
                              onPressed: () async {
                                final picked =
                                    await FilePicker.platform.pickFiles(
                                      type: FileType.image,
                                      withData: true,
                                    );
                                final bytes =
                                    (picked == null || picked.files.isEmpty)
                                        ? null
                                        : picked.files.first.bytes;
                                if (bytes == null || bytes.isEmpty) return;
                                setLocal(() {
                                  nuevaImagen = base64Encode(bytes);
                                  quitarImagen = false;
                                });
                              },
                              child: const Text('Cambiar imagen'),
                            ),
                            ToggleSwitch(
                              checked: quitarImagen,
                              onChanged:
                                  (v) => setLocal(() => quitarImagen = v),
                              content: const Text('Quitar imagen actual'),
                            ),
                            if (nuevaImagen != null)
                              const Text('Imagen nueva lista para guardar'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  Button(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Guardar cambios'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (ok != true || !mounted) return;

      final principal = (responsableSel ?? '').trim();
      if (principal.isEmpty && !asignarATodos) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Responsable'),
                content: const Text('Seleccione un responsable principal.'),
                severity: InfoBarSeverity.warning,
                onClose: close,
              ),
        );
        return;
      }
      if (asignarMultiples &&
          !asignarATodos &&
          seleccionados.isEmpty &&
          principal.isEmpty) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Responsables'),
                content: const Text(
                  'Marque al menos un usuario o el responsable principal.',
                ),
                severity: InfoBarSeverity.warning,
                onClose: close,
              ),
        );
        return;
      }

      final lines = checksCtrl.text
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final checklist = lines
          .map(
            (line) => <String, dynamic>{
              'nombre': line,
              'minutos': 0,
              'grupo': kGrupoJerarquiaIndefinida,
            },
          )
          .toList();

      final List<String> responsablesBody;
      if (asignarATodos) {
        responsablesBody = [kTodosResponsablesToken];
      } else if (asignarMultiples) {
        responsablesBody = seleccionados.toList();
      } else {
        responsablesBody = <String>[];
      }

      await ApiClient.put(
        '/api/tareas/manual/$idTarea',
        body: {
          'titulo': tituloCtrl.text.trim(),
          'descripcion': descCtrl.text.trim(),
          'responsable': principal,
          'responsables': responsablesBody,
          'minutos_estimados': sinTiempo
              ? 0
              : ((int.tryParse(daysCtrl.text.trim()) ?? 0) * 24 * 60) +
                  ((int.tryParse(horasCtrl.text.trim()) ?? 0) * 60) +
                  (int.tryParse(minsCtrl.text.trim()) ?? 0),
          'sin_tiempo_estimado': sinTiempo,
          'checklist': checklist,
          if (nuevaImagen != null) 'imagen_base64': nuevaImagen,
          if (quitarImagen) 'eliminar_imagen': true,
        },
      );
      if (!mounted) return;
      await _cargar();
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Misión actualizada'),
          content: const Text(
            'Datos, responsables, tiempo, checklist e imagen guardados.',
          ),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Error'),
          content: Text('No se pudo editar la misión: $e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      tituloCtrl.dispose();
      descCtrl.dispose();
      daysCtrl.dispose();
      horasCtrl.dispose();
      minsCtrl.dispose();
      checksCtrl.dispose();
    }
  }

  Map<String, dynamic>? _tareaActivaPorId(int idTarea) {
    for (final t in _activasOrdenadas) {
      final id = t['id_tarea'];
      final a = id is int ? id : int.tryParse('$id');
      if (a == idTarea) return t;
    }
    return null;
  }

  Future<void> _aplicarPrioridadMision(
    int idTarea,
    int nivel,
    bool suspender,
  ) async {
    if (!_puedeControlarMisiones) return;
    final idx = _activasOrdenadas.indexWhere((t) {
      final id = t['id_tarea'];
      final a = id is int ? id : int.tryParse('$id');
      return a == idTarea;
    });
    if (idx < 0) return;

    final copy = List<Map<String, dynamic>>.from(_activasOrdenadas);
    final item = copy.removeAt(idx);
    final int insertAt;
    if (nivel == 1) {
      insertAt = 0;
    } else if (nivel == 2) {
      insertAt = copy.isEmpty ? 0 : 1;
    } else {
      insertAt = copy.length;
    }
    copy.insert(insertAt, item);
    setState(() => _activasOrdenadas = copy);

    final doSuspend = suspender && nivel == 1;
    final forced = <int, int>{idTarea: (nivel - 1).clamp(0, 2)};
    final ok = await _persistirReorden(
      suspenderOtrasMismoResponsable: doSuspend,
      idTareaPrioridadUrgente: doSuspend ? idTarea : null,
      forcedRankById: forced,
    );
    if (!mounted) return;
    if (ok) {
      await _cargar();
      if (!mounted) return;
      if (doSuspend) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Prioridad crítica'),
                content: const Text(
                  'Orden actualizado. Las demás tareas del mismo responsable quedaron en pausa (Prioridad Urgente asignada).',
                ),
                severity: InfoBarSeverity.warning,
                onClose: close,
              ),
        );
      }
    }
  }

  Future<void> _dialogoCancelarMision(int idTarea) async {
    final ctrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setLocal) {
              return ContentDialog(
                title: const Text('Cancelar mision'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Indique el motivo de cancelacion (obligatorio, min. 3 caracteres).',
                    ),
                    const SizedBox(height: 12),
                    TextBox(
                      controller: ctrl,
                      placeholder: 'Motivo de cancelacion',
                      maxLines: 4,
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ],
                ),
                actions: [
                  Button(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Volver'),
                  ),
                  FilledButton(
                    onPressed:
                        ctrl.text.trim().length < 3
                            ? null
                            : () => Navigator.pop(ctx, true),
                    child: const Text('Cancelar mision'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (ok != true) return;
      final motivo = ctrl.text.trim();
      if (motivo.length < 3) return;
      await ApiClient.put(
        '/api/tareas/cancelar/$idTarea',
        body: {'motivo_cancelacion': motivo},
      );
      if (!mounted) return;
      await _cargar();
      if (!mounted) return;
      displayInfoBar(
        context,
        builder:
            (c, close) => InfoBar(
              title: const Text('Mision cancelada'),
              content: const Text('El estado se actualizo a Cancelado.'),
              severity: InfoBarSeverity.warning,
              onClose: close,
            ),
      );
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text('$e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _dialogoPausar(int idTarea) async {
    String motivo = _kMotivosPausa.last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return ContentDialog(
              title: const Text('Pausar mision'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Seleccione el motivo de pausa (obligatorio).'),
                  const SizedBox(height: 12),
                  ComboBox<String>(
                    value: motivo,
                    items:
                        _kMotivosPausa
                            .map((e) => ComboBoxItem(value: e, child: Text(e)))
                            .toList(),
                    onChanged: (v) => setLocal(() => motivo = v ?? motivo),
                  ),
                ],
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Volver'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Confirmar pausa'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    try {
      await ApiClient.put(
        '/api/tareas/estado/$idTarea',
        body: {'estado': 'Pausado', 'motivo_pausa': motivo},
      );
      if (!mounted) return;
      await _cargar();
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text('$e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    }
  }

  Future<void> _reanudarMision(int idTarea) async {
    try {
      await ApiClient.put(
        '/api/tareas/estado/$idTarea',
        body: {'estado': 'En Proceso'},
      );
      if (!mounted) return;
      await _cargar();
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text('$e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    }
  }

  Future<void> _finalizarManualMision(int idTarea) async {
    try {
      await ApiClient.put('/api/tareas/finalizar_manual/$idTarea');
      if (!mounted) return;
      displayInfoBar(
        context,
        builder:
            (c, close) => InfoBar(
              title: const Text('Misión finalizada'),
              content: const Text('Progreso al 100 % y estado Terminado.'),
              severity: InfoBarSeverity.success,
              onClose: close,
            ),
      );
      await _cargar();
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text('$e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    }
  }

  Future<bool> _persistirReorden({
    bool suspenderOtrasMismoResponsable = false,
    int? idTareaPrioridadUrgente,
    Map<int, int>? forcedRankById,
  }) async {
    final soloServidor =
        _activasOrdenadas.where((t) {
          final id = t['id_tarea'];
          final n = id is int ? id : int.tryParse('$id');
          return n != null && n >= 1;
        }).toList();
    if (soloServidor.isEmpty) {
      return true;
    }
    final body = <String, dynamic>{
      'items': List<Map<String, dynamic>>.generate(
        soloServidor.length,
        (i) => {
          'id_tarea': soloServidor[i]['id_tarea'],
          'priority_rank':
              (() {
                final id = soloServidor[i]['id_tarea'];
                final idInt = id is int ? id : int.tryParse('$id');
                if (idInt != null &&
                    forcedRankById != null &&
                    forcedRankById.containsKey(idInt)) {
                  final pr = forcedRankById[idInt]!;
                  return pr < 0 ? 0 : pr;
                }
                return i;
              })(),
        },
      ),
      if (suspenderOtrasMismoResponsable &&
          idTareaPrioridadUrgente != null &&
          idTareaPrioridadUrgente >= 1) ...{
        'suspender_otras_mismo_responsable': true,
        'id_tarea_prioridad_urgente': idTareaPrioridadUrgente,
      },
    };
    try {
      debugPrint(
        'JSON ENVIADO A /reordenar (Prioridades): ${jsonEncode(body)}',
      );
      await ApiClient.put('/api/tareas/reordenar', body: body);
      return true;
    } catch (e) {
      debugPrint('Error 500 en prioridades: $e');
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (c, close) => InfoBar(
                title: const Text('Reordenar / Prioridad'),
                content: Text(
                  'No se pudo actualizar prioridad.\nError: $e\nJSON: ${jsonEncode(body)}',
                ),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
      await _cargar();
      return false;
    }
  }

  void _moveActivaEnGrid(int index, int delta) {
    if (!_puedeControlarMisiones) return;
    final j = index + delta;
    if (j < 0 || j >= _activasOrdenadas.length) return;
    setState(() {
      final a = _activasOrdenadas[index];
      _activasOrdenadas[index] = _activasOrdenadas[j];
      _activasOrdenadas[j] = a;
    });
    unawaited(_persistirReorden());
  }

  Future<void> _abrirAltaManual() async {
    final ok = await showManualMissionFormDialog(context);
    if (ok && mounted) await _cargar();
  }

  bool _isDark(BuildContext context) {
    final b = material.Theme.of(context).brightness;
    return b == Brightness.dark;
  }

  Future<void> _reactivarTareaHistorial(Map<String, dynamic> tarea) async {
    final id = tarea['id_tarea'];
    final idTarea = id is int ? id : int.tryParse('$id');
    if (idTarea == null) return;
    try {
      await ApiClient.put('/api/tareas/historial/$idTarea/reactivar');
      if (!mounted) return;
      await _cargar();
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Tarea reactivada'),
          content: Text('La misión #$idTarea volvió a activas.'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
      _tabController.index = 0;
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Error'),
          content: Text('No se pudo reactivar: $e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    }
  }

  Future<void> _eliminarTareaHistorial(Map<String, dynamic> tarea) async {
    final id = tarea['id_tarea'];
    final idTarea = id is int ? id : int.tryParse('$id');
    if (idTarea == null) return;
    final pwdCtrl = TextEditingController();
    try {
      final masterPwd = await showDialog<String?>(
        context: context,
        builder:
            (ctx) => ContentDialog(
              title: const Text('Eliminar misión del historial'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Se eliminará de forma permanente la misión #$idTarea.\n'
                    'Ingrese contraseña maestra para confirmar.',
                  ),
                  const SizedBox(height: 10),
                  TextBox(
                    controller: pwdCtrl,
                    obscureText: true,
                    placeholder: 'Contraseña maestra',
                  ),
                ],
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, pwdCtrl.text.trim()),
                  child: const Text('Eliminar'),
                ),
              ],
            ),
      );
      if ((masterPwd ?? '').isEmpty) return;
      await ApiClient.delete(
        '/api/tareas/historial/$idTarea',
        headers: {ApiClient.adminMasterPasswordHeader: masterPwd!},
      );
      if (!mounted) return;
      await _cargar();
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Eliminada'),
          content: Text('La misión #$idTarea fue eliminada del historial.'),
          severity: InfoBarSeverity.warning,
          onClose: close,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Error'),
          content: Text('No se pudo eliminar: $e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      pwdCtrl.dispose();
    }
  }

  /// ─────────────────── GRABACION DE AUDIO POR VOZ ─────────────────────────

  Future<void> _verificarVozDisponible() async {
    try {
      final resp = await ApiClient.get('/api/tareas/voz/disponible');
      if (mounted) {
        setState(() {
          _vozWhisperDisponible =
              (resp is Map) && (resp['whisper_disponible'] == true);
        });
      }
    } catch (_) {
      // Si no se puede verificar, dejamos null para no bloquear el boton
    }
  }

  /// Iniciar/detener grabacion de audio para crear tarea por voz.
  Future<void> _toggleAudioRecording() async {
    try {
      if (_isRecordingAudio) {
        // Detener y procesar
        setState(() => _isRecordingAudio = false);
        final audioPath = await audioRecordingService.stopRecording();
        if (audioPath != null) {
          await _procesarAudioGrabado(audioPath);
        } else {
          if (mounted) {
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('Error'),
                content: Text(
                  audioRecordingService.lastError ?? 'No se pudo grabar el audio.',
                ),
                severity: InfoBarSeverity.error,
                action: IconButton(
                  icon: const Icon(FluentIcons.clear),
                  onPressed: close,
                ),
              ),
            );
          }
        }
      } else {
        // Iniciar grabacion
        final ok = await audioRecordingService.startRecording();
        if (ok) {
          setState(() => _isRecordingAudio = true);
        } else {
          if (mounted) {
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('No se pudo iniciar'),
                content: Text(
                  audioRecordingService.lastError ?? 'Verifica el permiso de microfono.',
                ),
                severity: InfoBarSeverity.error,
                action: IconButton(
                  icon: const Icon(FluentIcons.clear),
                  onPressed: close,
                ),
              ),
            );
          }
          setState(() => _isRecordingAudio = false);
        }
      }
    } catch (e) {
      debugPrint('[Audio] Error en _toggleAudioRecording: $e');
      setState(() => _isRecordingAudio = false);
    }
  }

  /// Procesar audio grabado y enviar al backend
  /// Incluye manejo de lista de operarios y modo debug
  Future<void> _procesarAudioGrabado(String audioPath) async {
    try {
      setState(() => _isProcessingAudio = true);

      // Mostrar loading
      if (mounted) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
            title: const Text('Procesando'),
            content: const Text('Transcribiendo audio...'),
            severity: InfoBarSeverity.info,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          ),
        );
      }

      // PASO 1: Subir el archivo de audio al servidor (multipart) y transcribirlo.
      // Usar el endpoint de upload para que funcione desde Android/iOS sin
      // necesidad de compartir sistema de archivos con el servidor.
      Map<String, dynamic>? transcripcionResponse;
      try {
        final audioFile = File(audioPath);
        if (!await audioFile.exists()) {
          throw Exception('El archivo de audio no se encontró en: $audioPath');
        }
        final fileName = audioPath.split('/').last.split('\\').last;
        transcripcionResponse = (await ApiClient.postMultipart(
          '/api/tareas/voz/transcribir-audio-upload',
          fields: {'idioma': 'es', 'minutos_base': '30'},
          files: {'audio': await ApiClient.fileField('audio', audioPath, filename: fileName)},
        )) as Map<String, dynamic>?;
      } on ApiException catch (apiEx) {
        if (apiEx.statusCode == 503) {
          if (mounted) {
            await showDialog<void>(
              context: context,
              builder: (ctx) => ContentDialog(
                title: const Row(
                  children: [
                    Icon(FluentIcons.microphone, color: material.Colors.orange),
                    SizedBox(width: 8),
                    Text('Transcripción no disponible'),
                  ],
                ),
                content: const Text(
                  'El servidor no tiene faster-whisper instalado.\n\n'
                  'El audio no puede transcribirse automáticamente.\n'
                  'Puedes crear la tarea manualmente.',
                ),
                actions: [
                  Button(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cerrar'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _abrirAltaManual();
                    },
                    child: const Text('Crear tarea manual'),
                  ),
                ],
              ),
            );
          }
          return;
        }
        rethrow;
      }

      if (transcripcionResponse == null) {
        throw Exception('No hay respuesta del servidor');
      }

      // Extraer transcripción
      final transcripcion = transcripcionResponse['transcripcion'] ?? '';
      if (transcripcion.isEmpty) {
        throw Exception('Transcripción vacía del servidor');
      }

      debugPrint('[AudioProcessing] Transcripción obtenida: $transcripcion');

      // PASO 2: Procesar transcripción a JSON de tarea
      final response = await ApiClient.post(
        '/api/tareas/voz/procesar',
        body: {
          'transcripcion': transcripcion,
          'minutos_base': 30,
          'incluir_metadata': true,
        },
      );

      if (response == null) {
        if (mounted) {
          displayInfoBar(
            context,
            builder: (c, close) => InfoBar(
              title: const Text('Error'),
              content: const Text('No hay respuesta del servidor al procesar transcripción'),
              severity: InfoBarSeverity.error,
              action: IconButton(
                icon: const Icon(FluentIcons.clear),
                onPressed: close,
              ),
            ),
          );
        }
        return;
      }

      debugPrint('[AudioProcessing] Respuesta del servidor: ${response.toString()}');
      print('[DEBUG] Response body completo: ${response.toString()}');

      if (mounted && response != null) {
        final taskData = Map<String, dynamic>.from(response);

        // Obtener lista de operarios para selector obligatorio
        final operarios = _obtenerListaOperarios();

        // Mostrar dialog de confirmación con selector de usuario
        if (mounted) {
          await showVoiceTaskConfirmation(
            context,
            taskData: taskData,
            operarios: operarios,
            onConfirm: (confirmedData) async {
              // Confirmado: crear la tarea
              try {
                final response = await ApiClient.post(
                  '/api/tareas/crear_manual',
                  body: {
                    'titulo': confirmedData['titulo'],
                    'descripcion': confirmedData['descripcion'] ?? '',
                    'responsable': confirmedData['usuario_asignado'],
                    'categoria': 'VOZ_LOCAL',
                    'minutos_estimados':
                        confirmedData['minutos_estimados'] ?? 30,
                  },
                );

                if (mounted) {
                  displayInfoBar(
                    context,
                    builder: (c, close) => InfoBar(
                      title: const Text('Tarea Creada'),
                      content: const Text('La tarea fue creada exitosamente.'),
                      severity: InfoBarSeverity.success,
                      action: IconButton(
                        icon: const Icon(FluentIcons.clear),
                        onPressed: close,
                      ),
                    ),
                  );
                  await _cargar();
                }
              } catch (e) {
                if (mounted) {
                  displayInfoBar(
                    context,
                    builder: (c, close) => InfoBar(
                      title: const Text('Error'),
                      content: Text('Error al crear tarea: $e'),
                      severity: InfoBarSeverity.error,
                      action: IconButton(
                        icon: const Icon(FluentIcons.clear),
                        onPressed: close,
                      ),
                    ),
                  );
                }
              }
            },
            onEdit: (editedData) {
              // Abrir formulario manual con datos precargados
              _abrirAltaManual();
            },
            onLoadAudioFile: (filePath) async {
              debugPrint('[Audio] Procesando archivo de audio: $filePath');
              await _procesarAudioGrabado(filePath);
            },
          );
        }
      }
    } catch (e) {
      debugPrint('[Audio] Error procesando: $e');
      if (mounted) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
            title: const Text('Error'),
            content: Text('Error: $e'),
            severity: InfoBarSeverity.error,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          ),
        );
      }
    } finally {
      setState(() => _isProcessingAudio = false);
    }
  }

  /// Obtener lista de operarios actuales desde las tareas
  List<String> _obtenerListaOperarios() {
    // Extraer lista única de usuarios asignados del estado actual
    // Esta es una aproximación - idealmente vendría del backend
    final operarios = <String>{};
    // Por ahora, retornar lista vacía para que el dialog muestre solamente dropdown
    // En producción, cargaría desde backend
    return ['Juan', 'María', 'Carlos', 'Pedro', 'Ana'].toList();
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    return material.Scaffold(
      backgroundColor: palette.surfaceBase,
      floatingActionButton: _puedeControlarMisiones
          ? material.FloatingActionButton.small(
              heroTag: 'monitoreo_grabacion_voz',
              onPressed: _isProcessingAudio ? null : _toggleAudioRecording,
              backgroundColor: _isRecordingAudio
                  ? material.Colors.red.shade500
                  : FluentTheme.of(context).accentColor,
              tooltip: _isRecordingAudio ? 'Detener grabación' : 'Grabar tarea por voz',
              child: Icon(
                _isRecordingAudio
                    ? FluentIcons.stop
                    : FluentIcons.microphone,
                color: material.Colors.white,
                size: 18,
              ),
            )
          : null,
      floatingActionButtonLocation:
          material.FloatingActionButtonLocation.endFloat,
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(
              UiTokens.pageHPadding,
              10,
              UiTokens.pageHPadding,
              2,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(UiTokens.cardRadius),
              color: palette.surfaceCard,
              border: Border.all(
                color: palette.borderSubtle,
              ),
            ),
            child: material.TabBar(
              controller: _tabController,
              tabs: [
                material.Tab(
                  text: _esModoSoloLectura
                      ? 'Misiones activas (lectura)'
                      : 'Misiones activas',
                ),
                const material.Tab(text: 'Historial (100 % / Canceladas)'),
                const material.Tab(text: 'Alta manual'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: material.TabBarView(
              controller: _tabController,
              children: [
                _MonitoreoTabKeepAlive(child: _tabActivas()),
                _MonitoreoTabKeepAlive(child: _tabHistorial()),
                _MonitoreoTabKeepAlive(child: _tabAltaManual()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────── SWIMLANES HELPERS ─────────────────────────────────

  static const String _kSinAsignar = 'Misiones Sin Asignar';

  /// Agrupa las misiones activas en filas por usuario asignado.
  /// Prioridad de orden:
  /// 1) Mis tareas (usuario logueado), 2) Sin asignar, 3) resto alfabético.
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorUsuario() {
    final Map<String, List<Map<String, dynamic>>> byUser = {};
    for (final t in _activasOrdenadas) {
      final us = asignadoMision(t);
      final key = (us == 'Sin asignar' || us.isEmpty) ? _kSinAsignar : us;
      byUser.putIfAbsent(key, () => []).add(t);
    }
    final me = _currentUserName.trim().toLowerCase();
    final entries =
        byUser.entries.toList()..sort((a, b) {
          final aIsMe = me.isNotEmpty && a.key.trim().toLowerCase() == me;
          final bIsMe = me.isNotEmpty && b.key.trim().toLowerCase() == me;
          if (aIsMe && !bIsMe) return -1;
          if (!aIsMe && bIsMe) return 1;
          if (a.key == _kSinAsignar) return -1;
          if (b.key == _kSinAsignar) return 1;
          return a.key.toLowerCase().compareTo(b.key.toLowerCase());
        });
    return entries;
  }

  /// Color de avatar determinista a partir del nombre del usuario.
  static material.Color _avatarColor(String name) {
    const colors = [
      material.Color(0xFF42A5F5), // azul electrico
      material.Color(0xFF64B5F6), // azul cielo intenso
      material.Color(0xFF5C6BC0), // indigo
      material.Color(0xFF7E57C2), // violeta
      material.Color(0xFF9575CD), // lavanda fuerte
      material.Color(0xFFAB47BC), // magenta violeta
      material.Color(0xFF26C6DA), // cian intenso
      material.Color(0xFF00ACC1), // turquesa profundo
      material.Color(0xFFFF8A65), // coral suave
    ];
    if (name == _kSinAsignar) return const material.Color(0xFF5E35B1);
    var hash = 0;
    for (final c in name.codeUnits) {
      hash = (hash * 31 + c) & 0xFFFFFFFF;
    }
    return colors[hash % colors.length];
  }

  /// Iniciales para el avatar (máx 2 caracteres).
  static String _iniciales(String name) {
    if (name == _kSinAsignar) return '?';
    final parts = name.trim().split(RegExp(r'[\s_]+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  // ─────────────────────────────────────────────────────────────────────────

  List<String> _usuariosActivosOrdenados() {
    final users = _activasOrdenadas
        .map((t) => asignadoMision(t))
        .where((u) => u != 'Sin asignar' && u.trim().isNotEmpty)
        .toSet()
        .toList();
    users.sort((a, b) {
      final me = _currentUserName.trim().toLowerCase();
      final aMe = me.isNotEmpty && a.trim().toLowerCase() == me;
      final bMe = me.isNotEmpty && b.trim().toLowerCase() == me;
      if (aMe && !bMe) return -1;
      if (!aMe && bMe) return 1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return users;
  }

  List<Map<String, dynamic>> _activasFiltradas() {
    if (_filtroUsuario == _kFiltroTodos) return _activasOrdenadas;
    final me = _currentUserName.trim().toLowerCase();
    if (_filtroUsuario == _kFiltroMisTareas && me.isNotEmpty) {
      return _activasOrdenadas
          .where((t) {
            if (asignadoMision(t).trim().toLowerCase() == me) return true;
            for (final u in usuariosAsignadosLista(t)) {
              if (u.toLowerCase() == me) return true;
            }
            return false;
          })
          .toList();
    }
    return _activasOrdenadas
        .where((t) => asignadoMision(t) == _filtroUsuario)
        .toList();
  }

  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparActivasMostradas(
    List<Map<String, dynamic>> tasks,
  ) {
    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final t in tasks) {
      final raw = asignadoMision(t).trim();
      final key = raw.isEmpty ? 'Sin asignar' : raw;
      byUser.putIfAbsent(key, () => []).add(t);
    }
    final me = _currentUserName.trim().toLowerCase();
    final entries = byUser.entries.toList()
      ..sort((a, b) {
        final aMe = me.isNotEmpty && a.key.toLowerCase() == me;
        final bMe = me.isNotEmpty && b.key.toLowerCase() == me;
        if (aMe && !bMe) return -1;
        if (!aMe && bMe) return 1;
        if (a.key == 'Sin asignar') return -1;
        if (b.key == 'Sin asignar') return 1;
        return a.key.toLowerCase().compareTo(b.key.toLowerCase());
      });
    return entries;
  }

  Widget _tarjetaActivaLobby(
    int globalIndex,
    Map<String, dynamic> t,
    bool dark,
  ) {
    final id = t['id_tarea'];
    return DirectiveMissionCard(
      task: t,
      canControl: _puedeControlarMisiones,
      permitirChecklist: _puedeControlarMisiones,
      vistaMisionesActivas: true,
      checkEnProceso: _checkEnProceso,
      isDark: dark,
      vistaCompacta: _vistaCompacta,
      lobbyStyle: true,
      lobbyIndex: globalIndex,
      lobbyCount: _activasOrdenadas.length,
      onReorderByDelta: _puedeControlarMisiones ? _moveActivaEnGrid : null,
      onToggleCheck: _marcarChecklistItem,
      onAbrirDialogoPrioridad:
          _puedeControlarMisiones
              ? (int tid) => _dialogoAsignarPrioridad(tid)
              : null,
      onCancel:
          () =>
              _dialogoCancelarMision(id is int ? id : int.tryParse('$id') ?? 0),
      onPause: () => _dialogoPausar(id is int ? id : int.tryParse('$id') ?? 0),
      onResume:
          () => _reanudarMision(id is int ? id : int.tryParse('$id') ?? 0),
      onFinalizarManual:
          _puedeControlarMisiones
              ? () => _finalizarManualMision(
                id is int ? id : int.tryParse('$id') ?? 0,
              )
              : null,
      onEditManual:
          _puedeControlarMisiones && esManualSource(t)
              ? () => _dialogoEditarMisionManual(
                id is int ? id : int.tryParse('$id') ?? 0,
              )
              : null,
      onCargarBitacora: _cargarBitacora,
      onShowMeta: () {
        showMissionMetaSideSheet(
          context,
          t['meta'],
          task: Map<String, dynamic>.from(t),
        );
      },
    );
  }

  String _formatoMinutosCarga(int mins) {
    if (mins <= 0) return '0 min';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  int _minutosRestantesParaUsuario(String usuario) {
    var sum = 0;
    for (final t in _activasOrdenadas) {
      if (asignadoMision(t) != usuario) continue;
      final r = minutosRestantesEstimados(t);
      if (r != null && r > 0) sum += r;
    }
    return sum;
  }

  Widget _cargaDisponibilidadResumen() {
    final usuarios =
        _activasOrdenadas.map((t) => asignadoMision(t)).toSet().toList()
          ..sort();
    final chips = <Widget>[];
    for (final u in usuarios) {
      final m = _minutosRestantesParaUsuario(u);
      if (m <= 0) continue;
      final finTxt = estimadoFinLaboralDesdeAhoraEtiqueta(m);
      chips.add(
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: FluentTheme.of(
                context,
              ).accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: FluentTheme.of(
                  context,
                ).resources.controlStrokeColorDefault.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$u · ${_formatoMinutosCarga(m)} restantes (estim.)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                if (finTxt != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '$u finaliza sus actividades el $finTxt',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    if (chips.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: Text(
          'Carga acumulada: sin minutos presupuestados en misiones activas '
          '(o todas marcadas como «no aplica»).',
          style: TextStyle(
            fontSize: 12,
            color: FluentTheme.of(
              context,
            ).typography.body?.color?.withValues(alpha: 0.75),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Disponibilidad estimada (suma de tiempo restante por responsable)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: FluentTheme.of(
                context,
              ).typography.body?.color?.withValues(alpha: 0.95),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(children: chips),
        ],
      ),
    );
  }

  Widget _tabActivas() {
    if (_loading) return const Center(child: ProgressRing());
    if (_activasOrdenadas.isEmpty) {
      return Center(
        child: Text(
          'No hay misiones activas.',
          style: TextStyle(
            color: FluentTheme.of(
              context,
            ).typography.body?.color?.withValues(alpha: 0.8),
          ),
        ),
      );
    }
    final dark = _isDark(context);
    final usuariosActivos = _usuariosActivosOrdenados();
    final activasMostradas = _activasFiltradas();

    // Construir índice global → posición en _activasOrdenadas para reorder
    final Map<int, int> idToGlobalIndex = {
      for (var i = 0; i < _activasOrdenadas.length; i++)
        (_activasOrdenadas[i]['id_tarea'] is int
                ? _activasOrdenadas[i]['id_tarea'] as int
                : int.tryParse('${_activasOrdenadas[i]['id_tarea']}') ?? -1):
            i,
    };

    return Column(
      children: [
        // HEADER con botón minimizar
        Container(
          color: FluentTheme.of(context).cardColor,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Misiones Activas (${activasMostradas.length}/${_activasOrdenadas.length})',
                style: FluentTheme.of(context).typography.subtitle,
              ),
              material.Tooltip(
                message: _vistaCompacta ? 'Expandir tarjetas' : 'Minimizar tarjetas',
                child: material.IconButton(
                  icon: Icon(
                    _vistaCompacta ? material.Icons.unfold_more : material.Icons.unfold_less,
                    color: FluentTheme.of(context).accentColor,
                  ),
                  onPressed: () => setState(() => _vistaCompacta = !_vistaCompacta),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
          alignment: Alignment.centerLeft,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _usuarioFilterChip(
                  label: 'Todos',
                  selected: _filtroUsuario == _kFiltroTodos,
                  onTap: () => setState(() => _filtroUsuario = _kFiltroTodos),
                ),
                const SizedBox(width: 6),
                _usuarioFilterChip(
                  label: 'Mis tareas',
                  selected: _filtroUsuario == _kFiltroMisTareas,
                  onTap:
                      () => setState(() => _filtroUsuario = _kFiltroMisTareas),
                ),
                for (final u in usuariosActivos) ...[
                  const SizedBox(width: 6),
                  _usuarioFilterChip(
                    label: u,
                    selected: _filtroUsuario == u,
                    avatarColor: _avatarColor(u),
                    initials: _iniciales(u),
                    onTap: () => setState(() => _filtroUsuario = u),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: material.Scrollbar(
            controller: _activasScrollController,
            thumbVisibility: true,
            child: material.ListView(
              controller: _activasScrollController,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                _cargaDisponibilidadResumen(),
                if (activasMostradas.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: Text(
                        'No hay misiones para este filtro.',
                        style: TextStyle(
                          color: FluentTheme.of(context)
                              .typography
                              .body
                              ?.color
                              ?.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, c) {
                      final maxW = c.maxWidth;
                      final target = _vistaCompacta ? 320.0 : 360.0;
                      final columns =
                          (maxW / target).floor().clamp(1, _vistaCompacta ? 4 : 3);
                      final gap = 10.0;
                      final cardW =
                          ((maxW - ((columns - 1) * gap)) / columns).clamp(
                        290.0,
                        _vistaCompacta ? 340.0 : 390.0,
                      );
                      final grouped = _filtroUsuario == _kFiltroTodos;
                      if (!grouped) {
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final t in activasMostradas)
                              SizedBox(
                                width: cardW,
                                child: RepaintBoundary(
                                  key: ValueKey('flt_mission_${t['id_tarea']}'),
                                  child: _tarjetaActivaLobby(
                                    idToGlobalIndex[t['id_tarea'] is int
                                            ? t['id_tarea'] as int
                                            : int.tryParse('${t['id_tarea']}') ?? -1] ??
                                        0,
                                    t,
                                    dark,
                                  ),
                                ),
                              ),
                          ],
                        );
                      }
                      final groups = _agruparActivasMostradas(activasMostradas);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final e in groups) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(2, 2, 2, 6),
                              child: Text(
                                e.key,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.82),
                                ),
                              ),
                            ),
                            Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                for (final t in e.value)
                                  SizedBox(
                                    width: cardW,
                                    child: RepaintBoundary(
                                      key: ValueKey('flt_mission_${t['id_tarea']}'),
                                      child: _tarjetaActivaLobby(
                                        idToGlobalIndex[t['id_tarea'] is int
                                                ? t['id_tarea'] as int
                                                : int.tryParse('${t['id_tarea']}') ?? -1] ??
                                            0,
                                        t,
                                        dark,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                          ],
                        ],
                      );
                    },
                  ),
            ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _usuarioFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    material.Color? avatarColor,
    String? initials,
  }) {
    final theme = FluentTheme.of(context);
    final dark = _isDark(context);
    final baseBorder = theme.resources.controlStrokeColorDefault.withValues(
      alpha: 0.45,
    );
    final selColor = theme.accentColor;
    material.Color? vivid;
    if (avatarColor != null) {
      vivid = monitoreoUserVividAccent(avatarColor, isDark: dark);
    }
    final chipBorder =
        selected
            ? selColor.withValues(alpha: 0.72)
            : (vivid ?? baseBorder);
    final chipBorderW = (!selected && vivid != null) ? 1.25 : 1.0;
    final iniColor =
        vivid != null
            ? (vivid.computeLuminance() > 0.52
                ? const material.Color(0xFF0F172A)
                : material.Colors.white)
            : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color:
              selected
                  ? selColor.withValues(alpha: 0.18)
                  : (vivid != null
                      ? vivid.withValues(alpha: dark ? 0.12 : 0.08)
                      : theme.cardColor),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: chipBorder, width: chipBorderW),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (avatarColor != null && initials != null && vivid != null) ...[
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: vivid.withValues(alpha: dark ? 0.22 : 0.18),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: vivid, width: 1.25),
                ),
                alignment: Alignment.center,
                child: Text(
                  initials,
                  style: TextStyle(
                    fontSize: initials.length > 2 ? 7.5 : 9,
                    fontWeight: FontWeight.w900,
                    color: iniColor,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: vivid != null && !selected ? vivid : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabHistorial() {
    if (_loading) return const Center(child: ProgressRing());
    final hist = _tareas.where(esMisionCentroHistorial).toList();
    final body =
        hist.isEmpty
            ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Sin misiones en historial (terminadas al 100 % o canceladas).',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: FluentTheme.of(
                      context,
                    ).typography.body?.color?.withValues(alpha: 0.8),
                  ),
                ),
              ),
            )
            : BitacoraCalendarioPanel(
              key: const ValueKey<String>('bitacora_hist_centro'),
              tareasHistorial: hist,
              tareasActivasParaProyeccion: _activasOrdenadas,
              onReactivarTarea:
                  _puedeControlarMisiones ? _reactivarTareaHistorial : null,
              onEliminarTarea:
                  _puedeControlarMisiones ? _eliminarTareaHistorial : null,
              onTapTarea: (t) {
                showMissionMetaSideSheet(
                  context,
                  t['meta'],
                  task: Map<String, dynamic>.from(t),
                );
              },
            );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: body,
    );
  }

  Widget _tabAltaManual() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
          // Header con icono
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                FluentIcons.add_field,
                size: 34,
                color: FluentTheme.of(context).accentColor,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Crear Misión en Servidor',
                    style: FluentTheme.of(context)
                        .typography
                        .title
                        ?.copyWith(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Alta manual de tareas con responsable y categoría',
                    style: TextStyle(
                      fontSize: 14,
                      color: FluentTheme.of(context)
                          .typography
                          .body
                          ?.color
                          ?.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Card de información
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FluentTheme.of(context).cardColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: FluentTheme.of(context)
                    .inactiveColor
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _esModoSoloLectura
                      ? 'Modo Lectura - No puede crear misiones'
                      : 'Modo Edición - Puede crear misiones',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: _esModoSoloLectura
                        ? material.Colors.orange.shade700
                        : material.Colors.green.shade700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _esModoSoloLectura
                      ? 'Su rol actual no tiene permiso para crear misiones. Solo los administradores con permisos de control pueden crear tareas manuales.'
                      : 'Registra una tarea manual con responsable, categoría y descripción. Se guardará en SQL con SourceType Manual y se asignará automáticamente.',
                  style: TextStyle(
                    fontSize: 13,
                    color: FluentTheme.of(context)
                        .typography
                        .body
                        ?.color
                        ?.withValues(alpha: 0.8),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Botón
          FilledButton(
            onPressed: _esModoSoloLectura ? null : _abrirAltaManual,
            style: ButtonStyle(
              padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _esModoSoloLectura
                      ? FluentIcons.lock
                      : FluentIcons.add,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Text(
                  _esModoSoloLectura
                      ? 'Crear misión (Deshabilitado)'
                      : 'Crear nueva misión',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          if (_esModoSoloLectura) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: material.Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: material.Colors.blue.shade300,
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        FluentIcons.info,
                        size: 20,
                        color: material.Colors.blue.shade700,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Cómo habilitar creación de misiones',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: material.Colors.blue.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '1. Chequee arriba en "Simulando:" cuál es su rol\n'
                    '2. Si es administrador, solo algunos roles tienen permisos\n'
                    '3. Contacte al administrador del sistema para actualizar permisos',
                    style: TextStyle(
                      fontSize: 12,
                      color: material.Colors.blue.shade700,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Evita destruir el estado de cada pestana al cambiar de tab (historial/calendario).
class _MonitoreoTabKeepAlive extends StatefulWidget {
  const _MonitoreoTabKeepAlive({required this.child});

  final Widget child;

  @override
  State<_MonitoreoTabKeepAlive> createState() => _MonitoreoTabKeepAliveState();
}

class _MonitoreoTabKeepAliveState extends State<_MonitoreoTabKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Swimlane fila por usuario
// ─────────────────────────────────────────────────────────────────────────────

class _SwimlaneRow extends StatelessWidget {
  const _SwimlaneRow({
    super.key,
    required this.usuario,
    required this.tareas,
    required this.colapsada,
    required this.onToggleColapso,
    required this.avatarColor,
    required this.iniciales,
    required this.dark,
    required this.idToGlobalIndex,
    required this.cardBuilder,
  });

  final String usuario;
  final List<Map<String, dynamic>> tareas;
  final bool colapsada;
  final VoidCallback onToggleColapso;
  final material.Color avatarColor;
  final String iniciales;
  final bool dark;
  final Map<int, int> idToGlobalIndex;
  final Widget Function(Map<String, dynamic> tarea) cardBuilder;

  @override
  Widget build(BuildContext context) {
    final borderColor = avatarColor.withValues(alpha: 0.45);
    final countBadgeBg = avatarColor.withValues(alpha: 0.18);
    final titleColor = dark ? material.Colors.white : material.Colors.black87;

    final header = material.InkWell(
      onTap: onToggleColapso,
      borderRadius: material.BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: material.Row(
          children: [
            // Cabecera tipo "nota" (sin barra horizontal completa)
            material.Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: material.BoxDecoration(
                color:
                    dark
                        ? const material.Color(0xFF1E1E2E)
                        : const material.Color(0xFFF3F4F6),
                borderRadius: material.BorderRadius.circular(12),
                border: material.Border.all(color: borderColor, width: 1.2),
              ),
              child: material.Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  material.Container(
                    width: 30,
                    height: 30,
                    decoration: material.BoxDecoration(
                      color: avatarColor.withValues(alpha: 0.92),
                      borderRadius: material.BorderRadius.circular(8),
                      border: material.Border.all(
                        color: material.Colors.white.withValues(alpha: 0.35),
                        width: 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: material.Text(
                      iniciales,
                      style: const material.TextStyle(
                        color: material.Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: material.Text(
                      usuario,
                      style: material.TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                        letterSpacing: 0.15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  material.Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: material.BoxDecoration(
                      color: countBadgeBg,
                      borderRadius: material.BorderRadius.circular(20),
                      border: material.Border.all(color: borderColor),
                    ),
                    child: material.Text(
                      '${tareas.length}',
                      style: material.TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: avatarColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            material.AnimatedRotation(
              turns: colapsada ? -0.25 : 0,
              duration: const Duration(milliseconds: 220),
              child: Icon(
                FluentIcons.chevron_down,
                size: 16,
                color: dark ? material.Colors.white70 : material.Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: material.AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (!colapsada) ...[
              const SizedBox(height: 12),
              // Wrap responsive para acomodar las tarjetas
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final t in tareas)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: material.SizedBox(
                        width: double.infinity,
                        child: RepaintBoundary(
                          key: ValueKey('sl_mission_${t['id_tarea']}'),
                          child: cardBuilder(t),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
