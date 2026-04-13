import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import 'task_display_utils.dart';

/// Azul prioridad normal / acento manual en monitoreo (menos saturado que Blue A400).
const Color _kMonitoreoAzulPrioridadNormal = Color(0xFF3A6FB3);

bool _tieneMetaUtil(Map<String, dynamic> task) {
  final m = task['meta'];
  if (m == null) return false;
  if (m is String) return m.trim().isNotEmpty;
  if (m is Map) return m.isNotEmpty;
  return true;
}

bool _tieneDetalleInfo(Map<String, dynamic> task) {
  return descripcionMision(task).isNotEmpty || _tieneMetaUtil(task);
}

bool _esPausaPorPrioridadUrgente(Map<String, dynamic> task) {
  if (!esPausada(task)) return false;
  final reasonRaw = task['pause_reason_id'] ?? task['Pause_Reason_ID'];
  final reasonId = reasonRaw is int ? reasonRaw : int.tryParse('$reasonRaw');
  if (reasonId == 4) return true;
  final motivo = (task['motivo_pausa'] ??
              task['Motivo_Pausa'] ??
              task['pause_reason'] ??
              task['PauseReason'] ??
              '')
          .toString()
          .trim()
          .toLowerCase();
  if (motivo.contains('prioridad urgente')) return true;
  final meta = task['meta'];
  if (meta is Map) {
    final m = (meta['motivo_pausa'] ?? meta['Motivo_Pausa'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (m.contains('prioridad urgente')) return true;
  }
  return false;
}

/// Valor corto para pastilla de tiempo (p. ej. "T. est.: n/a" -> "n/a").
String tiempoEtiquetaCortaParaPill(String tiempoCorto) {
  final parts = tiempoCorto.split(':');
  if (parts.length >= 2) {
    return parts.sublist(1).join(':').trim();
  }
  return tiempoCorto.trim();
}

/// Ancho común de Pausar/Finalizar cuando se apilan (2+ involucrados).
const double _kLobbyStackedActionWidth = 138;

/// Separación vertical entre Pausar y Finalizar (sin IntrinsicHeight / LayoutBuilder).
const double _kLobbyStackedActionGap = 6;

Widget _lobbyStackedInkAction({
  required double width,
  required double height,
  required VoidCallback? onPressed,
  required Color backgroundColor,
  required Widget child,
}) {
  return material.Material(
    type: material.MaterialType.transparency,
    child: material.InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: material.Ink(
        decoration: material.BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        width: width,
        height: height,
        child: material.Center(child: child),
      ),
    ),
  );
}

Color _onUserBg(Color c) => c.computeLuminance() > 0.45 ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);

Color? _tryHexToColor(String? hex) {
  final s = (hex ?? '').trim().toUpperCase();
  if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(s)) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _ensureReadableColorOn(Color base, Color bg, {double minRatio = 3.2}) {
  if (_contrastRatio(base, bg) >= minRatio) return base;
  var c = base;
  for (var i = 0; i < 8; i++) {
    if (_contrastRatio(c, bg) >= minRatio) break;
    final hsl = material.HSLColor.fromColor(c);
    final targetLight = bg.computeLuminance() < 0.4 ? 0.78 : 0.22;
    final nextLight = hsl.lightness + (targetLight - hsl.lightness) * 0.42;
    c = hsl.withLightness(nextLight.clamp(0.0, 1.0)).toColor();
  }
  return c;
}

class DirectiveMissionCard extends StatefulWidget {
  const DirectiveMissionCard({
    super.key,
    required this.task,
    required this.canControl,
    this.permitirChecklist = true,
    required this.vistaMisionesActivas,
    required this.checkEnProceso,
    required this.isDark,
    required this.onToggleCheck,
    this.onToggleGrupo,
    this.onAbrirDialogoPrioridad,
    this.onCargarBitacora,
    this.onCancel,
    this.onPause,
    this.onResume,
    this.onShowMeta,
    this.onFinalizarManual,
    this.onEditManual,
    this.vistaHistorial = false,
    this.vistaCompacta = false,
    this.lobbyStyle = false,
    this.lobbyIndex,
    this.lobbyCount,
    this.onReorderByDelta,
  });

  final Map<String, dynamic> task;
  final bool canControl;
  final bool permitirChecklist;
  final bool vistaMisionesActivas;
  final Set<int> checkEnProceso;
  final bool isDark;
  final bool vistaCompacta;
  final Future<void> Function(int idTarea, Map<String, dynamic> check, bool? v)
  onToggleCheck;
  final Future<void> Function(
    int idTarea,
    List<Map<String, dynamic>> grupo,
    bool hecho,
  )?
  onToggleGrupo;
  final Future<void> Function(int idTarea)? onAbrirDialogoPrioridad;
  final Future<List<Map<String, dynamic>>> Function(int idTarea)?
  onCargarBitacora;
  final VoidCallback? onCancel;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onShowMeta;
  final VoidCallback? onFinalizarManual;
  final VoidCallback? onEditManual;
  final bool vistaHistorial;
  final bool lobbyStyle;
  final int? lobbyIndex;
  final int? lobbyCount;
  final void Function(int index, int delta)? onReorderByDelta;

  @override
  State<DirectiveMissionCard> createState() => _DirectiveMissionCardState();
}

class _DirectiveMissionCardState extends State<DirectiveMissionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.vistaCompacta || _expanded) {
      final internalCard = _DirectiveMissionCardInternal(
        task: widget.task,
        canControl: widget.canControl,
        permitirChecklist: widget.permitirChecklist,
        vistaMisionesActivas: widget.vistaMisionesActivas,
        checkEnProceso: widget.checkEnProceso,
        isDark: widget.isDark,
        vistaCompacta: widget.vistaCompacta,
        onToggleCheck: widget.onToggleCheck,
        onToggleGrupo: widget.onToggleGrupo,
        onAbrirDialogoPrioridad: widget.onAbrirDialogoPrioridad,
        onCargarBitacora: widget.onCargarBitacora,
        onCancel: widget.onCancel,
        onPause: widget.onPause,
        onResume: widget.onResume,
        onShowMeta: widget.onShowMeta,
        onFinalizarManual: widget.onFinalizarManual,
        onEditManual: widget.onEditManual,
        vistaHistorial: widget.vistaHistorial,
        lobbyStyle: widget.lobbyStyle,
        lobbyIndex: widget.lobbyIndex,
        lobbyCount: widget.lobbyCount,
        onReorderByDelta: widget.onReorderByDelta,
      );

      if (!widget.vistaCompacta) return internalCard;
      return GestureDetector(
        onTap: () => setState(() => _expanded = false),
        child: internalCard,
      );
    }

    // VISTA COMPACTA
    final t = widget.task;
    final r = t['priority_rank'] ?? t['PriorityRank'];
    final n = r is int ? r : int.tryParse('$r');
    final pRank = (n != null) ? n + 1 : 0;

    material.Color andonBar =
        material.Color(_kMonitoreoAzulPrioridadNormal.value);
    if (pRank == 1) {
      andonBar = const material.Color(0xFFE53935);
    } else if (pRank == 2) {
      andonBar = const material.Color(0xFFFF9800);
    }

    final bg =
        widget.isDark
            ? const material.Color(0xFF2C2C32)
            : const material.Color(0xFFF0F0F3);
    final fg = widget.isDark ? material.Colors.white : material.Colors.black87;

    final String asignado =
        '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? 'Sin asignar'}'
            .trim();
    final pausada = esPausada(t);

    return material.Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      color: pausada
          ? (widget.isDark
              ? const material.Color(0xFF3A3E46)
              : const material.Color(0xFFE5E7EB))
          : bg,
      shape: material.RoundedRectangleBorder(
        borderRadius: material.BorderRadius.circular(8),
        side: material.BorderSide(
          color: andonBar.withValues(alpha: 0.55),
          width: 1.0,
        ),
      ),
      clipBehavior: material.Clip.antiAlias,
      child: material.InkWell(
        onTap: () => setState(() => _expanded = true),
        child: material.DecoratedBox(
          decoration: material.BoxDecoration(
            border: material.Border(
              left: material.BorderSide(width: 6.0, color: andonBar),
            ),
          ),
          child: material.Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: material.Row(
              children: [
                material.Icon(
                  esManualSource(t)
                      ? FluentIcons.page_list
                      : FluentIcons.bullseye_target,
                  color: andonBar,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: material.Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      material.Text(
                        tituloMision(t),
                        style: material.TextStyle(
                          fontWeight: material.FontWeight.w700,
                          fontSize: 13,
                          color: fg,
                        ),
                        maxLines: 1,
                        overflow: material.TextOverflow.ellipsis,
                      ),
                      material.Text(
                        asignado,
                        style: material.TextStyle(
                          fontSize: 11,
                          color: fg.withValues(alpha: pausada ? 0.55 : 0.7),
                        ),
                        maxLines: 1,
                        overflow: material.TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                material.Text(
                  '#${t['id_tarea']}',
                  style: material.TextStyle(
                    fontSize: 12,
                    fontWeight: material.FontWeight.w600,
                    color: fg.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DirectiveMissionCardInternal extends StatelessWidget {
  /// Sin alteración de color (evita rama duplicada junto a [ColorFiltered]).
  static const ColorFilter _lobbyColorIdentity = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  /// Tarjeta lobby pausada: aspecto “desactivado” (solo [Reanudar] queda a color).
  static const ColorFilter _lobbyPausadaGrayscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  const _DirectiveMissionCardInternal({
    required this.task,
    required this.canControl,
    this.permitirChecklist = true,
    required this.vistaMisionesActivas,
    required this.checkEnProceso,
    required this.isDark,
    required this.vistaCompacta,
    required this.onToggleCheck,
    this.onToggleGrupo,
    this.onAbrirDialogoPrioridad,
    this.onCargarBitacora,
    this.onCancel,
    this.onPause,
    this.onResume,
    this.onShowMeta,
    this.onFinalizarManual,
    this.onEditManual,
    this.vistaHistorial = false,
    this.lobbyStyle = false,
    this.lobbyIndex,
    this.lobbyCount,
    this.onReorderByDelta,
  });

  final Map<String, dynamic> task;
  final bool canControl;
  final bool permitirChecklist;
  final bool vistaMisionesActivas;
  final Set<int> checkEnProceso;
  final bool isDark;
  final Future<void> Function(int idTarea, Map<String, dynamic> check, bool? v)
  onToggleCheck;
  final Future<void> Function(
    int idTarea,
    List<Map<String, dynamic>> grupo,
    bool hecho,
  )?
  onToggleGrupo;

  /// Diálogo de prioridad (1–3) y suspensión opcional; solo misiones activas con control.
  final Future<void> Function(int idTarea)? onAbrirDialogoPrioridad;

  /// Historial: eventos desde `Tbl_Gestor_Tarea_Estado_Auditoria`.
  final Future<List<Map<String, dynamic>>> Function(int idTarea)?
  onCargarBitacora;
  final VoidCallback? onCancel;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onShowMeta;

  /// Cierre express para tareas con origen manual (progreso 100 %, estado Terminado).
  final VoidCallback? onFinalizarManual;
  final VoidCallback? onEditManual;

  /// Pestaña historial: resalta cancelaciones y motivo.
  final bool vistaHistorial;
  final bool vistaCompacta;

  /// Tarjeta tipo lobby (icono, título, barra gruesa) para misión activa en grid.
  final bool lobbyStyle;
  final int? lobbyIndex;
  final int? lobbyCount;
  final void Function(int index, int delta)? onReorderByDelta;

  static String _tituloChecklistUi(String raw, bool manual) {
    final h = tituloEncabezadoGrupoChecklist(raw).trim();
    if (!manual) return h;
    final lc = h.toLowerCase();
    final indef =
        h == kGrupoJerarquiaIndefinida ||
        lc.contains('[indefinido]') ||
        lc.contains('sin jerarquia definida');
    if (indef) return 'Tareas por completar';
    return h;
  }

  static const Color _kGreen = Color(0xFF00E676);
  static const Color _kYellow = Color(0xFFFFC107);
  static const Color _kRed = Color(0xFFE53935);
  static const Color _kBlue = _kMonitoreoAzulPrioridadNormal;
  static const Color _kNeutral = Color(0xFF78909C);

  /// PriorityRank en servidor: 0 = máxima prioridad (primera en grid).
  int? _andonPrioridad1Based() {
    final r = task['priority_rank'] ?? task['PriorityRank'];
    if (r == null) return null;
    final n = r is int ? r : int.tryParse('$r');
    if (n == null) return null;
    return n + 1;
  }

  Color _colorAndonPrioridad() {
    final br = _andonPrioridad1Based();
    // priority_rank 0–1 = primeros puestos (crítico / alta); 2+ o sin dato = normal (azul).
    if (br == null || br < 1) return _kBlue;
    if (br == 1) return const Color(0xFFE53935);
    if (br == 2) return const Color(0xFFFF9800);
    return _kBlue;
  }

  Color _colorSemaforo() {
    if (esCancelada(task)) return const Color(0xFF546E7A);
    if (esPausada(task)) return _kYellow;
    if (esCritica(task)) return _kRed;
    if (esEnProceso(task)) return _kGreen;
    if (esManualSource(task)) return _kBlue;
    return _kNeutral;
  }

  String _pillEstado() {
    if (esCancelada(task)) return 'CANCELADO';
    final p = int.tryParse('${task['porcentaje_progreso'] ?? 0}') ?? 0;
    if (p >= 100) return 'TERMINADO';
    if (esPausada(task)) return 'PAUSADO';
    final st = normEst(task);
    if (st.contains('proceso') || st == 'en proceso') return 'EN PROCESO';
    return 'PENDIENTE';
  }

  @override
  Widget build(BuildContext context) {
    final idTareaRaw = task['id_tarea'];
    final idTarea =
        idTareaRaw is int ? idTareaRaw : int.tryParse('$idTareaRaw') ?? 0;
    final p = int.tryParse('${task['porcentaje_progreso'] ?? 0}') ?? 0;
    final checks =
        (task['checklist'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final titulo = tituloMision(task);
    final asignado = asignadoMision(task);
    final usuariosAsignados = usuariosAsignadosLista(task);
    final avatarLabel = (() {
      final hasTodos = usuariosAsignados.any((u) {
        final n = u.trim().toUpperCase();
        return n == '__TODOS__' || n == 'TODOS';
      });
      if (hasTodos) return inicialesNombreUsuario('TODOS');
      if (usuariosAsignados.length > 2) return '+${usuariosAsignados.length}';
      if (usuariosAsignados.length == 2) {
        String ch(String name) {
          final ini = inicialesNombreUsuario(name);
          if (ini.isEmpty) return '?';
          return ini[0].toUpperCase();
        }

        return '${ch(usuariosAsignados[0])}${ch(usuariosAsignados[1])}';
      }
      final base =
          usuariosAsignados.isNotEmpty ? usuariosAsignados.first : asignado;
      return inicialesNombreUsuario(
        base.trim().isEmpty || base == 'Sin asignar' ? 'Sin asignar' : base,
      );
    })();
    final stroke = _colorSemaforo();
    final andonBar = _colorAndonPrioridad();
    final cancelada = esCancelada(task);
    final pausada = esPausada(task);
    final lobbyPausedMuted =
        lobbyStyle && vistaMisionesActivas && pausada && !cancelada;
    final andonBarLobby =
        lobbyPausedMuted
            ? (isDark ? const Color(0xFF585C65) : const Color(0xFF98A2B0))
            : andonBar;
    final lobbyCardStroke =
        lobbyPausedMuted
            ? (isDark ? const Color(0xFF6B7079) : const Color(0xFF8892A0))
            : stroke;
    final pausadaPorUrgente = _esPausaPorPrioridadUrgente(task);
    final criticaTarjeta =
        esCritica(task) && !cancelada && vistaMisionesActivas;
    final descCard = descripcionMision(task);
    final motivo = cancelada ? motivoCancelacion(task) : null;
    final showMotivo = cancelada && motivo != null && motivo.isNotEmpty;
    final showMotivoInline = showMotivo && !(vistaHistorial && cancelada);
    final motivoCancelacionTxt = motivo ?? '';
    final showMotivoHistorialBanner =
        vistaHistorial && cancelada && motivoCancelacionTxt.isNotEmpty;
    final fcHist = vistaHistorial ? fechaCierreHistorialLegible(task) : '';
    final ucHist = vistaHistorial ? usuarioCompletoHistorialLegible(task) : '';

    final bg = pausada
        ? (isDark ? const Color(0xFF3A3E46) : const Color(0xFFE5E7EB))
        : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFF0F0F3));
    final lobbySurface = BoxDecoration(
      gradient:
          (!pausada && criticaTarjeta)
              ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors:
                    isDark
                        ? const [
                          Color(0xFF3E2723),
                          Color(0xFF4E342E),
                          Color(0xFF1B1B1F),
                        ]
                        : const [
                          Color(0xFFFFF8E1),
                          Color(0xFFFFECB3),
                          Color(0xFFFFCDD2),
                        ],
              )
              : null,
      color: (!pausada && criticaTarjeta) ? null : bg,
      border: Border(left: BorderSide(width: 8.0, color: andonBarLobby)),
    );
    final fg = pausada
        ? (isDark ? const Color(0xFFD1D5DB) : const Color(0xFF4B5563))
        : (isDark ? const Color(0xFFECEFF1) : const Color(0xFF1B1B1B));
    final fgSec = pausada
        ? (isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280))
        : (isDark ? const Color(0xFFB0BEC5) : const Color(0xFF616161));

    material.Color barColor;
    if (cancelada) {
      barColor = const material.Color(0xFFE53935);
    } else if (p >= 100) {
      barColor = const material.Color(0xFF00E676);
    } else if (p > 0) {
      barColor = const material.Color(0xFFFF9100);
    } else {
      barColor = const material.Color(0xFFB0BEC5);
    }

    final tieneDetalleInfo = _tieneDetalleInfo(task);
    final tieneImagenAdjunta = imagenAdjuntaBase64Tarea(task) != null;
    final canEditManualMission =
        esManualSource(task) &&
        canControl &&
        !cancelada &&
        !pausada &&
        p < 100 &&
        onEditManual != null;
    final tiempoTxt = tiempoEstimadoEtiqueta(task);
    final totalMeta = totalMinutosPresupuestoCombinado(task);
    final tiempoCorto = (() {
      var s = tiempoTxt;
      s = s.replaceFirst('Tiempo estimado: ', 'T. est.: ');
      s = s.replaceAll(' hrs ', ' h ');
      s = s.replaceAll(' min', ' m');
      s = s.replaceAll(' no aplica', ' n/a');
      return s;
    })();

    final tiempoFooter = Tooltip(
      message:
          totalMeta != null
              ? 'Tiempo restante estimado = presupuesto ($totalMeta min) × (1 − progreso/100). '
                  'Radar: total_minutos en meta; manual: minutos al crear o checklist.'
              : 'Defina minutos estimados al crear la misión manual, marque «No aplica» si no aplica, '
                  'o use Radar para simulación con total_minutos.',
      child: Text(
        tiempoCorto,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fgSec,
        ),
        textAlign: TextAlign.right,
      ),
    );

    Widget iconTile(String tooltip, IconData icon, VoidCallback? onPressed) {
      return Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 34,
          height: 34,
          child: IconButton(
            icon: Icon(icon, size: 16),
            onPressed: onPressed,
          ),
        ),
      );
    }

    final iconRowUtilityChildren = <Widget>[
      if (onShowMeta != null && tieneDetalleInfo)
        iconTile(
          'Nombre, descripción al crear la misión y, si aplica, datos técnicos (Radar / auditoría).',
          FluentIcons.info_solid,
          onShowMeta,
        ),
      if (tieneImagenAdjunta)
        iconTile(
          'Ver imagen adjunta a la mision',
          FluentIcons.attach,
          () => mostrarImagenAdjuntaMision(context, task),
        ),
      if (vistaMisionesActivas &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100 &&
          onAbrirDialogoPrioridad != null)
        iconTile(
          'Asignar prioridad (1 Crítico, 2 Alta, 3 Normal)',
          FluentIcons.sort,
          () => onAbrirDialogoPrioridad!(idTarea),
        ),
    ];

    final iconRowChildren = <Widget>[
      ...iconRowUtilityChildren,
      if (vistaMisionesActivas && canControl && onCancel != null)
        iconTile('Cancelar misión', FluentIcons.delete, onCancel),
    ];

    final buttonRowChildren = <Widget>[
      if (vistaMisionesActivas &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100)
        Button(onPressed: onPause, child: const Text('Pausar')),
      if (vistaMisionesActivas && canControl && pausada && p < 100)
        Button(onPressed: onResume, child: const Text('Reanudar')),
      if (esManualSource(task) &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100 &&
          onFinalizarManual != null)
        Button(onPressed: onFinalizarManual, child: const Text('Finalizar')),
    ];

    final actionWrap = Align(
      alignment: Alignment.topRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconRowChildren.isNotEmpty)
              Wrap(
                spacing: 2,
                runSpacing: 2,
                alignment: WrapAlignment.end,
                children: iconRowChildren,
              ),
            if (buttonRowChildren.isNotEmpty) ...[
              if (iconRowChildren.isNotEmpty) const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: buttonRowChildren,
              ),
            ],
          ],
        ),
      ),
    );

    final checklistTile = _expansionChecklist(
      context,
      idTarea,
      task,
      checks,
      fg,
      fgSec,
      isDark,
      permitirChecklist && canControl && !pausada,
    );
    final controlesInferiores = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: checklistTile),
        const SizedBox(width: 10),
        Flexible(fit: FlexFit.loose, child: actionWrap),
      ],
    );

    final Widget? bitacoraHistorial =
        vistaHistorial && onCargarBitacora != null && idTarea > 0
            ? BitacoraHistorialExpansion(
              idTarea: idTarea,
              onLoad: onCargarBitacora!,
              fg: fg,
              fgSec: fgSec,
              isDark: isDark,
            )
            : null;

    material.Color colorUsuario(String u) {
      final fromTaskRaw = task['usuarios_colores'];
      if (fromTaskRaw is Map) {
        final k = u.trim().toLowerCase();
        String? hx;
        for (final entry in fromTaskRaw.entries) {
          final ku = '${entry.key}'.trim().toLowerCase();
          if (ku == k) {
            hx = '${entry.value}'.trim();
            break;
          }
        }
        final parsed = _tryHexToColor(hx);
        if (parsed != null) {
          return _ensureReadableColorOn(parsed, bg);
        }
      }
      if (u.trim().toLowerCase() == asignado.trim().toLowerCase()) {
        final parsed = _tryHexToColor('${task['usuario_color_hex'] ?? ''}');
        if (parsed != null) {
          return _ensureReadableColorOn(parsed, bg);
        }
      }
      const palette = <material.Color>[
        material.Color(0xFF64B5F6),
        material.Color(0xFF42A5F5),
        material.Color(0xFF5C6BC0),
        material.Color(0xFF7E57C2),
        material.Color(0xFFAB47BC),
        material.Color(0xFFBA68C8),
        material.Color(0xFF26C6DA),
        material.Color(0xFF29B6F6),
        material.Color(0xFFFF8A65),
        material.Color(0xFF00ACC1),
      ];
      var hash = 0;
      for (final c in u.codeUnits) {
        hash = (hash * 31 + c) & 0xFFFFFFFF;
      }
      return _ensureReadableColorOn(palette[hash.abs() % palette.length], bg);
    }

    final footerUsuarios = (() {
      final list = usuariosAsignados.isNotEmpty ? usuariosAsignados : <String>[asignado];
      final hasTodos = list.any((u) {
        final n = u.trim().toUpperCase();
        return n == '__TODOS__' || n == 'TODOS';
      });
      if (hasTodos) {
        return <Widget>[
          Text(
            'TODOS',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: fg,
              height: 1.18,
            ),
          ),
        ];
      }
      if (list.length <= 1) {
        final name = list.first.trim().isEmpty ? 'Sin asignar' : list.first;
        final uColor = colorUsuario(name);
        return <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                      color: uColor.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: uColor.withValues(alpha: 0.92)),
            ),
            child: Text(
              name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                        color: _onUserBg(uColor),
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ];
      }
      return [
            for (final u in list)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                  color: colorUsuario(u).withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: colorUsuario(u).withValues(alpha: 0.9)),
            ),
            child: Text(
              u,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                    color: _onUserBg(colorUsuario(u)),
                height: 1.15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ];
    })();

    final footerRow = Row(
      children: [
        Container(
          width: 8,
          height: 22,
          decoration: BoxDecoration(
            color: colorUsuario(asignado),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Icon(FluentIcons.contact, size: 16, color: fgSec),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: footerUsuarios,
          ),
        ),
        const SizedBox(width: 10),
        tiempoFooter,
        const SizedBox(width: 8),
        Icon(
          esManualSource(task)
              ? FluentIcons.page_list
              : FluentIcons.bullseye_target,
          size: 15,
          color: fgSec,
        ),
        const SizedBox(width: 4),
        Text(
          esManualSource(task) ? 'Manual' : 'Radar',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fgSec,
          ),
        ),
      ],
    );

    if (lobbyStyle && vistaMisionesActivas) {
      final idx = lobbyIndex ?? 0;
      final n = lobbyCount ?? 1;
      final tiempoPillTxt = tiempoEtiquetaCortaParaPill(tiempoCorto);
      Widget lobbyMetaPill(String text) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: fgSec.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: fgSec.withValues(alpha: 0.45)),
          ),
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              color: fgSec,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.35,
            ),
          ),
        );
      }

      final lobbyUtilityIcons = <Widget>[...iconRowUtilityChildren];

      material.Color lobbyHeaderAvatarMatteFill() {
        final list =
            usuariosAsignados.isNotEmpty ? usuariosAsignados : <String>[asignado];
        final hasTodos = list.any((u) {
          final n = u.trim().toUpperCase();
          return n == '__TODOS__' || n == 'TODOS';
        });
        final nameForColor =
            hasTodos
                ? (asignado.trim().isNotEmpty ? asignado : 'Todos')
                : (list.isEmpty || list.first.trim().isEmpty
                    ? asignado
                    : list.first.trim());
        final base = colorUsuario(nameForColor);
        return monitoreoUserMatteAvatarFill(base, isDark: isDark);
      }

      final headerAvatarFill = lobbyHeaderAvatarMatteFill();
      final headerAvatarFg =
          headerAvatarFill.computeLuminance() > 0.52
              ? const material.Color(0xFF0F172A)
              : material.Colors.white;

      Widget lobbyUserPill() {
        final list =
            usuariosAsignados.isNotEmpty ? usuariosAsignados : <String>[asignado];
        final hasTodos = list.any((u) {
          final name = u.trim().toUpperCase();
          return name == '__TODOS__' || name == 'TODOS';
        });
        if (hasTodos) {
          final v = monitoreoUserVividAccent(stroke, isDark: isDark);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: v.withValues(alpha: isDark ? 0.10 : 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: v, width: 1.35),
            ),
            child: Text(
              'TODOS',
              style: TextStyle(
                color: isDark ? material.Colors.white : material.Colors.black87,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.35,
              ),
            ),
          );
        }
        if (list.isEmpty || (list.length == 1 && list.first.trim().isEmpty)) {
          return lobbyMetaPill('SIN ASIGNAR');
        }
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final rawName in list)
                if (rawName.trim().isNotEmpty)
                  Builder(
                    builder: (context) {
                      final name = rawName.trim();
                      final uSoft = monitoreoUserVividAccent(
                        colorUsuario(name),
                        isDark: isDark,
                      );
                      return ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: uSoft.withValues(
                              alpha: isDark ? 0.10 : 0.08,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: uSoft, width: 1.35),
                          ),
                          child: Text(
                            name.toUpperCase(),
                            style: TextStyle(
                              color:
                                  isDark
                                      ? material.Colors.white
                                      : material.Colors.black87,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    },
                  ),
            ],
          ),
        );
      }

      int lobbyFooterAssignedUserCount() {
        final list =
            usuariosAsignados.isNotEmpty ? usuariosAsignados : <String>[asignado];
        if (list.any((u) {
          final n = u.trim().toUpperCase();
          return n == '__TODOS__' || n == 'TODOS';
        })) {
          return 99;
        }
        return list.map((e) => e.trim()).where((e) => e.isNotEmpty).length;
      }

      /// Altura de cada botón apilado: reparte ~la mitad del alto estimado de chips
      /// (sin medir intrínsecos: evita IntrinsicHeight + LayoutBuilder).
      double lobbyFooterStackedButtonSlotHeight() {
        var n = lobbyFooterAssignedUserCount();
        if (n >= 99) n = 8;
        const chipRow = 34.0;
        const runSp = 6.0;
        final assumedRows = n <= 2 ? 1 : (n + 1) ~/ 2;
        final leftH =
            assumedRows * chipRow +
            (assumedRows > 1 ? (assumedRows - 1) * runSp : 0.0);
        return ((leftH - _kLobbyStackedActionGap) / 2).clamp(40.0, 58.0);
      }

      final lobbyStackedSlotH = lobbyFooterStackedButtonSlotHeight();

      final lobbyShowPause =
          vistaMisionesActivas &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100;
      final lobbyShowResume =
          vistaMisionesActivas && canControl && pausada && p < 100;
      final lobbyShowFinalize =
          esManualSource(task) &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100 &&
          onFinalizarManual != null;

      final lobbyStackActionsVertically =
          lobbyFooterAssignedUserCount() >= 2 &&
          lobbyShowFinalize &&
          (lobbyShowPause || lobbyShowResume);

      Widget lobbyStackedFirstForHeight(double h) {
        if (lobbyShowPause) {
          final fg = isDark ? Colors.white : const Color(0xFF111827);
          final bg = isDark ? const Color(0xFF2D3139) : const Color(0xFFE5E7EB);
          return _lobbyStackedInkAction(
            width: _kLobbyStackedActionWidth,
            height: h,
            onPressed: onPause,
            backgroundColor: bg,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                material.Icon(material.Icons.pause, size: 14, color: fg),
                const SizedBox(width: 8),
                Text(
                  'Pausar',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }
        if (lobbyShowResume) {
          final fg =
              isDark ? const Color(0xFFDCFCE7) : const Color(0xFF065F46);
          final bg =
              isDark ? const Color(0xFF14532D) : const Color(0xFFD1FAE5);
          return _lobbyStackedInkAction(
            width: _kLobbyStackedActionWidth,
            height: h,
            onPressed: onResume,
            backgroundColor: bg,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                material.Icon(material.Icons.play_arrow, size: 16, color: fg),
                const SizedBox(width: 6),
                Text(
                  'Reanudar',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }
        return SizedBox(width: _kLobbyStackedActionWidth, height: h);
      }

      Widget lobbyStackedFinalizeForHeight(double h) {
        if (!lobbyShowFinalize) {
          return SizedBox(width: _kLobbyStackedActionWidth, height: h);
        }
        if (isDark) {
          return _lobbyStackedInkAction(
            width: _kLobbyStackedActionWidth,
            height: h,
            onPressed: onFinalizarManual,
            backgroundColor: Colors.white,
            child: const Text(
              'Finalizar',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                color: Colors.black,
              ),
            ),
          );
        }
        final accent = FluentTheme.of(context).accentColor;
        return _lobbyStackedInkAction(
          width: _kLobbyStackedActionWidth,
          height: h,
          onPressed: onFinalizarManual,
          backgroundColor: accent,
          child: const Text(
            'Finalizar',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
              color: Colors.white,
            ),
          ),
        );
      }

      final lobbyPrimaryActions = <Widget>[];
      if (vistaMisionesActivas &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100) {
        lobbyPrimaryActions.add(
          Button(
            onPressed: onPause,
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(
                isDark ? const Color(0xFF2D3139) : const Color(0xFFE5E7EB),
              ),
              foregroundColor: WidgetStateProperty.all(
                isDark ? Colors.white : const Color(0xFF111827),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                material.Icon(
                  material.Icons.pause,
                  size: 14,
                  color: isDark ? Colors.white : const Color(0xFF111827),
                ),
                const SizedBox(width: 8),
                const Text('Pausar'),
              ],
            ),
          ),
        );
      }
      if (vistaMisionesActivas && canControl && pausada && p < 100) {
        lobbyPrimaryActions.add(
          Button(
            onPressed: onResume,
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(
                isDark ? const Color(0xFF14532D) : const Color(0xFFD1FAE5),
              ),
              foregroundColor: WidgetStateProperty.all(
                isDark ? const Color(0xFFDCFCE7) : const Color(0xFF065F46),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                material.Icon(
                  material.Icons.play_arrow,
                  size: 16,
                  color:
                      isDark
                          ? const Color(0xFFDCFCE7)
                          : const Color(0xFF065F46),
                ),
                const SizedBox(width: 6),
                const Text('Reanudar'),
              ],
            ),
          ),
        );
      }
      if (esManualSource(task) &&
          canControl &&
          !cancelada &&
          !pausada &&
          p < 100 &&
          onFinalizarManual != null) {
        lobbyPrimaryActions.add(
          isDark
              ? FilledButton(
                  onPressed: onFinalizarManual,
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.all(Colors.white),
                    foregroundColor: WidgetStateProperty.all(Colors.black),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  child: const Text(
                    'Finalizar',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                )
              : FilledButton(
                  onPressed: onFinalizarManual,
                  style: ButtonStyle(
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  child: const Text(
                    'Finalizar',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
        );
      }

      final progressTrackColor = isDark
          ? const material.Color(0xFF3A3D45)
          : const material.Color(0xFFD6D6D6);

      final Widget? lobbyDeleteIcon =
          (vistaMisionesActivas && canControl && onCancel != null)
              ? (lobbyPausedMuted
                  ? ColorFiltered(
                    colorFilter: _lobbyPausadaGrayscale,
                    child: Tooltip(
                      message: 'Cancelar misión',
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: IconButton(
                          icon: const Icon(FluentIcons.delete, size: 16),
                          onPressed: onCancel,
                        ),
                      ),
                    ),
                  )
                  : Tooltip(
                    message: 'Cancelar misión',
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton(
                        icon: const Icon(FluentIcons.delete, size: 16),
                        onPressed: onCancel,
                      ),
                    ),
                  ))
              : null;

      return material.Card(
        elevation: isDark ? 6 : 4,
        color: material.Colors.transparent,
        shadowColor: lobbyCardStroke.withValues(alpha: 0.35),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: lobbyCardStroke.withValues(alpha: isDark ? 0.26 : 0.58),
            width: 1.35,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: lobbySurface,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showMotivoHistorialBanner)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    color:
                        isDark
                            ? const Color(0xFF4A1C1C)
                            : const Color(0xFFFFEBEE),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Motivo de cancelación',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color:
                                isDark
                                    ? const Color(0xFFFFCDD2)
                                    : const Color(0xFFB71C1C),
                            letterSpacing: 0.3,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          motivoCancelacionTxt,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            height: 1.35,
                            color:
                                isDark
                                    ? const Color(0xFFFFE0E0)
                                    : const Color(0xFF3E2723),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ColorFiltered(
                        colorFilter:
                            lobbyPausedMuted
                                ? _lobbyPausadaGrayscale
                                : _lobbyColorIdentity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                      // ── Header: flechas (≤42) | iniciales | título | editar | estado ──
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (onReorderByDelta != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: SizedBox(
                                height: 42,
                                width: 24,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    SizedBox(
                                      height: 20,
                                      width: 24,
                                      child: IconButton(
                                        icon: const Icon(
                                          FluentIcons.sort_up,
                                          size: 11,
                                        ),
                                        onPressed:
                                            idx > 0
                                                ? () =>
                                                    onReorderByDelta!(idx, -1)
                                                : null,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 20,
                                      width: 24,
                                      child: IconButton(
                                        icon: const Icon(
                                          FluentIcons.sort_down,
                                          size: 11,
                                        ),
                                        onPressed:
                                            idx < n - 1
                                                ? () =>
                                                    onReorderByDelta!(idx, 1)
                                                : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          Container(
                            width: 42,
                            height: 42,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                              color: headerAvatarFill,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              avatarLabel,
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              style: TextStyle(
                                fontSize: avatarLabel.length > 3 ? 8.5 : 14,
                                fontWeight: FontWeight.w900,
                                color: headerAvatarFg,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              titulo.toUpperCase(),
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                                color: fg,
                                height: 1.2,
                                letterSpacing: 0.2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            fit: FlexFit.loose,
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (canEditManualMission)
                                      Tooltip(
                                        message:
                                            'Editar checklist o imagen de la misión manual',
                                        child: SizedBox(
                                          width: 30,
                                          height: 30,
                                          child: IconButton(
                                            icon: const Icon(
                                              FluentIcons.edit,
                                              size: 14,
                                            ),
                                            onPressed: onEditManual,
                                          ),
                                        ),
                                      ),
                                    if (criticaTarjeta) ...[
                                      if (canEditManualMission)
                                        const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFB71C1C),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'CRÍTICO',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFFFFEBEE),
                                            letterSpacing: 0.6,
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (pausadaPorUrgente) ...[
                                      if (canEditManualMission || criticaTarjeta)
                                        const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF6D4C41),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'SUSPENDIDA',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFFFF3E0),
                                            letterSpacing: 0.45,
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (canEditManualMission ||
                                        criticaTarjeta ||
                                        pausadaPorUrgente)
                                      const SizedBox(width: 4),
                                    _pill(context, _pillEstado(), stroke),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (showMotivoInline) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Motivo: $motivo',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFFF8A80),
                            height: 1.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      // ── Progress section ──
                      const SizedBox(height: 18),
                      Text(
                        cancelada
                            ? 'PROGRESO: $p% (CANCELADA)'
                            : 'PROGRESO: $p%',
                        style: TextStyle(
                          fontSize: 11,
                          color: fgSec,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: material.LinearProgressIndicator(
                          value: (p / 100).clamp(0.0, 1.0),
                          minHeight: 4,
                          color: p > 0 ? barColor : progressTrackColor,
                          backgroundColor: progressTrackColor,
                        ),
                      ),
                      // ── Descripción + tiempo (pastilla a la derecha) ──
                      const SizedBox(height: 22),
                      SizedBox(
                        height: 36,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: descCard.isEmpty
                                  ? const SizedBox.shrink()
                                  : Align(
                                      alignment: Alignment.topLeft,
                                      child: Text(
                                        descCard.toUpperCase(),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: fgSec,
                                          height: 1.25,
                                          letterSpacing: 0.15,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 8, top: 0),
                              child: Tooltip(
                                message:
                                    totalMeta != null
                                        ? 'Tiempo restante estimado = presupuesto ($totalMeta min) × (1 − progreso/100).'
                                        : 'Tiempo estimado / restante de la misión.',
                                child: lobbyMetaPill(tiempoPillTxt),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ── Checklist + utility icons ──
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: checklistTile),
                          const SizedBox(width: 8),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 2,
                            runSpacing: 2,
                            children: lobbyUtilityIcons,
                          ),
                        ],
                      ),
                      if (bitacoraHistorial != null) ...[
                        const SizedBox(height: 10),
                        bitacoraHistorial,
                      ],
                          ],
                        ),
                      ),
                      // ── Footer: user pill + actions (Reanudar sin filtro en pausa) ──
                      const SizedBox(height: 16),
                      if (lobbyStackActionsVertically)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.topLeft,
                                child:
                                    lobbyPausedMuted
                                        ? ColorFiltered(
                                          colorFilter: _lobbyPausadaGrayscale,
                                          child: lobbyUserPill(),
                                        )
                                        : lobbyUserPill(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: _kLobbyStackedActionWidth,
                                      height: lobbyStackedSlotH,
                                      child: lobbyStackedFirstForHeight(
                                        lobbyStackedSlotH,
                                      ),
                                    ),
                                    const SizedBox(
                                      height: _kLobbyStackedActionGap,
                                    ),
                                    SizedBox(
                                      width: _kLobbyStackedActionWidth,
                                      height: lobbyStackedSlotH,
                                      child: lobbyStackedFinalizeForHeight(
                                        lobbyStackedSlotH,
                                      ),
                                    ),
                                  ],
                                ),
                                if (lobbyDeleteIcon != null) ...[
                                  const SizedBox(width: 6),
                                  lobbyDeleteIcon,
                                ],
                              ],
                            ),
                          ],
                        )
                      else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child:
                                  lobbyPausedMuted
                                      ? ColorFiltered(
                                        colorFilter: _lobbyPausadaGrayscale,
                                        child: lobbyUserPill(),
                                      )
                                      : lobbyUserPill(),
                            ),
                            const SizedBox(width: 8),
                            if (lobbyPrimaryActions.isNotEmpty ||
                                lobbyDeleteIcon != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < lobbyPrimaryActions.length;
                                    i++
                                  ) ...[
                                    if (i > 0) const SizedBox(width: 8),
                                    lobbyPrimaryActions[i],
                                  ],
                                  if (lobbyDeleteIcon != null) ...[
                                    if (lobbyPrimaryActions.isNotEmpty)
                                      const SizedBox(width: 6),
                                    lobbyDeleteIcon,
                                  ],
                                ],
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 8, color: andonBar),
          Expanded(
            child: material.Material(
              color: material.Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  gradient:
                      criticaTarjeta
                          ? LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors:
                                isDark
                                    ? const [
                                      Color(0xFF3E2723),
                                      Color(0xFF4E342E),
                                      Color(0xFF1B1B1F),
                                    ]
                                    : const [
                                      Color(0xFFFFF8E1),
                                      Color(0xFFFFECB3),
                                      Color(0xFFFFCDD2),
                                    ],
                          )
                          : null,
                  color: criticaTarjeta ? null : bg,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showMotivoHistorialBanner)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                            decoration: BoxDecoration(
                              color:
                                  isDark
                                      ? const Color(0xFF4A1C1C)
                                      : const Color(0xFFFFEBEE),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Motivo de cancelación',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color:
                                        isDark
                                            ? const Color(0xFFFFCDD2)
                                            : const Color(0xFFB71C1C),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  motivoCancelacionTxt,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                    color:
                                        isDark
                                            ? const Color(0xFFFFE0E0)
                                            : const Color(0xFF3E2723),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  height: 38,
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: Text(
                                      titulo,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: fg,
                                        height: 1.2,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                if (showMotivoInline) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Motivo: $motivo',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFFF8A80),
                                      height: 1.2,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (criticaTarjeta) ...[
                            Container(
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFB71C1C),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'CRÍTICO',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFFFEBEE),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                          if (canEditManualMission)
                            Tooltip(
                              message: 'Editar checklist o imagen de la misión manual',
                              child: IconButton(
                                icon: const Icon(FluentIcons.edit, size: 16),
                                onPressed: onEditManual,
                              ),
                            ),
                          _pill(context, _pillEstado(), stroke),
                          if (pausadaPorUrgente) ...[
                            const SizedBox(width: 6),
                            Container(
                              margin: const EdgeInsets.only(right: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF6D4C41),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'SUSPENDIDA',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFFFFF3E0),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: material.LinearProgressIndicator(
                          value: (p / 100).clamp(0.0, 1.0),
                          minHeight: 6,
                          color: barColor,
                          backgroundColor:
                              isDark
                                  ? const material.Color(0xFF1E1E22)
                                  : const material.Color(0xFFE0E0E0),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        cancelada
                            ? 'Progreso: $p% (Cancelada)'
                            : 'Progreso: $p%',
                        style: TextStyle(fontSize: 11, color: fgSec),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 34,
                        child: descCard.isEmpty
                            ? const SizedBox.shrink()
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      descCard,
                                      style: TextStyle(
                                        fontSize: 12.4,
                                        fontWeight: FontWeight.w600,
                                        color: fg,
                                        height: 1.2,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Tooltip(
                                    message: 'Ver descripción completa',
                                    child: SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        icon: const Icon(FluentIcons.read, size: 14),
                                        onPressed: () =>
                                            _showMissionDescriptionDialog(context, descCard),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      if (vistaHistorial &&
                          (fcHist.isNotEmpty || ucHist.isNotEmpty)) ...[
                        const SizedBox(height: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (fcHist.isNotEmpty)
                              Text(
                                'Cierre: $fcHist',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: fgSec,
                                  height: 1.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (ucHist.isNotEmpty) ...[
                              if (fcHist.isNotEmpty) const SizedBox(height: 4),
                              Text(
                                'Completado por: $ucHist',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: fgSec.withValues(alpha: 0.9),
                                  height: 1.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      controlesInferiores,
                      if (bitacoraHistorial != null) ...[
                        const SizedBox(height: 6),
                        bitacoraHistorial,
                      ],
                      const Divider(),
                      footerRow,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expansionChecklist(
    BuildContext context,
    int idTarea,
    Map<String, dynamic> task,
    List<Map<String, dynamic>> checks,
    Color fg,
    Color fgSec,
    bool isDark,
    bool puedeEditar,
  ) {
    final agrupados = entregablesAgrupadosDesdeMeta(task);
    final body =
        checks.isEmpty
            ? <Widget>[
              Text(
                'Sin items en checklist.',
                style: TextStyle(color: fgSec, fontSize: 12),
              ),
            ]
            : (agrupados != null && agrupados.isNotEmpty)
            ? _checklistWidgetsFromMeta(
              idTarea,
              checks,
              agrupados,
              fg: fg,
              fgMuted: fgSec,
              isDark: isDark,
              puedeEditar: puedeEditar,
            )
            : _checklistWidgets(
              idTarea,
              checks,
              fg: fg,
              fgMuted: fgSec,
              isDark: isDark,
              puedeEditar: puedeEditar,
              hidePlaceholderGroupHeader: esManualSource(task),
            );
    return MissionChecklistScrollPane(
      title: 'Checklist (${checks.length})',
      fg: fg,
      fgSec: fgSec,
      isDark: isDark,
      scrollChildren: body,
    );
  }

  Widget _pill(BuildContext context, String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.85)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  List<Widget> _checklistWidgets(
    int idTarea,
    List<Map<String, dynamic>> checks, {
    required Color fg,
    required Color fgMuted,
    required bool isDark,
    required bool puedeEditar,
    bool hidePlaceholderGroupHeader = false,
  }) {
    final byGroup = <String, List<Map<String, dynamic>>>{};
    for (final c in checks) {
      final g = grupoDeCheck(c);
      byGroup.putIfAbsent(g, () => []).add(c);
    }
    final keys = byGroup.keys.toList()..sort(compareGrupoChecklist);
    final out = <Widget>[];
    if (hidePlaceholderGroupHeader && keys.length == 1) {
      final header = tituloEncabezadoGrupoChecklist(keys.first).trim();
      if (header == kGrupoJerarquiaIndefinida) {
        return [
          for (final c in byGroup[keys.first]!)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 6),
              child: _filaCheck(idTarea, c, puedeEditar, fgMuted),
            ),
        ];
      }
    }
    final headerBg = isDark ? const Color(0xFF38383F) : const Color(0xFFE4E7EF);
    for (var gi = 0; gi < keys.length; gi++) {
      final g = keys[gi];
      final list = byGroup[g]!;
      final headerText = _tituloChecklistUi(g, esManualSource(task));

      final filasItems = <Widget>[
        for (final c in list)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: _filaCheck(idTarea, c, puedeEditar, fgMuted),
          ),
      ];

      final encabezadoGrupo = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: headerBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: fgMuted.withValues(alpha: 0.38)),
        ),
        child: Text(
          headerText,
          softWrap: true,
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 14.5,
            height: 1.25,
            color: fg,
            letterSpacing: 0.2,
          ),
        ),
      );

      out.add(
        Padding(
          padding: EdgeInsets.only(top: gi == 0 ? 0 : 22, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              encabezadoGrupo,
              const SizedBox(height: 10),
              ...filasItems,
            ],
          ),
        ),
      );
    }
    return out;
  }

  /// Normaliza un string de grupo para comparación: elimina el sufijo
  /// "- (Clientes: …)" que el backend nuevo NO incluye en el campo `grupo`
  /// de cada ítem pero SÍ puede haber quedado en registros legados.
  static String _normGrupoParaMatch(String raw) {
    // Ejemplo con clientes: "[R] > [T] > [V1] - (Clientes: ATR, DX)"
    // Ejemplo sin clientes:  "[R] > [T] > [V1]"
    // Queremos siempre comparar solo la parte jerárquica.
    final idx = raw.indexOf(' - (Clientes:');
    return (idx >= 0 ? raw.substring(0, idx) : raw).trim();
  }

  Map<String, dynamic>? _matchCheckToSimTemplate(
    List<Map<String, dynamic>> checks,
    Set<int> usedIds,
    String grupoTituloBloque,
    Map<String, dynamic> tpl,
  ) {
    final wantNombre =
        '${tpl['nombre'] ?? ''}'.split(RegExp(r'\r?\n')).first.trim();
    // wantGrupo: puede ser la ruta base "[R] > [T] > [V]" (nuevo)
    // o el titulo completo con clientes (legado). Normalizar antes de comparar.
    final wantGrupoRaw = '${tpl['grupo'] ?? grupoTituloBloque}'.trim();
    final wantGrupoNorm = _normGrupoParaMatch(wantGrupoRaw);
    for (final c in checks) {
      final id = idCheckDe(c);
      if (id != null && usedIds.contains(id)) continue;
      // Comparar normalizando ambos lados para compatibilidad legado/nuevo.
      final checkGrupoNorm = _normGrupoParaMatch(grupoDeCheck(c));
      if (checkGrupoNorm != wantGrupoNorm) continue;
      if (nombrePrimeraLineaCheck(c) != wantNombre) continue;
      return c;
    }
    return null;
  }

  /// Igual que [_matchCheckToSimTemplate] pero ignora el grupo (solo por nombre).
  /// Usado como fallback para tareas legadas donde grupo en BD = [Indefinido].
  Map<String, dynamic>? _matchCheckByNombreOnly(
    List<Map<String, dynamic>> checks,
    Set<int> usedIds,
    Map<String, dynamic> tpl,
  ) {
    final wantNombre =
        '${tpl['nombre'] ?? ''}'.split(RegExp(r'\r?\n')).first.trim();
    for (final c in checks) {
      final id = idCheckDe(c);
      if (id != null && usedIds.contains(id)) continue;
      if (nombrePrimeraLineaCheck(c) == wantNombre) return c;
    }
    return null;
  }

  /// Orden y títulos de grupo según `meta.entregables_agrupados` (simulación Radar).
  ///
  /// Estrategia en 2 pasadas:
  /// - Pasada 1 (estricta): nombre + grupo normalizado (tareas post-fix).
  /// - Pasada 2 (flexible): solo nombre, sin grupo (tareas legadas con bug de grupo=[Indefinido]).
  List<Widget> _checklistWidgetsFromMeta(
    int idTarea,
    List<Map<String, dynamic>> checks,
    List<Map<String, dynamic>> agrupados, {
    required Color fg,
    required Color fgMuted,
    required bool isDark,
    required bool puedeEditar,
  }) {
    final usedIds = <int>{};
    final out = <Widget>[];
    final headerBg = isDark ? const Color(0xFF38383F) : const Color(0xFFE4E7EF);
    var gi = 0;

    // ── Pasada 1: matching estricto (nombre + grupo) ────────────────────────
    final matchedPerBlock = <List<Map<String, dynamic>>>[];
    for (final block in agrupados) {
      final gtRaw = '${block['grupo_titulo'] ?? ''}'.trim();
      final itemsTpl = block['items'] as List<dynamic>? ?? const [];
      final matched = <Map<String, dynamic>>[];
      for (final t in itemsTpl) {
        if (t is! Map) continue;
        final tpl = Map<String, dynamic>.from(
          t.map((k, v) => MapEntry('$k', v)),
        );
        final c = _matchCheckToSimTemplate(checks, usedIds, gtRaw, tpl);
        if (c != null) {
          final id = idCheckDe(c);
          if (id != null) usedIds.add(id);
          matched.add(c);
        }
      }
      matchedPerBlock.add(matched);
    }

    // Si pasada 1 no encontró nada (tareas legadas con grupo=[Indefinido] en BD),
    // intentar pasada 2: matching flexible solo por nombre de ítem.
    final totalP1 = matchedPerBlock.fold<int>(0, (s, m) => s + m.length);
    if (totalP1 == 0 && checks.isNotEmpty) {
      usedIds.clear();
      for (var bi = 0; bi < agrupados.length; bi++) {
        final itemsTpl = agrupados[bi]['items'] as List<dynamic>? ?? const [];
        final matched2 = <Map<String, dynamic>>[];
        for (final t in itemsTpl) {
          if (t is! Map) continue;
          final tpl = Map<String, dynamic>.from(
            t.map((k, v) => MapEntry('$k', v)),
          );
          final c = _matchCheckByNombreOnly(checks, usedIds, tpl);
          if (c != null) {
            final id = idCheckDe(c);
            if (id != null) usedIds.add(id);
            matched2.add(c);
          }
        }
        matchedPerBlock[bi] = matched2;
      }
    }

    // ── Renderizar bloques ──────────────────────────────────────────────────
    for (var bi = 0; bi < agrupados.length; bi++) {
      final block = agrupados[bi];
      final matched = matchedPerBlock[bi];
      if (matched.isEmpty) continue;

      final gtRaw = '${block['grupo_titulo'] ?? ''}'.trim();
      final headerText = _tituloChecklistUi(gtRaw, esManualSource(task));

      final filasItems = <Widget>[
        for (final c in matched)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: _filaCheck(idTarea, c, puedeEditar, fgMuted),
          ),
      ];

      final encabezadoGrupo = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: headerBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: fgMuted.withValues(alpha: 0.38)),
        ),
        child: Text(
          headerText,
          softWrap: true,
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 14.5,
            height: 1.25,
            color: fg,
            letterSpacing: 0.2,
          ),
        ),
      );

      out.add(
        Padding(
          padding: EdgeInsets.only(top: gi == 0 ? 0 : 22, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              encabezadoGrupo,
              const SizedBox(height: 10),
              ...filasItems,
            ],
          ),
        ),
      );
      gi++;
    }

    final orphans =
        checks.where((c) {
          final id = idCheckDe(c);
          return id == null || !usedIds.contains(id);
        }).toList();
    if (orphans.isNotEmpty) {
      if (out.isNotEmpty) {
        out.add(const SizedBox(height: 22));
      }
      out.addAll(
        _checklistWidgets(
          idTarea,
          orphans,
          fg: fg,
          fgMuted: fgMuted,
          isDark: isDark,
          puedeEditar: puedeEditar,
        ),
      );
    }

    return out;
  }

  Widget _filaCheck(
    int idTarea,
    Map<String, dynamic> c,
    bool puedeEditar,
    Color fgMuted,
  ) {
    final done = checkItemHecho(c);
    final label = etiquetaPrincipalChecklistUI(c);
    final sub = textoSecundarioChecklistUI(textoSecundarioCheck(c));
    final idCh = idCheckDe(c);
    final bloqueado = idCh != null && checkEnProceso.contains(idCh);
    final ok = puedeEditar && !bloqueado;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        material.Checkbox(
          value: done,
          onChanged:
              ok
                  ? (bool? v) {
                    if (v != null) onToggleCheck(idTarea, c, v);
                  }
                  : null,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 6, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  softWrap: true,
                  maxLines: 12,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.25),
                ),
                if (sub != null && sub.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      sub,
                      softWrap: true,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.25,
                        color: fgMuted.withValues(alpha: 0.92),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Checklist expandible: [Scrollbar] y [ListView] comparten el mismo [ScrollController].
class MissionChecklistScrollPane extends StatefulWidget {
  const MissionChecklistScrollPane({
    super.key,
    required this.title,
    required this.fg,
    required this.fgSec,
    required this.isDark,
    required this.scrollChildren,
  });

  final String title;
  final Color fg;
  final Color fgSec;
  final bool isDark;
  final List<Widget> scrollChildren;

  @override
  State<MissionChecklistScrollPane> createState() =>
      _MissionChecklistScrollPaneState();
}

class _MissionChecklistScrollPaneState
    extends State<MissionChecklistScrollPane> {
  final material.ScrollController _sc = material.ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return material.Material(
      color: Colors.transparent,
      child: material.Theme(
        data: material.ThemeData(
          brightness: widget.isDark ? Brightness.dark : Brightness.light,
          dividerColor: widget.fgSec.withValues(alpha: 0.25),
        ),
        child: material.ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -3),
          minTileHeight: 26,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            widget.title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: widget.fg,
            ),
          ),
          children: [
            material.Scrollbar(
              controller: _sc,
              thumbVisibility: true,
              child: material.ListView(
                controller: _sc,
                shrinkWrap: true,
                physics: const AlwaysScrollableScrollPhysics(),
                children: widget.scrollChildren,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Historial: bitácora desde auditoría de estados (carga al expandir).
class BitacoraHistorialExpansion extends StatefulWidget {
  const BitacoraHistorialExpansion({
    super.key,
    required this.idTarea,
    required this.onLoad,
    required this.fg,
    required this.fgSec,
    required this.isDark,
  });

  final int idTarea;
  final Future<List<Map<String, dynamic>>> Function(int idTarea) onLoad;
  final Color fg;
  final Color fgSec;
  final bool isDark;

  @override
  State<BitacoraHistorialExpansion> createState() =>
      _BitacoraHistorialExpansionState();
}

class _BitacoraHistorialExpansionState
    extends State<BitacoraHistorialExpansion> {
  bool _cargando = false;
  bool _pidio = false;
  List<Map<String, dynamic>> _items = [];
  String? _err;

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _err = null;
    });
    try {
      final r = await widget.onLoad(widget.idTarea);
      if (!mounted) return;
      setState(() {
        _items = r;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '$e';
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return material.Material(
      color: Colors.transparent,
      child: material.Theme(
        data: material.ThemeData(
          brightness: widget.isDark ? Brightness.dark : Brightness.light,
          dividerColor: widget.fgSec.withValues(alpha: 0.25),
        ),
        child: material.ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
          title: Text(
            'Bitácora de eventos',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: widget.fg,
            ),
          ),
          onExpansionChanged: (exp) {
            if (exp && !_pidio) {
              _pidio = true;
              _cargar();
            }
          },
          children: [
            if (_cargando)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: ProgressRing(strokeWidth: 2)),
              )
            else if (_err != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _err!,
                  style: const TextStyle(
                    color: Color(0xFFE53935),
                    fontSize: 12,
                  ),
                ),
              )
            else if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Sin eventos en la bitácora (pausas y cambios de estado aparecen aquí).',
                  style: TextStyle(color: widget.fgSec, fontSize: 12),
                ),
              )
            else
              ..._items.map((e) {
                final hora = '${e['hora'] ?? ''}'.trim();
                final txt = '${e['texto'] ?? ''}'.trim();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 118,
                        child: Text(
                          hora.isEmpty ? '—' : hora,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: widget.fgSec,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          txt.isEmpty ? '—' : txt,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: widget.fg,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

void _showMissionDescriptionDialog(BuildContext context, String descripcion) {
  showDialog(
    context: context,
    builder: (ctx) => ContentDialog(
      title: const Text('Descripción completa'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Text(
            descripcion.trim().isEmpty ? 'Sin descripción.' : descripcion.trim(),
            style: const TextStyle(fontSize: 13, height: 1.3),
          ),
        ),
      ),
      actions: [
        Button(child: const Text('Cerrar'), onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
}

/// Resultado de [showAsignarPrioridadMissionDialog].
class PrioridadMisionDialogResult {
  PrioridadMisionDialogResult({
    required this.nivel,
    required this.suspenderOtras,
  });

  /// 1 = Crítico, 2 = Alta, 3 = Normal (UI).
  final int nivel;
  final bool suspenderOtras;
}

/// Diálogo de prioridad con [State] propio para que los [RadioButton] redibujen al instante.
Future<PrioridadMisionDialogResult?> showAsignarPrioridadMissionDialog(
  BuildContext context, {
  required int nivelInicial,
}) {
  return showDialog<PrioridadMisionDialogResult>(
    context: context,
    builder: (ctx) => _PrioridadMisionDialogContent(nivelInicial: nivelInicial),
  );
}

class _PrioridadMisionDialogContent extends StatefulWidget {
  const _PrioridadMisionDialogContent({required this.nivelInicial});

  final int nivelInicial;

  @override
  State<_PrioridadMisionDialogContent> createState() =>
      _PrioridadMisionDialogContentState();
}

class _PrioridadMisionDialogContentState
    extends State<_PrioridadMisionDialogContent> {
  late int _sel;
  bool _suspender = false;

  @override
  void initState() {
    super.initState();
    _sel = widget.nivelInicial;
  }

  Widget _opt(int nivel, String label, material.Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: material.InkWell(
        onTap: () => setState(() => _sel = nivel),
        borderRadius: material.BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: RadioButton(
            checked: _sel == nivel,
            onChanged: (_) => setState(() => _sel = nivel),
            content: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: const Text('Asignar prioridad'),
      constraints: const BoxConstraints(maxWidth: 400),
      content: material.Material(
        type: material.MaterialType.transparency,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _opt(1, '1 — Crítico', const material.Color(0xFFE53935)),
              _opt(2, '2 — Alta', const material.Color(0xFFFF9800)),
              _opt(3, '3 — Normal', _kMonitoreoAzulPrioridadNormal),
              if (_sel == 1) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Suspender otras tareas de este responsable',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                    ToggleSwitch(
                      checked: _suspender,
                      onChanged: (v) => setState(() => _suspender = v),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              PrioridadMisionDialogResult(
                nivel: _sel,
                suspenderOtras: _suspender,
              ),
            );
          },
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}

void mostrarImagenAdjuntaMision(
  BuildContext context,
  Map<String, dynamic> task,
) {
  final b64 = imagenAdjuntaBase64Tarea(task);
  if (b64 == null || b64.isEmpty) return;
  Uint8List bytes;
  try {
    bytes = base64Decode(b64);
  } catch (_) {
    displayInfoBar(
      context,
      builder:
          (c, close) => InfoBar(
            title: const Text('Imagen'),
            content: const Text('No se pudo decodificar la imagen adjunta.'),
            severity: InfoBarSeverity.warning,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          ),
    );
    return;
  }
  showDialog<void>(
    context: context,
    builder:
        (ctx) => ContentDialog(
          title: const Text('Imagen adjunta'),
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
          content: SizedBox(
            width: 560,
            height: 440,
            child: material.InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Center(
                child: material.Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  errorBuilder:
                      (_, __, ___) =>
                          const Text('No se pudo mostrar la imagen'),
                ),
              ),
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
}
