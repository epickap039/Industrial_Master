import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/audio_recording_service.dart';
import '../services/notification_inbox_service.dart';
import '../widgets/bitacora_calendario_panel.dart';
import '../widgets/voice_task_confirmation_dialog.dart';
import 'monitoreo/widgets/directive_mission_card.dart';
import 'monitoreo/widgets/manual_mission_form_dialog.dart';
import 'monitoreo/widgets/mission_meta_sheet.dart';
import 'monitoreo/widgets/task_display_utils.dart';
import '../services/app_role.dart';

const List<String> _kMotivosPausa = ['Falta material', 'Avería', 'Aprobación'];

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
  bool _loading = true;
  bool _vistaCompacta = false;
  List<Map<String, dynamic>> _tareas = [];
  List<Map<String, dynamic>> _activasOrdenadas = [];

  /// Tracks which swimlane rows are collapsed. Key = usuario label.
  final Set<String> _swimlanesColapsadas = {};
  String _currentUserName = '';
  final Set<int> _checkEnProceso = {};
  final Set<int> _seenTaskIds = {};
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

    // Auto-refresco cada 30 s para recibir notificaciones
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
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

  bool _esMisionCentro(Map<String, dynamic> t) {
    var src =
        '${t['source_type'] ?? t['SourceType'] ?? ''}'.trim().toUpperCase();
    if (src.isEmpty) {
      src = 'MANUAL';
    }
    if (src == 'MANUAL' || src == 'RADAR') return true;
    final raw = t['tipo']?.toString().trim() ?? '';
    if (raw.isEmpty || raw == 'null') return false;
    final u = raw.toUpperCase();
    if (u == 'RADAR' || u == 'MANUAL') return true;
    return u.contains('RADAR') || u.contains('MANUAL');
  }

  bool _esActivaTab(Map<String, dynamic> t) {
    if (!_esMisionCentro(t)) return false;
    if (esCancelada(t)) return false;
    final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
    if (p >= 100) return false;
    final st = normEst(t);
    if (st.contains('terminad')) return false;
    return true;
  }

  bool _esHistorialTab(Map<String, dynamic> t) {
    if (!_esMisionCentro(t)) return false;
    if (esCancelada(t)) return true;
    final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
    if (p >= 100) return true;
    final st = normEst(t);
    if (st.contains('terminad')) return true;
    return false;
  }

  Future<List<Map<String, dynamic>>> _cargarBitacora(int idTarea) async {
    try {
      final raw = await ApiClient.get('/api/tareas/bitacora/$idTarea');
      if (raw is List) {
        return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
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
      final list = data.whereType<Map<String, dynamic>>().toList();

      // Notificaciones: buzón persistente + InfoBar si es nueva misión para el usuario
      if (_seenTaskIds.isNotEmpty) {
        for (final t in list) {
          final idRaw = t['id_tarea'];
          final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
          if (id != null && !_seenTaskIds.contains(id)) {
            final asignado =
                '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? ''}'
                    .trim();
            final soyYo =
                asignado.isNotEmpty &&
                _currentUserName.isNotEmpty &&
                asignado.toLowerCase() == _currentUserName.toLowerCase();

            if (soyYo && mounted) {
              try {
                final titulo = '${t['titulo'] ?? ''}';
                final agregada = await CmdInboxStore.instance
                    .addMissionAssigned(idTarea: id, titulo: titulo);
                if (agregada) {
                  if (mounted) {
                    displayInfoBar(
                      context,
                      builder:
                          (c, close) => InfoBar(
                            title: const Text('Nueva Misión Asignada'),
                            content: Text(
                              'ID: #$id - $titulo · Guardado en el buzón',
                            ),
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
        }
      }

      // Actualizar IDs vistos
      for (final t in list) {
        final idRaw = t['id_tarea'];
        final id = idRaw is int ? idRaw : int.tryParse('$idRaw');
        if (id != null) _seenTaskIds.add(id);
      }

      final activas =
          list
              .where(_esActivaTab)
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
    setState(() => _checkEnProceso.add(idCheck));
    try {
      await ApiClient.put(
        '/api/tareas/check/$idCheck',
        body: {'completado': nuevoValor ?? false},
      );
      if (!mounted) return;
      setState(() {
        final ti = _tareas.indexWhere((x) {
          final id = x['id_tarea'];
          final a = id is int ? id : int.tryParse('$id');
          return a == idTarea;
        });
        if (ti < 0) return;
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
          final hecho = nuevoValor ?? false;
          list[ci] = Map<String, dynamic>.from(list[ci])
            ..['completado'] = hecho ? 1 : 0;
          task['checklist'] = list;
          final pct = calcularProgresoDesdeChecklist(list);
          task['porcentaje_progreso'] = pct;
          _aplicarEstadoLocalPorProgreso(task, pct);
          _tareas[ti] = task;
        }
        _activasOrdenadas =
            _tareas
                .where(_esActivaTab)
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
      });
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
    String motivo = _kMotivosPausa.first;
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

  Future<void> _dialogoLimpiarHistorial() async {
    if (!_puedeControlarMisiones) return;
    final ctrl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return ContentDialog(
            title: const Text('Limpiar Historial'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Se borrarán DEFINTIVAMENTE todas las misiones terminadas al 100% o canceladas de la base de datos.',
                ),
                const SizedBox(height: 12),
                TextBox(
                  controller: ctrl,
                  obscureText: true,
                  placeholder: 'Contraseña de confirmación',
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(ctx, false),
              ),
              FilledButton(
                child: const Text('Borrar Historial'),
                onPressed: () {
                  if (ctrl.text == 'ADMIN_ING_2024') {
                    Navigator.pop(ctx, true);
                  } else {
                    displayInfoBar(
                      ctx,
                      builder:
                          (c, close) => InfoBar(
                            title: const Text('Acceso Denegado'),
                            content: const Text('Contraseña incorrecta.'),
                            severity: InfoBarSeverity.error,
                            onClose: close,
                          ),
                    );
                  }
                },
              ),
            ],
          );
        },
      );

      if (ok == true && mounted) {
        try {
          await ApiClient.delete('/api/tareas/limpiar_historial');
          if (mounted) {
            displayInfoBar(
              context,
              builder:
                  (c, close) => InfoBar(
                    title: const Text('Historial Limpiado'),
                    content: const Text(
                      'Las tareas antiguas fueron borradas con éxito.',
                    ),
                    severity: InfoBarSeverity.success,
                    onClose: close,
                  ),
            );
            await _cargar();
          }
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
    } finally {
      ctrl.dispose();
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
      if (mounted) setState(() => _vozWhisperDisponible = false);
    }
  }

  /// Iniciar/detener grabación de audio para crear tarea por voz
  /// ✅ Incluye manejo de permisos dinámicos
  /// ✅ DEBUG: Muestra ContentDialog con información de error si falla
  Future<void> _toggleAudioRecording() async {
    // Si sabemos que Whisper no está disponible, redirigir al formulario manual.
    if (_vozWhisperDisponible == false) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => ContentDialog(
            title: const Row(
              children: [
                Icon(FluentIcons.microphone, color: material.Colors.orange),
                SizedBox(width: 8),
                Text('Voz no disponible'),
              ],
            ),
            content: const Text(
              'El servidor no tiene el motor de transcripción de audio instalado '
              '(faster-whisper).\n\n'
              'Puedes crear la tarea manualmente con el formulario, '
              'o pedir al administrador que ejecute:\n\n'
              'pip install faster-whisper',
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

    try {
      if (_isRecordingAudio) {
        // Detener grabación
        setState(() => _isRecordingAudio = false);

        final audioPath = await audioRecordingService.stopRecording();
        if (audioPath != null) {
          // Procesar el audio
          await _procesarAudioGrabado(audioPath);
        } else {
          if (mounted) {
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('Error'),
                content: const Text('No se pudo grabar el audio.'),
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
        // Iniciar grabación
        // Primero, verificar permisos
        final micPermission =
            await audioRecordingService.requestMicrophonePermission();

        if (!micPermission) {
          if (mounted) {
            final errorMsg = audioRecordingService.lastError ??
                'No se pudieron otorgar permisos de micrófono.';
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('Permiso Denegado'),
                content: Text(errorMsg),
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

        // Intentar iniciar grabación
        final ok = await audioRecordingService.startRecording();
        if (ok) {
          setState(() => _isRecordingAudio = true);
        } else {
          // 🛠️ DEBUGGING PROFUNDO: Mostrar dialog con información detallada
          if (mounted) {
            final debugInfo = audioRecordingService.debugInfo;

            // Si hay información de debugging, mostrar dialog detallado
            if (debugInfo != null) {
              await showDialog<void>(
                context: context,
                builder: (ctx) => ContentDialog(
                  title: Row(
                    children: [
                      const Icon(FluentIcons.report_alert,
                          color: material.Colors.red),
                      const SizedBox(width: 8),
                      const Text('🛠️ DEBUG ERROR GRABACIÓN'),
                    ],
                  ),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 📂 Ruta intentada
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: material.Colors.grey.shade100,
                            border: Border.all(
                              color: material.Colors.grey.shade300,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                            'Ruta:\n${debugInfo.attemptedPath}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: material.Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // ⚠️ Mensaje exacto del error
                        Text(
                          'Mensaje de Error:',
                          style: FluentTheme.of(context).typography.subtitle,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: material.Colors.red.shade50,
                            border: Border.all(
                              color: material.Colors.red.shade300,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                            debugInfo.errorMessage,
                            style: const TextStyle(
                              fontSize: 12,
                              color: material.Colors.red,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // 🕐 Stack trace (primeras 5 líneas)
                        Text(
                          'StackTrace (primeras 5 líneas):',
                          style: FluentTheme.of(context).typography.subtitle,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: material.Colors.orange.shade50,
                            border: Border.all(
                              color: material.Colors.orange.shade300,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                            debugInfo.stackTraceLines.join('\n'),
                            style: const TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: material.Colors.orange,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // 📝 Recomendaciones
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: material.Colors.blue.shade50,
                            border: Border.all(
                              color: material.Colors.blue.shade300,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '💡 Recomendaciones:',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: material.Colors.blue.shade700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const SelectableText(
                                '1. Verificar permisos en configuración del dispositivo\n'
                                '2. Asegurate que la carpeta /data/local/tmp existe\n'
                                '3. Revisar logcat: adb logcat | grep AudioRecording\n'
                                '4. Probar modo debug: cargar archivo de audio',
                                style: TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    Button(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cerrar'),
                    ),
                  ],
                ),
              );
            } else {
              // Si no hay info de debugging, mostrar error simple
              displayInfoBar(
                context,
                builder: (c, close) => InfoBar(
                  title: const Text('Error al Grabar'),
                  content: Text(audioRecordingService.lastError ??
                      'Error desconocido'),
                  severity: InfoBarSeverity.error,
                  action: IconButton(
                    icon: const Icon(FluentIcons.clear),
                    onPressed: close,
                  ),
                ),
              );
            }
          }
          setState(() => _isRecordingAudio = false);
        }
      }
    } catch (e) {
      debugPrint('[Audio] Error crítico en _toggleAudioRecording: $e');
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
          if (mounted) setState(() => _vozWhisperDisponible = false);
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
              // Modo debug: cargar archivo de audio manualmente
              debugPrint('[Audio] Cargando archivo de audio en modo debug: $filePath');
              final loadedPath =
                  await audioRecordingService.loadAudioFileDebug(filePath);
              if (loadedPath != null && mounted) {
                displayInfoBar(
                  context,
                  builder: (c, close) => InfoBar(
                    title: const Text('Audio Cargado'),
                    content: const Text('Archivo cargado exitosamente.'),
                    severity: InfoBarSeverity.success,
                    action: IconButton(
                      icon: const Icon(FluentIcons.clear),
                      onPressed: close,
                    ),
                  ),
                );
                // Reprocesar con el nuevo archivo
                await _procesarAudioGrabado(loadedPath);
              }
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
    return material.Scaffold(
      floatingActionButton: _puedeControlarMisiones
          ? material.FloatingActionButton(
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
                size: 24,
              ),
            )
          : null,
      floatingActionButtonLocation:
          material.FloatingActionButtonLocation.startFloat,
      body: Column(
        children: [
          material.TabBar(
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
          const SizedBox(height: 12),
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
  /// El lane de "Sin Asignar" sale siempre primero.
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorUsuario() {
    final Map<String, List<Map<String, dynamic>>> byUser = {};
    for (final t in _activasOrdenadas) {
      final us = asignadoMision(t);
      final key = (us == 'Sin asignar' || us.isEmpty) ? _kSinAsignar : us;
      byUser.putIfAbsent(key, () => []).add(t);
    }
    final entries =
        byUser.entries.toList()..sort((a, b) {
          if (a.key == _kSinAsignar) return -1;
          if (b.key == _kSinAsignar) return 1;
          return a.key.toLowerCase().compareTo(b.key.toLowerCase());
        });
    return entries;
  }

  /// Color de avatar determinista a partir del nombre del usuario.
  static material.Color _avatarColor(String name) {
    const colors = [
      material.Color(0xFF1565C0), // azul oscuro
      material.Color(0xFF00695C), // teal
      material.Color(0xFF6A1B9A), // lilac
      material.Color(0xFFAD1457), // rosa
      material.Color(0xFFE65100), // naranja
      material.Color(0xFF2E7D32), // verde
      material.Color(0xFF4527A0), // indigo
      material.Color(0xFF00838F), // cyan
    ];
    if (name == _kSinAsignar) return const material.Color(0xFF546E7A);
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
      chips.add(
        Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
            child: Text(
              '$u · ${_formatoMinutosCarga(m)} restantes (estim.)',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
    final lanes = _agruparPorUsuario();

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
                'Misiones Activas (${_activasOrdenadas.length})',
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
        Expanded(
          child: material.Scrollbar(
            controller: _activasScrollController,
            thumbVisibility: true,
            child: material.ListView(
              controller: _activasScrollController,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
          _cargaDisponibilidadResumen(),
          for (final lane in lanes)
            _SwimlaneRow(
              key: ValueKey('lane_${lane.key}'),
              usuario: lane.key,
              tareas: lane.value,
              colapsada: _swimlanesColapsadas.contains(lane.key),
              onToggleColapso:
                  () => setState(() {
                    if (_swimlanesColapsadas.contains(lane.key)) {
                      _swimlanesColapsadas.remove(lane.key);
                    } else {
                      _swimlanesColapsadas.add(lane.key);
                    }
                  }),
              avatarColor: _avatarColor(lane.key),
              iniciales: _iniciales(lane.key),
              dark: dark,
              idToGlobalIndex: idToGlobalIndex,
              cardBuilder: (t) {
                final gIdx =
                    idToGlobalIndex[t['id_tarea'] is int
                        ? t['id_tarea'] as int
                        : int.tryParse('${t['id_tarea']}') ?? -1] ??
                    0;
                return _tarjetaActivaLobby(gIdx, t, dark);
              },
            ),
            ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabHistorial() {
    if (_loading) return const Center(child: ProgressRing());
    final hist = _tareas.where(_esHistorialTab).toList();
    if (hist.isEmpty) {
      return Center(
        child: Text(
          'Sin misiones en historial (terminadas al 100 % o canceladas).',
          style: TextStyle(
            color: FluentTheme.of(
              context,
            ).typography.body?.color?.withValues(alpha: 0.8),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: BitacoraCalendarioPanel(
        key: const ValueKey<String>('bitacora_hist_centro'),
        tareasHistorial: hist,
        onTapTarea: (t) {
          showMissionMetaSideSheet(
            context,
            t['meta'],
            task: Map<String, dynamic>.from(t),
          );
        },
      ),
    );
  }

  Widget _tabAltaManual() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con icono
          Row(
            children: [
              Icon(
                FluentIcons.add_field,
                size: 28,
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
                        ?.copyWith(fontSize: 18),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Alta manual de tareas con responsable y categoría',
                    style: TextStyle(
                      fontSize: 12,
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
                  style: const TextStyle(fontSize: 14),
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
    final headerBg =
        dark
            ? const material.Color(0xFF1E1E2E)
            : const material.Color(0xFFECEFF1);
    final borderColor = avatarColor.withValues(alpha: 0.45);
    final countBadgeBg = avatarColor.withValues(alpha: 0.18);

    final header = material.InkWell(
      onTap: onToggleColapso,
      borderRadius: material.BorderRadius.circular(14),
      child: material.Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: material.BoxDecoration(
          color: headerBg,
          borderRadius: material.BorderRadius.circular(14),
          border: material.Border.all(color: borderColor, width: 1.5),
        ),
        child: material.Row(
          children: [
            material.Container(
              width: 34,
              height: 34,
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
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 14),
            // Nombre del usuario
            Expanded(
              child: material.Text(
                usuario,
                style: material.TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: dark ? material.Colors.white : material.Colors.black87,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            // Badge con cantidad de misiones
            material.Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: material.BoxDecoration(
                color: countBadgeBg,
                borderRadius: material.BorderRadius.circular(20),
                border: material.Border.all(color: borderColor),
              ),
              child: material.Text(
                '${tareas.length} misión${tareas.length == 1 ? '' : 'es'}',
                style: material.TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: avatarColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Chevron animado
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
