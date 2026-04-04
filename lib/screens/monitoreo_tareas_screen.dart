import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../services/notification_inbox_service.dart';
import '../widgets/compact_page_header.dart';
import 'monitoreo/widgets/directive_mission_card.dart';
import 'monitoreo/widgets/notification_inbox_panel.dart';
import 'monitoreo/widgets/manual_mission_form_dialog.dart';
import 'monitoreo/widgets/mission_meta_sheet.dart';
import 'monitoreo/widgets/task_display_utils.dart';

const List<String> _kMotivosPausa = [
  'Falta material',
  'Avería',
  'Aprobación',
];

/// Centro de Comando Directivo Industrial (Radar + Manual, sin IA predictiva).
class MonitoreoTareasScreen extends StatefulWidget {
  const MonitoreoTareasScreen({super.key});

  @override
  State<MonitoreoTareasScreen> createState() => _MonitoreoTareasScreenState();
}

class _MonitoreoTareasScreenState extends State<MonitoreoTareasScreen> {
  bool _loading = true;
  bool _vistaCompacta = false;
  List<Map<String, dynamic>> _tareas = [];
  List<Map<String, dynamic>> _activasOrdenadas = [];
  /// Tracks which swimlane rows are collapsed. Key = usuario label.
  final Set<String> _swimlanesColapsadas = {};
  String _userRole = 'USER';
  String _currentUserName = '';
  final Set<int> _checkEnProceso = {};
  final Set<int> _seenTaskIds = {};
  int _inboxUnread = 0;
  Timer? _refreshTimer;
  final material.ScrollController _activasScrollController = material.ScrollController();
  final material.ScrollController _historialScrollController = material.ScrollController();

  @override
  void initState() {
    super.initState();
    _initSesion();
    _cargar();
    unawaited(_refreshInboxBadge());

    // Auto-refresco cada 30 segundos para recibir notificaciones
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) _cargar(silent: true);
    });
  }

  Future<void> _refreshInboxBadge() async {
    try {
      final n = await CmdInboxStore.instance.unreadCount();
      if (mounted) setState(() => _inboxUnread = n);
    } catch (_) {
      if (mounted) setState(() => _inboxUnread = 0);
    }
  }

  Future<void> _abrirBuzonNotificaciones() async {
    await showNotificationInboxDialog(
      context,
      onChanged: () {
        unawaited(_refreshInboxBadge());
      },
    );
    if (mounted) await _refreshInboxBadge();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _activasScrollController.dispose();
    _historialScrollController.dispose();
    super.dispose();
  }

  Future<void> _initSesion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _userRole = prefs.getString('rol') ?? 'USER';
          _currentUserName = (prefs.getString('username') ?? '').trim();
        });
      }
    } catch (_) {}
  }

  bool get _puedeControlarMisiones {
    final r = _userRole.trim().toUpperCase();
    return r == 'ADMIN' || r == 'INGENIERIA' || r == 'INGENIERÍA';
  }

  bool get _esModoSoloLectura => !_puedeControlarMisiones;

  bool _esMisionCentro(Map<String, dynamic> t) {
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
            builder: (context, close) => InfoBar(
              title: const Text('Error'),
              content: const Text('Respuesta invalida del servidor (lista de tareas).'),
              severity: InfoBarSeverity.error,
              action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
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
            final asignado = '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? ''}'.trim();
            final soyYo = asignado.isNotEmpty && _currentUserName.isNotEmpty &&
                asignado.toLowerCase() == _currentUserName.toLowerCase();

            if (soyYo && mounted) {
              try {
                final titulo = '${t['titulo'] ?? ''}';
                final agregada =
                    await CmdInboxStore.instance.addMissionAssigned(
                  idTarea: id,
                  titulo: titulo,
                );
                if (agregada) {
                  await _refreshInboxBadge();
                  if (mounted) {
                    displayInfoBar(
                      context,
                      builder: (c, close) => InfoBar(
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

      final activas = list.where(_esActivaTab).map((e) => Map<String, dynamic>.from(e)).toList();
      setState(() {
        _tareas = list;
        _activasOrdenadas = activas;
        if (!silent) _loading = false;
      });
    } catch (e) {
      if (mounted && !silent) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('Error'),
            content: Text('No se pudieron cargar las tareas: $e'),
            severity: InfoBarSeverity.error,
            action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
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
            list.add(Map<String, dynamic>.from(
              e.map((k, v) => MapEntry(k.toString(), v)),
            ));
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
        _activasOrdenadas = _tareas.where(_esActivaTab).map((e) => Map<String, dynamic>.from(e)).toList();
      });
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

  Future<void> _aplicarPrioridadMision(int idTarea, int nivel, bool suspender) async {
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
    final ok = await _persistirReorden(
      suspenderOtrasMismoResponsable: doSuspend,
      idTareaPrioridadUrgente: doSuspend ? idTarea : null,
    );
    if (!mounted) return;
    if (ok) {
      await _cargar();
      if (!mounted) return;
      if (doSuspend) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
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
                    onPressed: ctrl.text.trim().length < 3
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
        builder: (c, close) => InfoBar(
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
          builder: (c, close) => InfoBar(
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
                    items: _kMotivosPausa
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
        body: {
          'estado': 'Pausado',
          'motivo_pausa': motivo,
        },
      );
      if (!mounted) return;
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

  Future<void> _finalizarManualMision(int idTarea) async {
    try {
      await ApiClient.put('/api/tareas/finalizar_manual/$idTarea');
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
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

  Future<bool> _persistirReorden({
    bool suspenderOtrasMismoResponsable = false,
    int? idTareaPrioridadUrgente,
  }) async {
    final body = <String, dynamic>{
      'items': List<Map<String, dynamic>>.generate(
        _activasOrdenadas.length,
        (i) => {
          'id_tarea': _activasOrdenadas[i]['id_tarea'],
          'priority_rank': i,
        },
      ),
      if (suspenderOtrasMismoResponsable && idTareaPrioridadUrgente != null) ...{
        'suspender_otras_mismo_responsable': true,
        'id_tarea_prioridad_urgente': idTareaPrioridadUrgente,
      },
    };
    try {
      debugPrint('JSON ENVIADO A /reordenar (Prioridades): ${jsonEncode(body)}');
      await ApiClient.put('/api/tareas/reordenar', body: body);
      return true;
    } catch (e) {
      debugPrint('Error 500 en prioridades: $e');
      if (mounted) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
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
                      builder: (c, close) => InfoBar(
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
              builder: (c, close) => InfoBar(
                title: const Text('Historial Limpiado'),
                content: const Text('Las tareas antiguas fueron borradas con éxito.'),
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
    } finally {
      ctrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return material.Material(
      child: material.DefaultTabController(
        length: 3,
        child: ScaffoldPage(
          header: CompactPageHeader(
            title: Text(
              _esModoSoloLectura
                  ? 'Centro de Comando (solo lectura)'
                  : 'Centro de Comando Directivo',
            ),
            commandBar: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ToggleSwitch(
                  checked: _vistaCompacta,
                  onChanged: (v) => setState(() => _vistaCompacta = v),
                  content: const Text('Vista Compacta'),
                ),
                const SizedBox(width: 12),
                NotificationInboxButton(
                  unreadCount: _inboxUnread,
                  onOpen: () {
                    unawaited(_abrirBuzonNotificaciones());
                  },
                ),
                const SizedBox(width: 4),
                if (_puedeControlarMisiones) ...[
                  IconButton(
                    icon: Icon(FluentIcons.delete, color: material.Colors.red.shade400),
                    onPressed: _dialogoLimpiarHistorial,
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  icon: const Icon(FluentIcons.refresh),
                  onPressed: _loading ? null : _cargar,
                ),
              ],
            ),
          ),
          content: Column(
            children: [
              material.TabBar(
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
                  children: [
                    _tabActivas(),
                    _tabHistorial(),
                    _tabAltaManual(),
                  ],
                ),
              ),
            ],
          ),
        ),
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
    final entries = byUser.entries.toList()
      ..sort((a, b) {
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

  Widget _tarjetaActivaLobby(int globalIndex, Map<String, dynamic> t, bool dark) {
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
      onAbrirDialogoPrioridad: _puedeControlarMisiones
          ? (int tid) => _dialogoAsignarPrioridad(tid)
          : null,
      onCancel: () => _dialogoCancelarMision(id is int ? id : int.tryParse('$id') ?? 0),
      onPause: () => _dialogoPausar(id is int ? id : int.tryParse('$id') ?? 0),
      onResume: () => _reanudarMision(id is int ? id : int.tryParse('$id') ?? 0),
      onFinalizarManual: _puedeControlarMisiones
          ? () => _finalizarManualMision(id is int ? id : int.tryParse('$id') ?? 0)
          : null,
      onShowMeta: () {
        showMissionMetaSideSheet(context, t['meta']);
      },
    );
  }

  Widget _tabActivas() {
    if (_loading) return const Center(child: ProgressRing());
    if (_activasOrdenadas.isEmpty) {
      return Center(
        child: Text(
          'No hay misiones activas.',
          style: TextStyle(
            color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.8),
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
            : int.tryParse('${_activasOrdenadas[i]['id_tarea']}') ?? -1): i,
    };

    return material.Scrollbar(
      controller: _activasScrollController,
      thumbVisibility: true,
      child: material.SingleChildScrollView(
        controller: _activasScrollController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final lane in lanes)
              _SwimlaneRow(
                key: ValueKey('lane_${lane.key}'),
                usuario: lane.key,
                tareas: lane.value,
                colapsada: _swimlanesColapsadas.contains(lane.key),
                onToggleColapso: () => setState(() {
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
                  final gIdx = idToGlobalIndex[t['id_tarea'] is int
                      ? t['id_tarea'] as int
                      : int.tryParse('${t['id_tarea']}') ?? -1] ?? 0;
                  return _tarjetaActivaLobby(gIdx, t, dark);
                },
              ),
          ],
        ),
      ),
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
            color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.8),
          ),
        ),
      );
    }
    final dark = _isDark(context);
    // Un solo scroll (slivers): ListView + GridView shrinkWrap provocaba cajas sin tamaño / hit-test.
    return material.Scrollbar(
      controller: _historialScrollController,
      thumbVisibility: true,
      child: material.CustomScrollView(
        controller: _historialScrollController,
        slivers: [
          material.SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            sliver: material.SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Historial: misiones con progreso 100 %, estado terminado o canceladas. '
                    'En canceladas se muestra el motivo de forma destacada.',
                    style: TextStyle(
                      fontSize: 13,
                      color: FluentTheme.of(context)
                          .typography
                          .body
                          ?.color
                          ?.withValues(alpha: 0.85),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            ),
          ),
        material.SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          sliver: material.SliverGrid(
            gridDelegate: const material.SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 460,
              mainAxisExtent: 640,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            delegate: material.SliverChildBuilderDelegate(
              (context, i) {
                final t = hist[i];
                final id = t['id_tarea'];
                return RepaintBoundary(
                  key: ValueKey('hist_$id'),
                  child: DirectiveMissionCard(
                    task: t,
                    canControl: _puedeControlarMisiones,
                    permitirChecklist: false,
                    vistaMisionesActivas: false,
                    vistaHistorial: true,
                    checkEnProceso: _checkEnProceso,
                    isDark: dark,
                    onToggleCheck: _marcarChecklistItem,
                    onCargarBitacora: _cargarBitacora,
                    onCancel: null,
                    onPause: null,
                    onResume: null,
                    onFinalizarManual: null,
                    onShowMeta: () {
                      showMissionMetaSideSheet(context, t['meta']);
                    },
                  ),
                );
              },
              childCount: hist.length,
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _tabAltaManual() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Crear mision en servidor',
            style: FluentTheme.of(context).typography.subtitle?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Registra una tarea manual con responsable y categoria. '
            'Se guarda en SQL con SourceType Manual y CurrentAssignee.',
            style: TextStyle(
              color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _esModoSoloLectura ? null : _abrirAltaManual,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.add, size: 16),
                SizedBox(width: 8),
                Text('Nueva mision manual'),
              ],
            ),
          ),
        ],
      ),
    );
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
    final headerBg = dark
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
            // Avatar circular con iniciales
            material.Container(
              width: 42,
              height: 42,
              decoration: material.BoxDecoration(
                color: avatarColor,
                shape: material.BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: material.Text(
                iniciales,
                style: const material.TextStyle(
                  color: material.Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
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
                color: dark
                    ? material.Colors.white70
                    : material.Colors.black54,
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
