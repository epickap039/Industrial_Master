import 'dart:io';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/conflict_dialog.dart';
import '../services/api_client.dart';
import '../services/arbitration_bridge.dart';
import '../services/notification_inbox_service.dart';
import '../theme/page_title_style.dart';
import '../theme/ui_tokens.dart';

class ArbitrationScreen extends StatefulWidget {
  const ArbitrationScreen({super.key});

  @override
  State<ArbitrationScreen> createState() => _ArbitrationScreenState();
}

class _ArbitrationScreenState extends State<ArbitrationScreen> {
  static const Set<String> _syncReadyStates = {'NUEVO', 'LISTO_EXCEL', 'LISTO_BD'};

  /// Mismas claves que [BomManagerControllerMixin] al abrir el flujo PLM desde BOM.
  static const String _prefBomBridgeExcelPath = 'bom_bridge_excel_path';
  static const String _prefBomBridgeFilterNuevos = 'bom_bridge_filter_nuevos';

  // Datos
  List<dynamic> _conflicts = [];
  int _totalProcessed = 0;
  bool _isLoading = false;

  // Filtros y Selección
  String _filterStatus = 'TODOS'; // TODOS, NUEVO, CONFLICTO
  String _searchQuery = '';
  final Set<String> _selectedUpdates = {};

  // UI Scroll / búsqueda
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  void _onArbitrationBridgeTick() {
    _consumeBomCatalogBridge();
  }

  @override
  void initState() {
    super.initState();
    ArbitrationBridge.consumeRequestTick.addListener(_onArbitrationBridgeTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeBomCatalogBridge();
    });
  }

  @override
  void dispose() {
    ArbitrationBridge.consumeRequestTick.removeListener(_onArbitrationBridgeTick);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  static String _pieceCode(dynamic item) =>
      (item['Codigo_Pieza'] ?? item['codigo'] ?? '').toString();

  /// Filtro por estado (Nuevos / Conflictos / Todos).
  List<dynamic> get _statusFiltered {
    if (_filterStatus == 'TODOS') return List<dynamic>.from(_conflicts);
    return _conflicts.where((c) => c['Estado'] == _filterStatus).toList();
  }

  /// Vista actual: estado + prefijo de código.
  List<dynamic> get _visibleList {
    final q = _searchQuery.trim().toUpperCase();
    var list = _statusFiltered;
    if (q.isNotEmpty) {
      list =
          list
              .where(
                (c) => _pieceCode(c).toUpperCase().contains(q),
              )
              .toList();
    }
    return list;
  }

  /// Hay al menos un conflicto marcado con checkbox.
  bool get _hasSelectedConflicts =>
      _selectedUpdates.any(
        (id) => _conflicts.any(
          (c) => c['Codigo_Pieza'] == id && c['Estado'] == 'CONFLICTO',
        ),
      );

  // ACCIONES MASIVAS
  void _selectAllVisible() {
    setState(() {
      final idsVisible =
          _visibleList.map((c) => c['Codigo_Pieza'] as String).toSet();
      // Si todos los visibles ya están seleccionados, deseleccionar
      if (idsVisible.every((id) => _selectedUpdates.contains(id))) {
        _selectedUpdates.removeWhere((id) => idsVisible.contains(id));
      } else {
        _selectedUpdates.addAll(idsVisible);
      }
    });
  }

  /// Procesa el Excel de catálogo (mismo endpoint que el selector manual).
  Future<void> _loadExcelFromBytes(
    Uint8List bytes,
    String filename, {
    bool defaultFilterNuevos = false,
  }) async {
    setState(() => _isLoading = true);
    try {
      final mf = ApiClient.multipartFromBytes(
        'file',
        bytes,
        filename: filename,
      );
      final data = await ApiClient.postMultipart(
        '/api/excel/procesar',
        files: {'file': mf},
      ) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        _conflicts = data['conflictos'];
        _totalProcessed = data['total_leidos'];
        _selectedUpdates.clear();
        _filterStatus = defaultFilterNuevos ? 'NUEVO' : 'TODOS';
        _searchQuery = '';
        _searchController.clear();
      });
    } catch (e) {
      if (mounted) _showError("Error de archivo: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _consumeBomCatalogBridge() async {
    if (kIsWeb) return;
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_prefBomBridgeExcelPath);
    final filterNuevos = prefs.getBool(_prefBomBridgeFilterNuevos) ?? false;
    if (path == null || path.isEmpty) return;

    await prefs.remove(_prefBomBridgeExcelPath);
    await prefs.remove(_prefBomBridgeFilterNuevos);

    try {
      final f = File(path);
      if (!await f.exists()) return;
      final bytes = await f.readAsBytes();
      final name = path.replaceAll(r'\', '/').split('/').last;
      await _loadExcelFromBytes(bytes, name, defaultFilterNuevos: filterNuevos);
    } catch (_) {
      /* silencioso: no bloquear la pantalla si el puente falla */
    }
  }

  // 1. CARGA DE ARCHIVO
  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      Uint8List? bytes = f.bytes;
      if (bytes == null && f.path != null && !kIsWeb) {
        bytes = await File(f.path!).readAsBytes();
      }
      if (bytes == null) {
        if (mounted) {
          _showError('No se pudieron leer los datos del archivo.');
        }
        return;
      }
      await _loadExcelFromBytes(bytes, f.name, defaultFilterNuevos: false);
    } catch (e) {
      if (mounted) _showError("Error de archivo: $e");
    }
  }

  // 2. SINCRONIZACIÓN
  Future<void> _syncSelected() async {
    // Diálogo de Advertencia (REGLA ANTI-CONST)
    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('⚠️ Atención: Carga a Base de Datos'),
        content: Text(
          'En este apartado se cargarán códigos y materiales directamente a la base de datos oficial. '
          'Por favor, verifica que los datos en tu archivo de Excel estén estructurados correctamente antes de continuar.'
        ),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            child: Text('Proceder'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final username = prefs.getString('username') ?? 'Admin_Arbitraje';

      // Preparar payload con origen de estado para el backend
      // Solo se envían estados listos, nunca CONFLICTO.
      final updatesToSend =
          _conflicts
              .where(
                (c) =>
                    _selectedUpdates.contains(c['Codigo_Pieza']) &&
                    _syncReadyStates.contains(c['Estado']),
              )
              .map(
                (c) => {
                  // MAPEO CRÍTICO PARA BACKEND (ERROR 422 FIX)
                  'Codigo_Pieza': c['Codigo_Pieza'],
                  'Descripcion': c['Excel_Data']['Descripcion_Excel'],
                  'Medida': c['Excel_Data']['Medida_Excel'],
                  'Material': c['Excel_Data']['Material_Excel'],
                  'Simetria': c['Excel_Data']['Simetria'] ?? "No",
                  'Proceso_Primario': c['Excel_Data']['Proceso_Primario'],
                  'Proceso_1': c['Excel_Data']['Proceso_1'],
                  'Proceso_2': c['Excel_Data']['Proceso_2'],
                  'Proceso_3': c['Excel_Data']['Proceso_3'],
                  'Link_Drive': c['Excel_Data']['Link_Drive'],
                  'Estado': c['Estado'],
                  // Meta-datos internos (no esquema)
                  'usuario': username,
                  'Modificado_Por': username, // AUDITORÍA DE USUARIO
                  '_Estado_Origen': c['Estado'],
                },
              )
              .toList();

      if (updatesToSend.isEmpty) return;

      final result = await ApiClient.post(
        '/api/excel/sincronizar',
        headers: {'X-Usuario': username},
        body: updatesToSend,
      ) as Map<String, dynamic>;

      if (!mounted) return;

      await showDialog(
        context: context,
        builder:
            (c) => ContentDialog(
              title: const Text("Sincronización Completada"),
              content: Text("Mensaje: ${result['message']}"),
              actions: [
                Button(
                  child: const Text("OK"),
                  onPressed: () => Navigator.pop(c),
                ),
              ],
            ),
      );

      if (!mounted) return;
      final nuevos = (result['nuevos_insertados'] is int)
          ? (result['nuevos_insertados'] as int)
          : int.tryParse('${result['nuevos_insertados'] ?? 0}') ?? 0;
      if (nuevos > 0) {
        await CmdInboxStore.instance.addSystemNotice(
          title: 'Importar archivos: nuevos codigos',
          body: 'Se agregaron $nuevos codigo(s) nuevos al catalogo maestro.',
          assignedUser: username,
        );
        if (mounted) {
          displayInfoBar(
            context,
            builder: (c, close) => InfoBar(
              title: const Text('Carga completada'),
              content: Text('Se registraron $nuevos código(s) nuevos en la base de datos.'),
              severity: InfoBarSeverity.success,
              onClose: close,
            ),
          );
        }
      }

      // Limpiar lista visualmente
      setState(() {
        _conflicts.removeWhere(
          (c) => _selectedUpdates.contains(c['Codigo_Pieza']),
        );
        _selectedUpdates.clear();
        if (_conflicts.isEmpty) _totalProcessed = 0;
      });
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _syncOnlyNew() async {
    final newIds =
        _conflicts
            .where((c) => c['Estado'] == 'NUEVO')
            .map((c) => c['Codigo_Pieza'] as String)
            .toSet();

    if (newIds.isEmpty) {
      _showSnack("No hay elementos NUEVOS para sincronizar");
      return;
    }

    // Reusa el flujo de sincronización actual; solo enviará NUEVO.
    setState(() {
      _selectedUpdates
        ..clear()
        ..addAll(newIds);
    });
    await _syncSelected();
  }

  void _keepDbForAllConflicts() {
    final conflictIds =
        _conflicts
            .where((c) => c['Estado'] == 'CONFLICTO')
            .map((c) => c['Codigo_Pieza'] as String)
            .toSet();

    if (conflictIds.isEmpty) return;

    setState(() {
      _conflicts.removeWhere((c) => conflictIds.contains(c['Codigo_Pieza']));
      _selectedUpdates.removeWhere((id) => conflictIds.contains(id));
      if (_conflicts.isEmpty) _totalProcessed = 0;
    });

    _showSnack(
      "Se mantuvo SQL para ${conflictIds.length} conflicto(s).",
    );
  }

  void _keepDbForSelectedConflicts() {
    final ids =
        _selectedUpdates
            .where(
              (id) => _conflicts.any(
                (c) =>
                    c['Codigo_Pieza'] == id && c['Estado'] == 'CONFLICTO',
              ),
            )
            .toSet();

    if (ids.isEmpty) return;

    setState(() {
      _conflicts.removeWhere((c) => ids.contains(c['Codigo_Pieza']));
      _selectedUpdates.removeWhere((id) => ids.contains(id));
      if (_conflicts.isEmpty) _totalProcessed = 0;
    });

    _showSnack(
      "Se mantuvo BD para ${ids.length} conflicto(s) seleccionado(s).",
    );
  }

  void _showError(String msg) {
    showDialog(
      context: context,
      builder:
          (c) => ContentDialog(
            title: const Text("Error"),
            content: Text(msg),
            actions: [
              Button(
                child: const Text("OK"),
                onPressed: () => Navigator.pop(c),
              ),
            ],
          ),
    );
  }

  void _showInfo(String title, String msg) {
    showDialog(
      context: context,
      builder:
          (c) => ContentDialog(
            title: Text(title),
            content: Text(msg),
            actions: [
              FilledButton(
                child: const Text("OK"),
                onPressed: () => Navigator.pop(c),
              ),
            ],
          ),
    );
  }

  /// Llama al endpoint que normaliza Material vacío → 'POR DEFINIR' en toda la BD.
  Future<void> _limpiarMaterialVacio() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (c) => ContentDialog(
            title: const Text('🧹 Limpiar Material vacío'),
            content: const Text(
              'Esto actualizará TODAS las piezas en la base de datos que tienen '
              'Material vacío o nulo, asignándoles "POR DEFINIR".\n\n'
              '¿Deseas continuar?',
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(c, false),
              ),
              FilledButton(
                child: const Text('Limpiar BD'),
                onPressed: () => Navigator.pop(c, true),
              ),
            ],
          ),
    );
    if (ok != true) return;

    setState(() => _isLoading = true);
    try {
      final res = await ApiClient.post(
        '/api/excel/limpiar_material',
        body: {},
      ) as Map<String, dynamic>;
      if (mounted) {
        _showInfo(
          '✅ Limpieza completada',
          res['mensaje'] ?? 'Operación exitosa.',
        );
      }
    } catch (e) {
      if (mounted) _showError('Error al limpiar: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 3. EDICIÓN Y RESOLUCIÓN (LÓGICA "RESOLVER Y DESAPARECER")
  void _showEditDialog(dynamic item) async {
    // Si es CONFLICTO, mostrar primero el diálogo de resolución
    if (item['Estado'] == 'CONFLICTO' && item['is_manual_edit'] != true) {
      final result = await showDialog(
        context: context,
        builder: (c) => ConflictResolutionDialog(item: item),
      );

      if (result == null) return; // Cancelado

      if (result is Map) {
        final action = result['action'];

        // OPCIÓN A: USAR EXCEL (SINCRONIZAR YA)
        if (action == 'SYNC_EXCEL') {
          // 1. Mostrar carga
          setState(() => _isLoading = true);

          // 2. Preparar ítem único para sync
          final itemToSync = {
            'Codigo_Pieza': item['Codigo_Pieza'],
            'Descripcion': result['data']['Descripcion_Excel'],
            'Medida': result['data']['Medida_Excel'],
            'Material': result['data']['Material_Excel'],
            'Simetria': result['data']['Simetria'] ?? "No",
            'Proceso_Primario': result['data']['Proceso_Primario'],
            'Proceso_1': result['data']['Proceso_1'],
            'Proceso_2': result['data']['Proceso_2'],
            'Proceso_3': result['data']['Proceso_3'],
            'Link_Drive': result['data']['Link_Drive'],
            'Estado': 'CONFLICTO', // Para que el backend sepa que es update
            'usuario': 'Arbitro Rapido',
            'Modificado_Por': 'Arbitro Rapido',
          };

          // 3. Llamar al backend
          try {
            await _syncSingleItem(itemToSync);

            // 4. Éxito: Desaparecer de la lista
            if (mounted) {
              setState(() {
                _conflicts.removeWhere(
                  (c) => c['Codigo_Pieza'] == item['Codigo_Pieza'],
                );
                _selectedUpdates.remove(item['Codigo_Pieza']);
                _isLoading = false;
              });
              _showSnack(
                "Resolución aplicada: ${item['Codigo_Pieza']} (Datos Excel)",
              );
            }
          } catch (e) {
            if (mounted) setState(() => _isLoading = false);
            _showError("Error al sincronizar: $e");
          }
          return;
        }

        // OPCIÓN B: MANTENER BD (IGNORAR Y DESAPARECER)
        if (action == 'KEEP_DB') {
          setState(() {
            _conflicts.removeWhere(
              (c) => c['Codigo_Pieza'] == item['Codigo_Pieza'],
            );
            _selectedUpdates.remove(item['Codigo_Pieza']);
          });
          _showSnack("Ignorado: ${item['Codigo_Pieza']} (Se mantiene BD)");
          return;
        }

        // OPCIÓN C: EDITAR MANUAL
        if (action == 'EDIT_MANUAL') {
          await Future.delayed(const Duration(milliseconds: 100));
          _showManualEdit(item); // Abre formulario
          return;
        }
      }
    }

    // Flujo normal o post-edición manual
    _showManualEdit(item);
  }

  // Helper para sync individual (reutiliza lógica si es posible, o crea nueva)
  Future<void> _syncSingleItem(Map<String, dynamic> itemPayload) async {
    await ApiClient.post(
      '/api/excel/sincronizar',
      headers: {'X-Usuario': 'Alejandro'},
      body: [itemPayload],
    );
  }

  void _showSnack(String msg) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: const Text('Éxito'),
          content: Text(msg),
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
          severity: InfoBarSeverity.success,
        );
      },
    );
  }

  void _showManualEdit(dynamic item) {
    // Inicializar controladores con datos existentes o vacíos
    final descCtrl = TextEditingController(
      text: item['Excel_Data']['Descripcion_Excel'],
    );
    final medidaCtrl = TextEditingController(
      text: item['Excel_Data']['Medida_Excel'],
    );
    final matCtrl = TextEditingController(
      text: item['Excel_Data']['Material_Excel'],
    );
    final simetriaCtrl = TextEditingController(
      text: item['Excel_Data']['Simetria'] ?? "No",
    );
    final procPrimCtrl = TextEditingController(
      text: item['Excel_Data']['Proceso_Primario'] ?? "Torneado",
    );
    final proc1Ctrl = TextEditingController(
      text: item['Excel_Data']['Proceso_1'],
    );
    final proc2Ctrl = TextEditingController(
      text: item['Excel_Data']['Proceso_2'],
    );
    final proc3Ctrl = TextEditingController(
      text: item['Excel_Data']['Proceso_3'],
    ); // Campo Nuevo
    final linkCtrl = TextEditingController(
      text: item['Excel_Data']['Link_Drive'],
    );

    showDialog(
      context: context,
      builder: (c) {
        final dlgTheme = FluentTheme.of(c);
        return ContentDialog(
            title: Text("Editar Item: ${item['Codigo_Pieza']}"),
            content: SizedBox(
              width: 400, // Ancho fijo para el diálogo
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InfoLabel(
                      label: "Descripción",
                      child: TextFormBox(controller: descCtrl, maxLines: 2),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InfoLabel(
                            label: "Medida",
                            child: TextFormBox(controller: medidaCtrl),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InfoLabel(
                            label: "Material",
                            child: TextFormBox(controller: matCtrl),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Divider(),
                    const SizedBox(height: 8),
                    Text(
                      "Procesos y Geometría",
                      style: dlgTheme.typography.bodyStrong,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InfoLabel(
                            label: "Simetría",
                            child: TextFormBox(controller: simetriaCtrl),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InfoLabel(
                            label: "Primario",
                            child: TextFormBox(controller: procPrimCtrl),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    InfoLabel(
                      label: "Proceso 1",
                      child: TextFormBox(controller: proc1Ctrl),
                    ),
                    const SizedBox(height: 4),
                    InfoLabel(
                      label: "Proceso 2",
                      child: TextFormBox(controller: proc2Ctrl),
                    ),
                    const SizedBox(height: 4),
                    InfoLabel(
                      label: "Proceso 3",
                      child: TextFormBox(controller: proc3Ctrl),
                    ),
                    const SizedBox(height: 8),
                    const Divider(),
                    const SizedBox(height: 8),
                    InfoLabel(
                      label: "Link Drive",
                      child: TextFormBox(controller: linkCtrl),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              Button(
                child: const Text("Cancelar"),
                onPressed: () => Navigator.pop(c),
              ),
              FilledButton(
                child: const Text("Guardar Cambios"),
                onPressed: () async {
                  // 1. Mostrar carga
                  setState(() => _isLoading = true);
                  Navigator.pop(c); // Cerrar diálogo

                  // 2. Preparar payload
                  final itemToSync = {
                    'Codigo_Pieza': item['Codigo_Pieza'],
                    'Descripcion': descCtrl.text,
                    'Medida': medidaCtrl.text,
                    'Material': matCtrl.text,
                    'Simetria': simetriaCtrl.text,
                    'Proceso_Primario': procPrimCtrl.text,
                    'Proceso_1': proc1Ctrl.text,
                    'Proceso_2': proc2Ctrl.text,
                    'Proceso_3': proc3Ctrl.text,
                    'Link_Drive': linkCtrl.text,
                    'Estado': 'CONFLICTO', // Forzar UPDATE
                    'usuario': 'Arbitro Manual',
                    'Modificado_Por': 'Arbitro Manual',
                  };

                  // 3. Sincronizar
                  try {
                    await _syncSingleItem(itemToSync);

                    if (mounted) {
                      setState(() {
                        _conflicts.removeWhere(
                          (c) => c['Codigo_Pieza'] == item['Codigo_Pieza'],
                        );
                        _selectedUpdates.remove(item['Codigo_Pieza']);
                        _isLoading = false;
                      });
                      _showSnack(
                        "Edición Manual aplicada: ${item['Codigo_Pieza']}",
                      );
                    }
                  } catch (e) {
                    if (mounted) setState(() => _isLoading = false);
                    _showError("Error al guardar edición manual: $e");
                  }
                },
              ),
            ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final palette = uiSurfacePaletteOf(context);

    // ESTADO VACIO
    if (_conflicts.isEmpty && _totalProcessed == 0 && !_isLoading) {
      return ScaffoldPage(
        padding: const EdgeInsets.only(top: 8),
        header: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          child: Text(
            'Importar Excel',
            style: pageTitleTextStyle(context).copyWith(
              color: theme.typography.title?.color,
            ),
          ),
        ),
        content: ColoredBox(
          color: palette.surfaceBase,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  FluentIcons.excel_document,
                  size: 60,
                  color: theme.accentColor,
                ),
                const SizedBox(height: 20),
                Text(
                  "Carga un BOM para comparar con SQL Server",
                  style: theme.typography.title?.copyWith(
                    color: pageTitleForegroundColor(theme),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 30),
                FilledButton(
                  onPressed: _pickFile,
                  child: const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: Text("Seleccionar Archivo .xlsx"),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final hasConflictRows = _conflicts.any((c) => c['Estado'] == 'CONFLICTO');
    final canSyncSelection = _selectedUpdates.any(
      (id) => _conflicts.any(
        (c) =>
            c['Codigo_Pieza'] == id &&
            _syncReadyStates.contains(c['Estado']),
      ),
    );

    // ESTADO CON DATOS — cabecera con Wrap (evita overflow roto del CommandBar)
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Importar Excel',
              style: pageTitleTextStyle(context).copyWith(
                color: theme.typography.title?.color,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 200,
                  child: TextBox(
                    controller: _searchController,
                    placeholder: 'Buscar código…',
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                Tooltip(
                  message:
                      'Resolución de conflictos: selecciona las piezas a corregir o usa las acciones masivas para agilizar la importación.',
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.info,
                      size: 15,
                      color: theme.resources.textFillColorSecondary,
                    ),
                    onPressed: () {},
                  ),
                ),
                Tooltip(
                  message:
                      'Muestra solo filas con estado Nuevo (aún no existen en la base de datos).',
                  child: ToggleSwitch(
                    checked: _filterStatus == 'NUEVO',
                    content: const Text('Nuevos'),
                    onChanged: (v) =>
                        setState(() => _filterStatus = v ? 'NUEVO' : 'TODOS'),
                  ),
                ),
                Tooltip(
                  message:
                      'Muestra solo filas donde Excel y la base de datos no coinciden.',
                  child: ToggleSwitch(
                    checked: _filterStatus == 'CONFLICTO',
                    content: const Text('Conflictos'),
                    onChanged: (v) => setState(
                      () => _filterStatus = v ? 'CONFLICTO' : 'TODOS',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      content: ColoredBox(
        color: palette.surfaceBase,
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(
                style: DividerThemeData(
                  thickness: 1,
                  decoration: BoxDecoration(
                    color: theme.resources.dividerStrokeColorDefault,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: theme.resources.dividerStrokeColorDefault,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 44,
                              child: Center(
                                child: Checkbox(
                                  checked:
                                      _selectedUpdates.isNotEmpty &&
                                      _visibleList.isNotEmpty &&
                                      _visibleList.every(
                                        (c) => _selectedUpdates.contains(
                                          c['Codigo_Pieza'],
                                        ),
                                      ),
                                  onChanged: (v) => _selectAllVisible(),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                "CÓDIGO",
                                style: theme.typography.bodyStrong,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          "VALOR EXCEL",
                          style: theme.typography.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(
                        width: 22,
                        child: Icon(
                          FluentIcons.forward,
                          size: 12,
                          color: theme.resources.textFillColorSecondary,
                        ),
                      ),
                      Expanded(
                        flex: 5,
                        child: Text(
                          "COMPARATIVA SQL",
                          style: theme.typography.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          "ACCIONES",
                          style: theme.typography.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text(
                          "ESTADO",
                          style: theme.typography.bodyStrong,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _visibleList.length,
                        itemBuilder: (context, index) {
                          final item = _visibleList[index];
                          final codigo = item['Codigo_Pieza'] as String;
                          final isSelected = _selectedUpdates.contains(codigo);
                          final estado = item['Estado'] as String;
                          final detalles =
                              (item['Detalles'] as String?) ?? "";
                          final isManual = item['is_manual_edit'] == true;
                          final isConflicto = estado == 'CONFLICTO';
                          final xd = item['Excel_Data'];
                          final Map<String, dynamic> excelMap = xd is Map
                              ? Map<String, dynamic>.from(xd)
                              : <String, dynamic>{};
                          final matVal =
                              (excelMap['Material_Excel'] ?? '').toString();
                          final medVal =
                              (excelMap['Medida_Excel'] ?? '').toString();
                          final descVal =
                              (excelMap['Descripcion_Excel'] ?? '').toString();
                          final excelTooltip =
                              'Mat: $matVal\nMed: $medVal\nDesc: $descVal';

                          final rowFill = isSelected
                              ? theme.accentColor.withValues(alpha: 0.12)
                              : theme.cardColor;

                          return Container(
                            decoration: BoxDecoration(
                              color: rowFill,
                              border: Border.all(
                                color: isConflicto
                                    ? theme
                                        .resources
                                        .controlStrongStrokeColorDefault
                                    : theme
                                        .resources
                                        .dividerStrokeColorDefault,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                              vertical: 4,
                              horizontal: 6,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 44,
                                        child: Center(
                                          child: Checkbox(
                                            checked: isSelected,
                                            onChanged:
                                                (v) => setState(() {
                                                  v == true
                                                      ? _selectedUpdates.add(
                                                        codigo,
                                                      )
                                                      : _selectedUpdates.remove(
                                                        codigo,
                                                      );
                                                }),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          codigo,
                                          style: theme.typography.bodyStrong,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Tooltip(
                                    message: excelTooltip,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Mat: $matVal',
                                          style: theme.typography.caption
                                              ?.copyWith(
                                            color: isManual
                                                ? theme.accentColor
                                                : null,
                                            fontWeight: isManual
                                                ? FontWeight.w600
                                                : null,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'Med: $medVal',
                                          style: theme.typography.caption
                                              ?.copyWith(
                                            color: isManual
                                                ? theme.accentColor
                                                : null,
                                            fontWeight: isManual
                                                ? FontWeight.w600
                                                : null,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          'Desc: $descVal',
                                          style: theme.typography.caption
                                              ?.copyWith(
                                            color: isManual
                                                ? theme.accentColor
                                                : null,
                                            fontWeight: isManual
                                                ? FontWeight.w600
                                                : null,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 22,
                                  child: Icon(
                                    FluentIcons.forward,
                                    size: 12,
                                    color:
                                        theme.resources.textFillColorSecondary,
                                  ),
                                ),
                                Expanded(
                                  flex: 5,
                                  child: Tooltip(
                                    message: detalles,
                                    child: Text(
                                      estado == 'NUEVO'
                                          ? "Nueva entrada"
                                          : detalles,
                                      style: theme.typography.caption?.copyWith(
                                        fontStyle: estado == 'NUEVO'
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                        color:
                                            theme
                                                .resources
                                                .textFillColorSecondary,
                                      ),
                                      maxLines: 3,
                                      softWrap: true,
                                      overflow: TextOverflow.fade,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 72,
                                  child: IconButton(
                                    icon: const Icon(
                                      FluentIcons.edit,
                                      size: 14,
                                    ),
                                    onPressed: () => _showEditDialog(item),
                                  ),
                                ),
                                SizedBox(
                                  width: 100,
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: estado == 'CONFLICTO'
                                            ? const Color(0xFF7F1D1D)
                                            : theme.cardColor,
                                        border: Border.all(
                                          color: estado == 'NUEVO'
                                              ? theme.accentColor
                                              : estado == 'CONFLICTO'
                                                  ? const Color(0xFFEF4444)
                                              : theme
                                                  .resources
                                                  .dividerStrokeColorDefault,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          estado,
                                          textAlign: TextAlign.center,
                                          style: theme.typography.caption
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                                color: estado == 'CONFLICTO'
                                                    ? const Color(0xFFFEE2E2)
                                                    : null,
                                              ),
                                          maxLines: 1,
                                          softWrap: false,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                  ),
                ),
              ),
              // Botones de acción al pie: la lista usa solo el espacio restante (Expanded arriba).
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  border: Border(
                    top: BorderSide(
                      color: theme.resources.dividerStrokeColorDefault,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final bool canMantenerSel =
                          !_isLoading && _hasSelectedConflicts;
                      final bool canSincronizar =
                          canSyncSelection && !_isLoading;

                      if (constraints.maxWidth > 800) {
                        final actionButtons = <Widget>[
                          if (hasConflictRows) ...[
                            Button(
                              onPressed: canMantenerSel
                                  ? _keepDbForSelectedConflicts
                                  : null,
                              child: const Text('Mantener BD Sel.'),
                            ),
                            Button(
                              onPressed:
                                  _isLoading ? null : _keepDbForAllConflicts,
                              child: const Text('Mantener Todos'),
                            ),
                          ],
                          Button(
                            onPressed: _isLoading ? null : _syncOnlyNew,
                            child: const Text('Solo Nuevos'),
                          ),
                          Button(
                            onPressed: canSincronizar ? _syncSelected : null,
                            child: _isLoading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: ProgressRing(strokeWidth: 2),
                                  )
                                : Text(
                                    'Sincronizar (${_selectedUpdates.length})',
                                  ),
                          ),
                          Button(
                            onPressed: () {
                              setState(() {
                                _conflicts.clear();
                                _totalProcessed = 0;
                                _selectedUpdates.clear();
                                _searchQuery = '';
                                _searchController.clear();
                              });
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(FluentIcons.back, size: 14),
                                SizedBox(width: 6),
                                Text('Limpiar'),
                              ],
                            ),
                          ),
                          if (_filterStatus != 'CONFLICTO')
                            Button(
                              onPressed: _isLoading ? null : _syncOnlyNew,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(FluentIcons.add, size: 14),
                                  SizedBox(width: 6),
                                  Text('Aprobar nuevos'),
                                ],
                              ),
                            ),
                          Button(
                            onPressed:
                                _isLoading ? null : _limpiarMaterialVacio,
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.broom, size: 14),
                                SizedBox(width: 6),
                                Text('Limpiar Material'),
                              ],
                            ),
                          ),
                        ];

                        return SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minWidth: constraints.maxWidth,
                            ),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: actionButtons,
                            ),
                          ),
                        );
                      }

                      return Center(
                        child: material.PopupMenuButton<String>(
                          tooltip: 'Acciones',
                          onSelected: (value) {
                            switch (value) {
                              case 'mantener_sel':
                                if (canMantenerSel) {
                                  _keepDbForSelectedConflicts();
                                }
                                break;
                              case 'mantener_todos':
                                if (!_isLoading) _keepDbForAllConflicts();
                                break;
                              case 'solo_nuevos':
                                if (!_isLoading) _syncOnlyNew();
                                break;
                              case 'sincronizar':
                                if (canSincronizar) _syncSelected();
                                break;
                              case 'limpiar':
                                setState(() {
                                  _conflicts.clear();
                                  _totalProcessed = 0;
                                  _selectedUpdates.clear();
                                  _searchQuery = '';
                                  _searchController.clear();
                                });
                                break;
                              case 'aprobar_nuevos':
                                if (_filterStatus != 'CONFLICTO' &&
                                    !_isLoading) {
                                  _syncOnlyNew();
                                }
                                break;
                              case 'limpiar_material':
                                if (!_isLoading) _limpiarMaterialVacio();
                                break;
                            }
                          },
                          itemBuilder: (context) {
                            final items = <material.PopupMenuEntry<String>>[];

                            if (hasConflictRows) {
                              items.add(
                                const material.PopupMenuItem<String>(
                                  value: 'mantener_sel',
                                  child: Text('Mantener BD Sel.'),
                                ),
                              );
                              items.add(
                                const material.PopupMenuItem<String>(
                                  value: 'mantener_todos',
                                  child: Text('Mantener Todos'),
                                ),
                              );
                            }

                            items.add(
                              const material.PopupMenuItem<String>(
                                value: 'solo_nuevos',
                                child: Text('Solo Nuevos'),
                              ),
                            );
                            items.add(
                              material.PopupMenuItem<String>(
                                value: 'sincronizar',
                                child: Text(
                                  'Sincronizar (${_selectedUpdates.length})',
                                ),
                              ),
                            );
                            items.add(
                              const material.PopupMenuItem<String>(
                                value: 'limpiar',
                                child: Text('Limpiar'),
                              ),
                            );

                            if (_filterStatus != 'CONFLICTO') {
                              items.add(
                                const material.PopupMenuItem<String>(
                                  value: 'aprobar_nuevos',
                                  child: Text('Aprobar nuevos'),
                                ),
                              );
                            }

                            items.add(
                              const material.PopupMenuItem<String>(
                                value: 'limpiar_material',
                                child: Text('Limpiar Material'),
                              ),
                            );

                            return items;
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color:
                                    theme.resources.dividerStrokeColorDefault,
                              ),
                            ),
                            child: const Text('Acciones'),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
