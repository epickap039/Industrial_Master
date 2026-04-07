import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import 'task_display_utils.dart';

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

    material.Color andonBar = const material.Color(0xFF90A4AE);
    if (pRank == 1) {
      andonBar = const material.Color(0xFFE53935);
    } else if (pRank == 2)
      andonBar = const material.Color(0xFFFF9800);
    else if (pRank == 3)
      andonBar = const material.Color(0xFF2979FF);

    final bg =
        widget.isDark
            ? const material.Color(0xFF2C2C32)
            : const material.Color(0xFFF0F0F3);
    final fg = widget.isDark ? material.Colors.white : material.Colors.black87;

    final String asignado =
        '${t['usuario_asignado'] ?? t['Usuario_Asignado'] ?? 'Sin asignar'}'
            .trim();

    return material.Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      color: bg,
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
                          color: fg.withValues(alpha: 0.7),
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

  /// Pestaña historial: resalta cancelaciones y motivo.
  final bool vistaHistorial;
  final bool vistaCompacta;

  /// Tarjeta tipo lobby (icono, título, barra gruesa) para misión activa en grid.
  final bool lobbyStyle;
  final int? lobbyIndex;
  final int? lobbyCount;
  final void Function(int index, int delta)? onReorderByDelta;

  static const Color _kGreen = Color(0xFF00E676);
  static const Color _kYellow = Color(0xFFFFC107);
  static const Color _kRed = Color(0xFFE53935);
  static const Color _kBlue = Color(0xFF2979FF);
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
    if (br == null || br < 1) return const Color(0xFF90A4AE);
    if (br == 1) return const Color(0xFFE53935);
    if (br == 2) return const Color(0xFFFF9800);
    if (br == 3) return const Color(0xFF2979FF);
    return const Color(0xFF90A4AE);
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
    final stroke = _colorSemaforo();
    final andonBar = _colorAndonPrioridad();
    final cancelada = esCancelada(task);
    final pausada = esPausada(task);
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

    final bg = isDark ? const Color(0xFF2C2C32) : const Color(0xFFF0F0F3);
    final lobbySurface = BoxDecoration(
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
      border: Border(left: BorderSide(width: 8.0, color: andonBar)),
    );
    final fg = isDark ? const Color(0xFFECEFF1) : const Color(0xFF1B1B1B);
    final fgSec = isDark ? const Color(0xFFB0BEC5) : const Color(0xFF616161);

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
    final tiempoTxt = tiempoEstimadoEtiqueta(task);
    final totalMeta = totalMinutosPresupuestoCombinado(task);

    final presupuestoBlock = Tooltip(
      message:
          totalMeta != null
              ? 'Tiempo restante estimado = presupuesto ($totalMeta min) × (1 − progreso/100). '
                  'Radar: total_minutos en meta; manual: minutos al crear o checklist.'
              : 'Defina minutos estimados al crear la misión manual, marque «No aplica» si no aplica, '
                  'o use Radar para simulación con total_minutos.',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          tiempoTxt,
          textAlign: lobbyStyle ? TextAlign.start : TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: fg,
            height: 1.25,
          ),
        ),
      ),
    );

    final actionWrap = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onShowMeta != null && tieneDetalleInfo)
          Tooltip(
            message:
                'Nombre, descripción al crear la misión y, si aplica, datos técnicos (Radar / auditoría).',
            child: IconButton(
              icon: const Icon(FluentIcons.info, size: 16),
              onPressed: onShowMeta,
            ),
          ),
        if (tieneImagenAdjunta)
          Tooltip(
            message: 'Ver imagen adjunta a la mision',
            child: IconButton(
              icon: const Icon(FluentIcons.attach, size: 16),
              onPressed: () => mostrarImagenAdjuntaMision(context, task),
            ),
          ),
        if (vistaMisionesActivas &&
            canControl &&
            !cancelada &&
            !pausada &&
            p < 100 &&
            onAbrirDialogoPrioridad != null)
          Tooltip(
            message: 'Asignar prioridad (1 Crítico, 2 Alta, 3 Normal)',
            child: IconButton(
              icon: const Icon(FluentIcons.sort, size: 16),
              onPressed: () => onAbrirDialogoPrioridad!(idTarea),
            ),
          ),
        if (vistaMisionesActivas &&
            canControl &&
            !cancelada &&
            !pausada &&
            p < 100)
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(const Color(0xFFFFA000)),
            ),
            onPressed: onPause,
            child: const Text('Pausar'),
          ),
        if (vistaMisionesActivas && canControl && pausada && p < 100)
          FilledButton(onPressed: onResume, child: const Text('Reanudar')),
        if (esManualSource(task) &&
            canControl &&
            !cancelada &&
            !pausada &&
            p < 100 &&
            onFinalizarManual != null)
          FilledButton(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.all(const Color(0xFF2979FF)),
            ),
            onPressed: onFinalizarManual,
            child: const Text('Finalizar'),
          ),
        if (vistaMisionesActivas && canControl && onCancel != null)
          IconButton(
            icon: const Icon(FluentIcons.delete, size: 16),
            onPressed: onCancel,
          ),
      ],
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

    final footerRow = Row(
      children: [
        Icon(FluentIcons.contact, size: 16, color: fgSec),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            asignado == 'Sin asignar' ? asignado : 'Responsable: $asignado',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: fg,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
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
      final iconData =
          esManualSource(task)
              ? FluentIcons.page_list
              : FluentIcons.bullseye_target;
      return material.Card(
        elevation: 4,
        color: material.Colors.transparent,
        shadowColor: stroke.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: stroke.withValues(alpha: 0.55), width: 1.4),
        ),
        clipBehavior: Clip.antiAlias,
        // No usar Row+stretch aquí: en Wrap/SingleChildScrollView la altura es ∞ y falla el layout.
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
                padding: const EdgeInsets.fromLTRB(12, 12, 10, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (onReorderByDelta != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(FluentIcons.sort_up, size: 15),
                              onPressed:
                                  idx > 0
                                      ? () => onReorderByDelta!(idx, -1)
                                      : null,
                            ),
                            IconButton(
                              icon: const Icon(FluentIcons.sort_down, size: 15),
                              onPressed:
                                  idx < n - 1
                                      ? () => onReorderByDelta!(idx, 1)
                                      : null,
                            ),
                          ],
                        ),
                      ),
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: stroke.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(iconData, color: stroke, size: 28),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  titulo,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color: fg,
                                    height: 1.15,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              if (criticaTarjeta) ...[
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
                                const SizedBox(width: 6),
                              ],
                              _pill(context, _pillEstado(), stroke),
                            ],
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
                          const SizedBox(height: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: material.LinearProgressIndicator(
                              value: (p / 100).clamp(0.0, 1.0),
                              minHeight: 10,
                              color: barColor,
                              backgroundColor:
                                  isDark
                                      ? const material.Color(0xFF1E1E22)
                                      : const material.Color(0xFFE0E0E0),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            cancelada
                                ? 'Progreso: $p% (Cancelada)'
                                : 'Progreso: $p%',
                            style: TextStyle(
                              fontSize: 12,
                              color: fgSec,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (descCard.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              descCard,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: fgSec,
                                height: 1.25,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    presupuestoBlock,
                    const SizedBox(height: 10),
                    actionWrap,
                    const SizedBox(height: 8),
                    checklistTile,
                    if (bitacoraHistorial != null) ...[
                      const SizedBox(height: 6),
                      bitacoraHistorial,
                    ],
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: footerRow,
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
                                Text(
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
                          _pill(context, _pillEstado(), stroke),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.center,
                        child: presupuestoBlock,
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
                      if (descCard.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          descCard,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: fgSec,
                            height: 1.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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
                      actionWrap,
                      const SizedBox(height: 8),
                      checklistTile,
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
  }) {
    final byGroup = <String, List<Map<String, dynamic>>>{};
    for (final c in checks) {
      final g = grupoDeCheck(c);
      byGroup.putIfAbsent(g, () => []).add(c);
    }
    final keys = byGroup.keys.toList()..sort(compareGrupoChecklist);
    final out = <Widget>[];
    final headerBg = isDark ? const Color(0xFF38383F) : const Color(0xFFE4E7EF);
    for (var gi = 0; gi < keys.length; gi++) {
      final g = keys[gi];
      final list = byGroup[g]!;
      final headerText = tituloEncabezadoGrupoChecklist(g);

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
      final headerText = tituloEncabezadoGrupoChecklist(gtRaw);

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
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: Text(
            widget.title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
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
              _opt(3, '3 — Normal', const material.Color(0xFF2979FF)),
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
