import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:shared_preferences/shared_preferences.dart'; // === TAREA 2: Para rastreo de usuario ===
import 'dart:io';

import '../services/api_client.dart';

part '../controllers/bom_manager_controller.dart';

class BOMManagerScreen extends StatefulWidget {
  final int? idCliente;
  final String? clientName;
  // v60.0: nuevos parámetros de ingeniería maestra
  final int? idVersion;
  final String? versionName;
  final String? tractoName;
  final int? targetRevisionId;

  const BOMManagerScreen({
    Key? key,
    this.idCliente,
    this.clientName,
    this.idVersion,
    this.versionName,
    this.tractoName,
    this.targetRevisionId,
  }) : super(key: key);

  @override
  _BOMManagerScreenState createState() => _BOMManagerScreenState();
}

class _BOMManagerScreenState extends State<BOMManagerScreen> with BomManagerControllerMixin {
  CommandBarButton get _ecrCommandBarItem {
    final bool hasBorrador = _revisiones.any(
      (r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE',
    );
    final bool hasAprobada =
        _revisiones.any((r) => r['estado'] == 'Aprobada');

    if (_revisiones.isEmpty) {
      return CommandBarButton(
        icon: Icon(FluentIcons.add, color: _accentColor),
        label: const Text('Crear Ingeniería (Rev 0)'),
        onPressed: () => _addRevision(''),
      );
    }
    if (hasBorrador) {
      return CommandBarButton(
        icon: const Icon(FluentIcons.edit, color: Color(0xFFBDBDBD)),
        label: const Text('Edición en curso...'),
        onPressed: null,
      );
    }
    if (hasAprobada) {
      return CommandBarButton(
        icon: Icon(FluentIcons.build_definition, color: _accentColor),
        label: const Text('Iniciar Cambio ECR'),
        onPressed: () {
          if (!_esAprobada) {
            final approved = _revisiones.firstWhere(
              (r) => r['estado'] == 'Aprobada',
              orElse: () => null,
            );
            if (approved != null) {
              setState(() {
                _selectedRevision = approved;
                _arbol            = [];
                _selectedEnsamble = null;
                _vins             = [];
                _bomPlana         = [];
              });
              _fetchArbol();
              _fetchVINs();
            }
          }
          _showBranchingDialog();
        },
      );
    }
    // Solo OBSOLETO: permitir crear nueva base
    return CommandBarButton(
      icon: Icon(FluentIcons.add, color: _accentColor),
      label: const Text('Crear Ingeniería (Rev 0)'),
      onPressed: () => _addRevision(''),
    );
  }

  @override
  void initState() {
    super.initState();
    _fetchRevisiones();
  }

  List<TreeViewItem> _buildTreeItems() {
    final bool isAprobada = !_esEditable;

    return _arbol.map((est) {
      final List ensamblesList = est['ensambles'] as List;
      final bool hasChildren = ensamblesList.isNotEmpty;

      return TreeViewItem(
        expanded: hasChildren,
        content: Row(
          children: [
            Expanded(
              child: Text(
                est['nombre'],
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isAprobada) ...[
              IconButton(
                icon: const Icon(FluentIcons.add),
                onPressed:
                    () => _showAddDialog(
                      "Nuevo Ensamble para ${est['nombre']}",
                      (nombre) {
                        _addEnsamble(est['id'], nombre);
                      },
                    ),
              ),
              IconButton(
                icon: const Icon(FluentIcons.delete),
                onPressed:
                    () => _confirmDelete(
                      "¿Seguro de eliminar la estación '${est['nombre']}' y todo su contenido?",
                      () {
                        _deleteEstacion(est['id']);
                      },
                    ),
              ),
            ],
          ],
        ),
        children:
            ensamblesList.map((ens) {
              final isSelected =
                  _selectedEnsamble != null &&
                  _selectedEnsamble['id'] == ens['id'];
              return TreeViewItem(
                content: GestureDetector(
                  onTap: () {
                    setState(() => _selectedEnsamble = ens);
                  },
                  child: Container(
                    color:
                        isSelected
                            ? Colors.blue.withOpacity(0.2)
                            : Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            "${ens['nombre']}",
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!isAprobada)
                          IconButton(
                            icon: const Icon(FluentIcons.delete),
                            onPressed:
                                () => _confirmDelete(
                                  "¿Seguro de eliminar el ensamble '${ens['nombre']}' y sus piezas?",
                                  () {
                                    _deleteEnsamble(ens['id']);
                                  },
                                ),
                          ),
                      ],
                    ),
                  ),
                ),
                value: ens,
              );
            }).toList(),
      );
    }).toList();
  }

  Widget _buildPiezasTable() {
    if (_selectedRevision == null) {
      return const Center(child: Text("Selecciona una revisión primero."));
    }
    if (_selectedEnsamble == null) {
      return const Center(
        child: Text("Selecciona un ensamble para ver sus piezas."),
      );
    }

    // Snapshot inmutable para evitar RangeError si el estado cambia mid-frame
    final List<dynamic> piezas = List<dynamic>.from(
      _selectedEnsamble['piezas'] ?? [],
    );
    final bool isAprobada = !_esEditable;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── Encabezado del ensamble ───
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                "Piezas: ${_selectedEnsamble['nombre']}",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isAprobada)
              FilledButton(
                onPressed: _showAddPiezaDialog,
                child: const Text("Agregar Pieza"),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // ─── Header de columnas ───
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 12.0),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  "Código",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  "Descripción Oficial",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Cant.",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  "Procesos",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Simetría",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Acciones",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // ─── Lista de piezas ─── Expanded recibe constraints del Column padre
        Expanded(
          child:
              piezas.isEmpty
                  ? Center(
                    child: Text(
                      "No hay piezas en este ensamble.",
                      style: TextStyle(
                        color:
                            (FluentTheme.of(
                                  context,
                                ).typography.body?.color?.withOpacity(0.5) ??
                                Colors.grey),
                      ),
                    ),
                  )
                  : ListView.builder(
                    itemCount: piezas.length,
                    itemBuilder: (context, index) {
                      // Guardia: nunca acceder fuera de rango
                      if (index >= piezas.length)
                        return const SizedBox.shrink();
                      final pieza = piezas[index];

                      final List<String> procesos = [];
                      for (final key in [
                        'proceso_primario',
                        'proceso_1',
                        'proceso_2',
                        'proceso_3',
                      ]) {
                        final v = pieza[key]?.toString() ?? '';
                        if (v.isNotEmpty) procesos.add(v);
                      }
                      final strProcesos = procesos.join(', ');
                      final strLink = pieza['link_drive']?.toString() ?? '';
                      final hasLink = strLink.isNotEmpty && strLink != 'N/A';
                      final descripcion =
                          pieza['descripcion']?.toString() ?? '';

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 3.0,
                          horizontal: 12.0,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color:
                                  FluentTheme.of(
                                    context,
                                  ).scaffoldBackgroundColor,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                pieza['codigo']?.toString() ?? '',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Tooltip(
                                message: descripcion,
                                child: Text(
                                  descripcion,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Row(
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 80,
                                    ),
                                    child: TextBox(
                                      controller: TextEditingController(
                                        text:
                                            pieza['cantidad']?.toString() ??
                                            '0',
                                      ),
                                      keyboardType: TextInputType.number,
                                      textInputAction: TextInputAction.done,
                                      enabled: !isAprobada,
                                      placeholder: "Cant.",
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                      onSubmitted: (value) {
                                        final cant = double.tryParse(value);
                                        if (cant != null && cant > 0) {
                                          _updateCantidadPieza(
                                            pieza['id_estructura'],
                                            cant,
                                          );
                                        } else {
                                          _showError(
                                            "Cantidad inválida o igual a 0",
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                strProcesos,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(
                                pieza['simetria']?.toString() ?? '',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasLink)
                                    Tooltip(
                                      message: "Abrir Plano",
                                      child: IconButton(
                                        icon: Icon(
                                          FluentIcons.link,
                                          color: Colors.blue,
                                          size: 14,
                                        ),
                                        onPressed: () async {
                                          final uri = Uri.parse(strLink);
                                          if (await canLaunchUrl(uri)) {
                                            await launchUrl(uri);
                                          }
                                          if (!mounted) return;
                                        },
                                      ),
                                    ),
                                  if (!isAprobada)
                                    IconButton(
                                      icon: Icon(
                                        FluentIcons.delete,
                                        color: Colors.red,
                                        size: 14,
                                      ),
                                      onPressed:
                                          () => _confirmDelete(
                                            "¿Seguro de quitar la pieza ${pieza['codigo']}?",
                                            () => _deletePieza(pieza['id']),
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  // === VISTA PLANA ESTILO EXCEL ===
  Widget _buildVistaPlanaExcel() {
    final bool isDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : Colors.black;
    final Color rowEven =
        isDark ? const Color(0xFF242424) : Colors.white;
    final Color rowOdd =
        isDark ? const Color(0xFF2E2E2E) : const Color(0xFFF3F6FA);
    final Color hdBg = _accentColor;
    final Color borderColor =
        isDark ? const Color(0xFF3C3C3C) : const Color(0xFFDDE1E6);
    final Color lvl1Color = _accentColor;
    final Color lvl2Color =
        isDark ? const Color(0xFF90CAF9) : const Color(0xFF0D47A1);

    const double wNivel = 160.0;
    const double wCodigo = 180.0;
    const double wDesc = 380.0;
    const double wCant = 80.0;
    const double wMat = 140.0;
    const double wMedida = 65.0; // Largo, Ancho, Espesor
    const double wProceso = 85.0; // P. Primario, 1, 2, 3
    const double wSimetria = 80.0;
    const double totalWidth = wNivel + wCodigo + wDesc + wCant + wMat + (wMedida * 3) + (wProceso * 4) + wSimetria;

    Widget headerCell(String label, double w) {
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: hdBg,
          border: Border(
            right: BorderSide(
              color: Colors.white.withOpacity(0.25),
              width: 0.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 11,
            letterSpacing: 0.4,
          ),
        ),
      );
    }

    Widget dataCell(
      String text,
      double w, {
      bool isNumber = false,
      Color? colorOverride,
      FontWeight fontWeight = FontWeight.normal,
      bool tooltip = false,
    }) {
      final txt = Text(
        text,
        style: TextStyle(
          color: colorOverride ?? textColor,
          fontSize: 12,
          fontWeight: fontWeight,
        ),
        textAlign: isNumber ? TextAlign.center : TextAlign.start,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: borderColor, width: 0.5),
          ),
        ),
        child: tooltip && text.length > 35
            ? Tooltip(message: text, child: txt)
            : txt,
      );
    }

    if (_isLoading && _bomPlana.isEmpty) {
      return const Center(child: ProgressRing());
    }

    if (_bomPlana.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.table, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              _selectedRevision == null
                  ? "Selecciona una revisión para ver la Vista Plana."
                  : "No hay datos para mostrar en esta revisión.",
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final int totalPiezas =
        _bomPlana.where((r) => (r['nivel'] as num).toInt() == 3).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── Título compacto + botón auditoría ───
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Row(
            children: [
              Icon(FluentIcons.table, size: 14, color: _accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Vista Plana — Rev. ${_selectedRevision?['numero_revision'] ?? '-'}"
                  "  ·  $totalPiezas piezas",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: textColor,
                  ),
                ),
              ),
              Tooltip(
                message: "Verifica si existen planos DXF/PDF para cada pieza",
                child: Button(
                  onPressed: _isLoading ? null : _buscarPlanos,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.document_search,
                          size: 13, color: _accentColor),
                      const SizedBox(width: 5),
                      const Text("Auditar Planos",
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // ─── Tabla con doble scroll ───
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header fijo
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: borderColor, width: 1.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        headerCell("Estación", wNivel),
                        headerCell("Código", wCodigo),
                        headerCell("Descripción", wDesc),
                        headerCell("Material", wMat),
                        headerCell("Cantidad", wCant),
                        headerCell("Largo", wMedida),
                        headerCell("Ancho", wMedida),
                        headerCell("Espesor", wMedida),
                        headerCell("Proc. P", wProceso),
                        headerCell("Proc. 1", wProceso),
                        headerCell("Proc. 2", wProceso),
                        headerCell("Proc. 3", wProceso),
                        headerCell("Tiene DXF", wSimetria),
                      ],
                    ),
                  ),
                  // Filas virtualizadas
                  Expanded(
                    child: ListView.builder(
                      itemCount: _bomPlana.length,
                      itemBuilder: (context, index) {
                        final row = _bomPlana[index];
                        final int nivel = (row['nivel'] as num).toInt();
                        final bool isOdd = index.isOdd;

                        Color? rowTextOverride;
                        FontWeight fw = FontWeight.normal;
                        String nivelLabel;

                        if (nivel == 1) {
                          rowTextOverride = lvl1Color;
                          fw = FontWeight.bold;
                          nivelLabel = "▶ EST";
                        } else if (nivel == 2) {
                          rowTextOverride = lvl2Color;
                          fw = FontWeight.w600;
                          nivelLabel = "  ▸ ENS";
                        } else {
                          // Tarea 5: Mostrar Ensamble Padre o PIEZA
                          final padre = row['nombre_ensamble']?.toString() ?? "PIEZA";
                          nivelLabel = "      " + (padre.length > 20 ? padre.substring(0, 20) : padre);
                        }

                        final cantStr = row['cantidad'] != null
                            ? (row['cantidad'] as num)
                                .toStringAsFixed(2)
                                .replaceAll(RegExp(r'\.?0+$'), '')
                            : '';

                        return Container(
                          decoration: BoxDecoration(
                            color: isOdd ? rowOdd : rowEven,
                            border: Border(
                              bottom: BorderSide(
                                color: borderColor,
                                width: 0.5,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              dataCell(
                                nivelLabel,
                                wNivel,
                                isNumber: true,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(row['codigo_pieza']?.toString() ?? '', wCodigo, colorOverride: rowTextOverride, fontWeight: fw),
                              dataCell(row['descripcion']?.toString() ?? '', wDesc, tooltip: true),
                              dataCell(row['material']?.toString() ?? '', wMat, tooltip: true),
                              nivel == 3
                                  ? Container(
                                      width: wCant,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(border: Border(right: BorderSide(color: borderColor, width: 0.5))),
                                      child: TextBox(
                                        controller: TextEditingController(text: cantStr),
                                        keyboardType: TextInputType.number,
                                        enabled: _esEditable,
                                        textAlign: TextAlign.center,
                                        onSubmitted: (value) async {
                                          final cant = double.tryParse(value);
                                          if (cant != null && cant > 0) {
                                            final idEst = row['id_estructura'];
                                            if (idEst != null) {
                                              await _updateCantidadPieza((idEst as num).toInt(), cant);
                                              if (!mounted) return;
                                            } else { _showError("Sin id_estructura"); }
                                          } else { _showError("Cantidad inválida"); }
                                        },
                                      ),
                                    )
                                  : dataCell(cantStr, wCant, isNumber: true),
                              dataCell(row['largo_cad']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['ancho_cad']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['espesor_cad']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['proceso_primario']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_1']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_2']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_3']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['tiene_dxf']?.toString() ?? '', wSimetria, tooltip: true),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // === v60.0: HORIZONTAL STEPPER DE REVISIONES ===
  Widget _buildRevisionStepper() {
    if (_revisiones.isEmpty) {
      return const Text("Sin revisiones", style: TextStyle(color: Colors.grey));
    }
    // Snapshot inmutable: evita RangeError si _revisiones cambia mid-frame
    final List<dynamic> snap = List<dynamic>.from(_revisiones);
    if (snap.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(snap.length * 2 - 1, (i) {
          if (i.isOdd) {
            return Container(
              width: 24,
              height: 2,
              color: Colors.grey.withOpacity(0.4),
            );
          }
          final idx = i ~/ 2;
          if (idx >= snap.length) return const SizedBox.shrink();
          final rev = snap[idx];
          final isSelected =
              _selectedRevision != null &&
              _selectedRevision['id_revision'] == rev['id_revision'];
          final isAprobada = rev['estado'] == 'Aprobada';
          final isObsoleta = rev['estado'] == 'OBSOLETO';
          final stepColor = isAprobada
              ? const Color(0xFF2E7D32)   // verde
              : isObsoleta
                  ? const Color(0xFF9E9E9E)  // gris
                  : const Color(0xFFF9A825); // amarillo (Borrador)

          return Tooltip(
            message:
                "Rev ${rev['numero_revision']} - ${rev['estado']} (click para seleccionar)",
            child: GestureDetector(
              onTap: () {
                // setState atómico: revisión + limpieza en UN solo frame.
                // Así _esEditable/_esAprobada se recalculan con el estado
                // correcto antes del primer rebuild, habilitando/deshabilitando
                // los TextBox y botones instantáneamente.
                setState(() {
                  _selectedRevision = rev;
                  _arbol            = [];
                  _selectedEnsamble = null;
                  _vins             = [];
                  _bomPlana         = [];
                });
                _fetchArbol();
                _fetchVINs();
                if (_vistaPlana) _fetchBomPlana();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? stepColor : stepColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: stepColor,
                    width: isSelected ? 2.5 : 1,
                  ),
                  boxShadow:
                      isSelected
                          ? [
                            BoxShadow(
                              color: stepColor.withOpacity(0.4),
                              blurRadius: 6,
                            ),
                          ]
                          : [],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAprobada
                          ? FluentIcons.lock
                          : isObsoleta
                              ? FluentIcons.blocked
                              : FluentIcons.edit,
                      size: 12,
                      color: isSelected ? Colors.white : stepColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "Rev ${rev['numero_revision']}",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.white : stepColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        leading: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: IconButton(
            icon: const Icon(FluentIcons.back),
            onPressed: () {
              if (Navigator.canPop(context)) Navigator.pop(context, true);
            },
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Gestor de Listas (BOM)'),
            if (_clientesDeRevision(_selectedRevision).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.people,
                      size: 11,
                      color: Colors.blue.withOpacity(0.65),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Aplica para: ${_clientesDeRevision(_selectedRevision)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Colors.blue.withOpacity(0.75),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      // LayoutBuilder garantiza constraints reales antes del Column
      content: LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth,
            height:
                constraints.maxHeight.isInfinite ? 600 : constraints.maxHeight,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ─── Banner: ingeniería compartida entre múltiples clientes ───
                  Builder(builder: (context) {
                    final clientes = _clientesDeRevision(_selectedRevision);
                    final isShared = clientes.isNotEmpty &&
                        clientes != 'Ingeniería Base (Sin clientes)';
                    if (!isShared) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: InfoBar(
                        title: const Text('Ingeniería Compartida'),
                        content: Text(
                          '⚠️ Ingeniería compartida por: $clientes. '
                          'Cambios afectan a todos los VINs vinculados.',
                        ),
                        severity: InfoBarSeverity.warning,
                      ),
                    );
                  }),
                  // ─── Barra superior: Stepper + CommandBar ───────────────
                  Container(
                    decoration: BoxDecoration(
                      color: _accentColor.withOpacity(0.06),
                      border: Border(
                        bottom: BorderSide(
                          color: _accentColor.withOpacity(0.2),
                          width: 1.5,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 6.0,
                            ),
                            child: _buildRevisionStepper(),
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 24,
                          color: Colors.grey.withOpacity(0.2),
                        ),
                        // ── Semáforo de Estado ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Tooltip(
                            message: _esAprobada 
                                ? 'Revisión Aprobada - Sólo Lectura' 
                                : _esObsoleta 
                                    ? 'Archivo Histórico - Sólo Lectura' 
                                    : 'Borrador - Edición Activa',
                            child: Icon(
                              FluentIcons.circle_fill, 
                              size: 14, 
                              color: _esAprobada 
                                  ? const Color(0xFF2E7D32) 
                                  : _esObsoleta 
                                      ? const Color(0xFF9E9E9E) 
                                      : const Color(0xFFF9A825)
                            ),
                          ),
                        ),
                        Expanded(
                          child: CommandBar(
                            // Incluir _esEditable y si hay revisión: el número de primaryItems
                            // cambia al aprobar/pasar a solo lectura. Sin esto, fluent_ui 4.11.x
                            // conserva _dynamicallyHiddenPrimaryItems con índices viejos y lanza
                            // RangeError en allSecondaryItems (índice fuera de rango).
                            key: ValueKey(
                              'cmd_${_selectedRevision?['id_revision']}_'
                              'e${_esEditable}_'
                              'del${_selectedRevision != null}',
                            ),
                            overflowBehavior:
                                CommandBarOverflowBehavior.dynamicOverflow,
                            primaryItems: [
                              // ── Botón ECR inteligente ──────────────────────
                              _ecrCommandBarItem,

                              // ── 💾 Guardar Cambios (solo Borrador) ─────────
                              if (_esEditable)
                                CommandBarButton(
                                  icon: Icon(
                                    FluentIcons.save,
                                    color: _hasPendingChanges
                                        ? Colors.orange
                                        : Colors.grey,
                                  ),
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _hasPendingChanges
                                            ? 'Cambios sin guardar'
                                            : 'Actualizado',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _hasPendingChanges
                                              ? Colors.orange
                                              : Colors.grey,
                                          fontWeight: _hasPendingChanges
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      if (_hasPendingChanges) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            color: Colors.orange,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  onPressed: _hasPendingChanges
                                      ? () => _vistaPlana
                                          ? _fetchBomPlana()
                                          : _fetchArbol()
                                      : null,
                                ),
                              if (_esEditable)
                                CommandBarButton(
                                  icon: Icon(FluentIcons.lock,
                                      color: Colors.green),
                                  label: const Text("Aprobar"),
                                  onPressed: _showAprobarConfirmDialog,
                                ),
                              // ── Eliminar: siempre visible, admin bypass si no es borrador ──
                              if (_selectedRevision != null)
                                CommandBarButton(
                                  icon: Icon(FluentIcons.delete,
                                      color: _esEditable ? const Color(0xFFF57C00) : const Color(0xFFBDBDBD)),
                                  label: const Text("Eliminar"),
                                  onPressed: _esEditable 
                                      ? _checkAndShowDeleteDialog 
                                      : _showAdminDeleteDialog,
                                ),
                              CommandBarButton(
                                icon: Icon(
                                  _vistaPlana
                                      ? FluentIcons.check_list
                                      : FluentIcons.table,
                                  color:
                                      _vistaPlana
                                          ? _accentColor
                                          : const Color(0xFF757575),
                                ),
                                label: Text(
                                  _vistaPlana ? "Vista Árbol" : "Vista Plana",
                                ),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : () {
                                          final entering = !_vistaPlana;
                                          setState(
                                            () => _vistaPlana = entering,
                                          );
                                          if (entering) _fetchBomPlana();
                                        },
                              ),
                            ],
                            secondaryItems: [
                              CommandBarButton(
                                icon: Icon(
                                  FluentIcons.excel_document,
                                  color: Colors.green,
                                ),
                                label: const Text("Exportar BOM"),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : _exportarExcel,
                              ),
                              CommandBarButton(
                                icon: Icon(FluentIcons.car, color: Colors.blue),
                                label: Tooltip(
                                  message: "Administra las unidades físicas ligadas a esta revisión",
                                  child: const Text("Gestionar VINs"),
                                ),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : _showVINManagementDialog,
                              ),
                              const CommandBarSeparator(),
                              CommandBarButton(
                                icon: const Icon(FluentIcons.download),
                                label: const Text("Importar Excel"),
                                onPressed: (_selectedRevision == null ||
                                        !_esEditable)
                                    ? null
                                    : _importarExcel,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isLoading) const ProgressBar(),

                  const SizedBox(height: 8),
                  // ─── ZONA PRINCIPAL: ocupa todo el espacio restante ─────
                  Expanded(
                    child: _vistaPlana
                        ? Card(
                            padding: const EdgeInsets.all(12),
                            child: _buildVistaPlanaExcel(),
                          )
                        : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Panel izquierdo: TreeView de ensambles
                        SizedBox(
                          width: 280,
                          child: Card(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            "ENSAMBLES",
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                          if (_esEditable)
                                            Tooltip(
                                              message: "Agregar Estación",
                                              child: IconButton(
                                                icon: const Icon(
                                                  FluentIcons.add,
                                                  size: 14,
                                                ),
                                                onPressed: () =>
                                                    _showAddDialog(
                                                  "Nueva Estación",
                                                  _addEstacion,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const Divider(),
                                      Expanded(
                                        child: _arbol.isEmpty
                                            ? Center(
                                                child: Text(
                                                  "Sin estaciones",
                                                  style: TextStyle(
                                                    color: (FluentTheme.of(
                                                                    context)
                                                                .typography
                                                                .body
                                                                ?.color
                                                                ?.withOpacity(
                                                                    0.5) ??
                                                            Colors.grey),
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              )
                                            : TreeView(
                                                items: _buildTreeItems(),
                                                selectionMode:
                                                    TreeViewSelectionMode
                                                        .single,
                                                onItemInvoked:
                                                    (item, reason) async {},
                                              ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Panel derecho: tabla de piezas — Expanded recibe
                        // constraints exactos del Row padre
                        Expanded(
                          child: Card(
                            padding: const EdgeInsets.all(12),
                            child:
                                _isLoading && _selectedEnsamble == null
                                    ? const Center(child: ProgressRing())
                                    : _buildPiezasTable(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}


// ════════════════════════════════════════════════════════════════════════════
// _DiffAuditorDialog — Auditor de Cambios estilo Git/Cursor
// Muestra el diff de la revisión actual vs la anterior antes de aprobar.
// Tabla color-codificada: Verde=nuevo  Rojo=eliminado  Naranja=modificado
// ════════════════════════════════════════════════════════════════════════════

class _DiffAuditorDialog extends StatefulWidget {
  final int          idRevision;
  final String       revNum;
  final Color        accentColor;
  final VoidCallback onConfirm;

  const _DiffAuditorDialog({
    required this.idRevision,
    required this.revNum,
    required this.accentColor,
    required this.onConfirm,
  });

  @override
  State<_DiffAuditorDialog> createState() => _DiffAuditorDialogState();
}

class _DiffAuditorDialogState extends State<_DiffAuditorDialog> {
  bool    _loading     = true;
  String? _error;
  List<_DiffRow> _rows = [];
  int _cntNuevos       = 0;
  int _cntEliminados   = 0;
  int _cntModificados  = 0;

  @override
  void initState() {
    super.initState();
    _loadDiff();
  }

  Future<void> _loadDiff() async {
    try {
      final respDelta = await ApiClient.getUnvalidated(
        '/api/bom/delta/${widget.idRevision}',
      );
      if (!mounted) return;
      if (respDelta.statusCode != 200) {
        setState(() {
          _error   = 'Error en delta: ${respDelta.statusCode}';
          _loading = false;
        });
        return;
      }
      final delta = respDelta.decodeJson() as Map<String, dynamic>;

      if (delta['tiene_anterior'] != true) {
        setState(() { _rows = []; _loading = false; });
        return;
      }

      final List<String> nuevos =
          List<String>.from(delta['codigos_nuevos']     as List? ?? []);
      final List<String> eliminados =
          List<String>.from(delta['codigos_eliminados'] as List? ?? []);
      final Map<String, dynamic> modificados =
          Map<String, dynamic>.from(delta['modificados'] as Map? ?? {});

      final respPlana = await ApiClient.getUnvalidated(
        '/api/bom/plana/${widget.idRevision}',
      );
      if (!mounted) return;
      final Map<String, String> descMap = {};
      final Map<String, double> cantMap = {};
      if (respPlana.statusCode == 200) {
        final plana = respPlana.decodeJson() as List<dynamic>;
        for (final row in plana) {
          if ((row['nivel'] as num).toInt() == 3) {
            final cod    = row['codigo_pieza']?.toString() ?? '';
            descMap[cod] = row['descripcion']?.toString() ?? '';
            cantMap[cod] = double.tryParse(row['cantidad']?.toString() ?? '') ?? 0.0;
          }
        }
      }

      final List<_DiffRow> rows = [];

      for (final cod in nuevos) {
        rows.add(_DiffRow(
          tipo:         _DiffTipo.agregado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: '',
          cantActual:   _fmt(cantMap[cod] ?? 0.0),
        ));
      }
      for (final cod in eliminados) {
        final prev = (modificados[cod]?['prev_qty'] as num?)?.toDouble() ?? 0.0;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.eliminado,
          codigo:       cod,
          descripcion:  '',
          cantAnterior: _fmt(prev),
          cantActual:   '--',
        ));
      }
      for (final entry in modificados.entries) {
        final cod  = entry.key;
        final prev = double.tryParse(entry.value['prev_qty']?.toString() ?? '') ?? 0.0;
        final curr = double.tryParse(entry.value['curr_qty']?.toString() ?? '') ?? 0.0;
        if (prev == curr) continue;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.modificado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: _fmt(prev),
          cantActual:   _fmt(curr),
        ));
      }

      rows.sort((a, b) => a.tipo.index.compareTo(b.tipo.index));

      setState(() {
        _rows           = rows;
        _cntNuevos      = rows.where((r) => r.tipo == _DiffTipo.agregado).length;
        _cntEliminados  = rows.where((r) => r.tipo == _DiffTipo.eliminado).length;
        _cntModificados = rows.where((r) => r.tipo == _DiffTipo.modificado).length;
        _loading        = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = 'Error: $e'; _loading = false; });
    }
  }

  String _fmt(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final Color bg  = isDark ? const Color(0xFF1E1E2A) : Colors.white;
    final Color tx  = isDark ? const Color(0xFFE8EAED) : const Color(0xFF1A1A2E);
    final Color bdr = isDark ? const Color(0xFF3A3A4A) : const Color(0xFFDDE3EA);

    const Color clrGreen    = Color(0xFF2E7D32);
    const Color clrGreenBg  = Color(0x182E7D32);
    const Color clrRed      = Color(0xFFC62828);
    const Color clrRedBg    = Color(0x18C62828);
    const Color clrOrange   = Color(0xFFE65100);
    const Color clrOrangeBg = Color(0x18E65100);

    const double wFlag  =   5.0;
    const double wCod   = 160.0;
    const double wDesc  = 450.0;
    const double wPrev  =  90.0;
    const double wCurr  =  90.0;
    const double totalW = wFlag + wCod + wDesc + wPrev + wCurr;

    Widget hCell(String label, double w, {TextAlign align = TextAlign.left}) {
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: widget.accentColor,
          border: Border(right: BorderSide(
              color: Colors.white.withOpacity(0.15), width: 0.5)),
        ),
        child: Text(label,
          style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.3),
          textAlign: align, overflow: TextOverflow.ellipsis),
      );
    }

    Widget dCell(String text, double w,
        {Color? fg, FontWeight fw = FontWeight.normal,
         bool mono = false, TextAlign align = TextAlign.left}) {
      final txt = Text(text,
        style: TextStyle(color: fg ?? tx, fontSize: 11, fontWeight: fw,
            fontFamily: mono ? 'monospace' : null),
        textAlign: align, overflow: TextOverflow.ellipsis, maxLines: 1);
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
            border: Border(right: BorderSide(color: bdr, width: 0.5))),
        child: text.length > 35 ? Tooltip(message: text, child: txt) : txt,
      );
    }

    Widget badge(String label, int count, Color color) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('$count $label',
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ]),
      );
    }

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth:  MediaQuery.of(context).size.width  * 0.95,
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      title: Row(children: [
        Icon(FluentIcons.compare, size: 18, color: widget.accentColor),
        const SizedBox(width: 8),
        Expanded(child: Text(
          'Auditor de Cambios — Rev. ${widget.revNum}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis)),
        if (!_loading && _error == null) ...[
          const SizedBox(width: 8),
          badge('Nuevas',      _cntNuevos,      clrGreen),
          const SizedBox(width: 6),
          badge('Eliminadas',  _cntEliminados,  clrRed),
          const SizedBox(width: 6),
          badge('Modificadas', _cntModificados, clrOrange),
        ],
      ]),
      content: _loading
          ? const Center(child: ProgressRing())
          : _error != null
              ? Center(child: Text(_error!,
                  style: TextStyle(color: Colors.red)))
              : _rows.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(FluentIcons.check_mark, size: 40, color: clrGreen),
                      const SizedBox(height: 12),
                      const Text('Sin diferencias detectadas.',
                          style: TextStyle(fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(
                        'La revisión ${widget.revNum} es idéntica a la anterior.',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]))
                  : Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: bdr),
                          borderRadius: BorderRadius.circular(6),
                          color: bg),
                      child: Column(children: [
                        Row(children: [
                          Container(width: wFlag, color: widget.accentColor),
                          hCell('Código',        wCod),
                          hCell('Descripción',   wDesc),
                          hCell('Rev. Anterior', wPrev, align: TextAlign.center),
                          hCell('Rev. Actual',   wCurr, align: TextAlign.center),
                        ]),
                        Expanded(child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: totalW,
                            child: ListView.builder(
                              itemCount: _rows.length,
                              itemBuilder: (ctx, i) {
                                final r = _rows[i];
                                Color rowBg, flagClr, codeFg, qtyFg;
                                String icon;
                                switch (r.tipo) {
                                  case _DiffTipo.agregado:
                                    rowBg = clrGreenBg; flagClr = clrGreen;
                                    codeFg = clrGreen; qtyFg = clrGreen; icon = '+';
                                  case _DiffTipo.eliminado:
                                    rowBg = clrRedBg; flagClr = clrRed;
                                    codeFg = clrRed; qtyFg = clrRed; icon = '-';
                                  case _DiffTipo.modificado:
                                    rowBg = isDark ? const Color(0xFF1E1000) : clrOrangeBg;
                                    flagClr = clrOrange; codeFg = clrOrange;
                                    qtyFg = clrOrange; icon = '*';
                                }
                                return Container(
                                  color: rowBg,
                                  child: Row(children: [
                                    Container(
                                      width: wFlag, color: flagClr,
                                      alignment: Alignment.center,
                                      child: Text(icon, style: const TextStyle(
                                          color: Colors.white, fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                    ),
                                    dCell(r.codigo, wCod,
                                        fg: codeFg, fw: FontWeight.w600, mono: true),
                                    dCell(r.descripcion, wDesc,
                                        fg: r.tipo == _DiffTipo.eliminado
                                            ? clrRed.withOpacity(0.8) : null),
                                    Container(
                                      width: wPrev,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(border: Border(
                                          right: BorderSide(color: bdr, width: 0.5))),
                                      child: Text(r.cantAnterior,
                                        style: TextStyle(
                                          fontSize: 12, fontWeight: FontWeight.w600,
                                          color: r.tipo == _DiffTipo.eliminado ? clrRed
                                              : r.tipo == _DiffTipo.modificado
                                                  ? clrOrange.withOpacity(0.7) : tx,
                                          decoration: r.tipo == _DiffTipo.modificado
                                              ? TextDecoration.lineThrough : null),
                                        textAlign: TextAlign.center),
                                    ),
                                    Container(
                                      width: wCurr,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      child: Text(r.cantActual,
                                        style: TextStyle(fontSize: 12,
                                            fontWeight: FontWeight.bold, color: qtyFg),
                                        textAlign: TextAlign.center),
                                    ),
                                  ]),
                                );
                              },
                            ),
                          ),
                        )),
                      ]),
                    ),
      actions: [
        Button(
          child: const Text('Cancelar'),
          onPressed: () => Navigator.pop(context),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text('Esta acción es irreversible.',
              style: TextStyle(fontSize: 11,
                  color: Colors.orange.withOpacity(0.9))),
        ),
        FilledButton(
          style: ButtonStyle(backgroundColor: WidgetStateProperty.all(clrGreen)),
          onPressed: widget.onConfirm,
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.check_mark, size: 13, color: Colors.white),
            SizedBox(width: 6),
            Text('Confirmar y Aprobar Revisión',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ]),
        ),
      ],
    );
  }
}

// ─── Modelos ──────────────────────────────────────────────────────────────────
enum _DiffTipo { eliminado, modificado, agregado }

class _DiffRow {
  final _DiffTipo tipo;
  final String    codigo;
  final String    descripcion;
  final String    cantAnterior;
  final String    cantActual;

  const _DiffRow({
    required this.tipo,
    required this.codigo,
    required this.descripcion,
    required this.cantAnterior,
    required this.cantActual,
  });
}
