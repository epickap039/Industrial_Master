part of 'package:industrial_manager_v15_5/screens/bom_manager.dart';

/// Lógica de negocio, estado y diálogos de datos del gestor BOM.
/// La construcción principal del árbol, tablas, vista plana y [build] permanecen en la pantalla.
mixin BomManagerControllerMixin on State<BOMManagerScreen> {
  bool _isLoading = false;
  /// POST manuales (estación / ensamble / pieza): deshabilita acciones y muestra progreso.
  bool _manualBomMutating = false;

  int? _currentIdCliente;
  String _currentClientName = '';

  List<dynamic> _arbol = [];
  dynamic _selectedEnsamble;
  List<dynamic> _revisiones = [];
  dynamic _selectedRevision;
  List<dynamic> _vins = [];

  // Vista Plana Excel
  List<dynamic> _bomPlana = [];
  bool _vistaPlana = false;

  // Estado de guardado (indicador de cambios pendientes)
  bool _hasPendingChanges = false;
  DateTime? _lastSavedAt;

  // v60.0: determina el color de acento según el nombre del tracto
  Color get _accentColor {
    final t = (widget.tractoName ?? '').toUpperCase();
    if (t.contains('KENWORTH')) return const Color(0xFFD32F2F); // Rojo
    if (t.contains('INTERNATIONAL')) return const Color(0xFFE65100); // Naranja
    if (t.contains('PETERBILT')) return const Color(0xFF1565C0); // Azul
    return const Color(0xFF1565C0); // Azul por defecto
  }

  // v60.0: ID maestro de la versión de ingeniería
  int get _masterId => widget.idVersion ?? widget.idCliente ?? 1;
  bool get _usingVersionMode => widget.idVersion != null;

  // ── Estado de edición PLM ──────────────────────────────────────────────────
  /// Editable sólo en estado Borrador (≡ PENDIENTE en terminología PLM)
  bool get _esEditable =>
      _selectedRevision != null &&
      (_selectedRevision!['estado'] == 'Borrador' ||
          _selectedRevision!['estado'] == 'PENDIENTE');

  bool get _esAprobada =>
      _selectedRevision != null &&
      _selectedRevision!['estado'] == 'Aprobada';

  bool get _esObsoleta =>
      _selectedRevision != null &&
      _selectedRevision!['estado'] == 'OBSOLETO';

  @override
  void didUpdateWidget(BOMManagerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetRevisionId != oldWidget.targetRevisionId &&
        widget.targetRevisionId != null) {
      if (_revisiones.isNotEmpty) {
        final rev = _revisiones.firstWhere(
          (r) => r['id_revision'] == widget.targetRevisionId,
          orElse: () => null,
        );
        if (rev != null) {
          setState(() {
            _selectedRevision = rev;
          });
          _fetchArbol();
        }
      }
    }
  }

  void _clearData() {
    setState(() {
      _arbol = [];
      _selectedEnsamble = null;
      _vins = [];
      _bomPlana = [];
    });
  }

  /// Usuario de sesión para header `X-Usuario` en auditoría de ingeniería.
  Future<String> _prefsUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString('username')?.trim();
    return (u != null && u.isNotEmpty) ? u : 'Operador';
  }

  String _clientesDeRevision(dynamic rev) {
    if (rev == null) return '';
    final String clientes =
        ((rev['clientes_afectados'] ?? rev['cliente']) ?? '').toString().trim();
    return clientes;
  }

  Future<void> _ensureRevisionClientContext() async {
    if (!mounted || _revisiones.isEmpty) return;

    final bool needsContext = _revisiones.any((r) {
      final hasVersion = r['id_version'] != null;
      final hasClientes = _clientesDeRevision(r).isNotEmpty;
      return !hasVersion || !hasClientes;
    });
    if (!needsContext) return;

    try {
      final res = await ApiClient.getUnvalidated('/api/mapa/jerarquia');
      if (!mounted || res.statusCode != 200) return;
      final dynamic decoded = res.decodeJson();
      if (decoded is! List) return;

      final Map<int, Map<String, dynamic>> metaByRevision = {};
      for (final tracto in decoded) {
        final tipos = (tracto['tipos'] as List?) ?? const [];
        for (final tipo in tipos) {
          final versiones = (tipo['versiones'] as List?) ?? const [];
          for (final ver in versiones) {
            final int? idVersion = (ver['id'] as num?)?.toInt();
            final revisiones = (ver['revisiones'] as List?) ?? const [];
            for (final rev in revisiones) {
              final int? idRev = (rev['id_revision'] as num?)?.toInt();
              if (idRev == null) continue;
              final String clientes =
                  ((rev['clientes_afectados'] ?? rev['cliente']) ??
                          'Ingeniería Base (Sin clientes)')
                      .toString();
              metaByRevision[idRev] = {
                'id_version': idVersion,
                'clientes_afectados': clientes,
              };
            }
          }
        }
      }

      if (metaByRevision.isEmpty || !mounted) return;

      final List<dynamic> revisionesUpdated =
          _revisiones.map((r) {
            final int? idRev = (r['id_revision'] as num?)?.toInt();
            if (idRev == null) return r;
            final meta = metaByRevision[idRev];
            if (meta == null) return r;
            return {
              ...Map<String, dynamic>.from(r as Map),
              'id_version': r['id_version'] ?? meta['id_version'],
              'clientes_afectados':
                  _clientesDeRevision(r).isNotEmpty
                      ? _clientesDeRevision(r)
                      : meta['clientes_afectados'],
            };
          }).toList();

      final int? selectedId = (_selectedRevision?['id_revision'] as num?)?.toInt();
      dynamic selectedUpdated = _selectedRevision;
      if (selectedId != null) {
        selectedUpdated = revisionesUpdated.firstWhere(
          (r) => r['id_revision'] == selectedId,
          orElse: () => _selectedRevision,
        );
      }

      setState(() {
        _revisiones = revisionesUpdated;
        _selectedRevision = selectedUpdated;
      });
    } catch (_) {}
  }

  Future<void> _fetchRevisiones() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      // v60.0: usa endpoint por version si está disponible
      final path = _usingVersionMode
          ? '/api/bom/revisiones/version/$_masterId'
          : '/api/bom/revisiones/$_masterId';
      final response = await ApiClient.getUnvalidated(path);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> lista = response.decodeJson() as List<dynamic>;
        _clearData();
        // Determinar qué revisión seleccionar — FUERA del setState para
        // no llamar _fetchArbol() ni _fetchBomPlana() dentro del callback.
        dynamic nuevaSeleccion;
        if (lista.isNotEmpty) {
          if (widget.targetRevisionId != null) {
            nuevaSeleccion = lista.firstWhere(
              (r) => r['id_revision'] == widget.targetRevisionId,
              orElse: () => lista.last,
            );
          } else if (_selectedRevision != null) {
            // Intentar mantener la revisión actualmente seleccionada;
            // si ya no existe (fue borrada) caer al último elemento.
            nuevaSeleccion = lista.firstWhere(
              (r) => r['id_revision'] == _selectedRevision!['id_revision'],
              orElse: () => lista.last,
            );
          } else {
            nuevaSeleccion = lista.last;
          }
        }
        if (!mounted) return;
        setState(() {
          _revisiones = lista;
          _selectedRevision = nuevaSeleccion; // null si lista vacía
        });
        await _ensureRevisionClientContext();
        if (!mounted) return;
        // Disparar carga del árbol FUERA del setState — evita RangeError
        // por reconstrucción del widget tree con datos a medio actualizar.
        if (nuevaSeleccion != null) {
          _fetchArbol();
          if (_vistaPlana) _fetchBomPlana();
        }
      }
    } catch (e) {
      if (mounted) _showError("Error al cargar revisiones: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Crea una nueva revisión. El nombre "Revisión N" se genera en el backend.
  /// [notas] es texto libre opcional que se registra en el log de auditoría.
  Future<void> _addRevision(String notas) async {
    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('Ya existe una revisión activa. No se puede crear una base nueva.');
       return;
    }

    setState(() => _isLoading = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final path = _usingVersionMode
          ? '/api/bom/revisiones/version/$_masterId'
          : '/api/bom/revisiones/$_masterId';
      final response = await ApiClient.postUnvalidated(
        path,
        headers: {'X-Usuario': username},
        body: {'notas': notas.isEmpty ? null : notas},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        await _fetchRevisiones();
      } else {
        _showError("Error al crear revisión: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) _showError("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showNewRevisionDialog() {
    String notasValue = '';
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 300),
        title: Row(
          children: [
            Icon(FluentIcons.add, size: 16, color: _accentColor),
            const SizedBox(width: 8),
            const Text('Nueva Revisión de Ingeniería',
                style: TextStyle(fontSize: 14)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentColor.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(FluentIcons.info, size: 13, color: _accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'El nombre se generará automáticamente como "Revisión N".',
                      style: TextStyle(fontSize: 11, color: _accentColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            InfoLabel(
              label: 'Anotaciones / Notas  (opcional)',
              child: TextBox(
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 12),
                placeholder:
                    'Ej: Cambios en bastidor trasero, revisión por ECR-042...',
                maxLines: 3,
                onChanged: (v) => notasValue = v,
              ),
            ),
          ],
        ),
        actions: [
          Button(
            child: const Text('Cancelar'),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            child: const Text('Crear Revisión'),
            onPressed: () {
              Navigator.pop(ctx);
              _addRevision(notasValue.trim());
            },
          ),
        ],
      ),
    );
  }

  /// Abre el Auditor de Cambios (diff estilo Git) antes de aprobar la revisión.
  void _showAprobarConfirmDialog() {
    if (_selectedRevision == null) return;
    final int idRev = _selectedRevision!['id_revision'] as int;
    final String revNum =
        (_selectedRevision!['numero_revision'] ?? '-').toString();
    showDialog(
      context: context,
      builder: (ctx) => _DiffAuditorDialog(
        idRevision: idRev,
        revNum: revNum,
        accentColor: _accentColor,
        onConfirm: () {
          Navigator.pop(ctx);
          _aprobarRevision();
        },
      ),
    );
  }

  Future<void> _aprobarRevision() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.putUnvalidated(
        '/api/bom/revisiones/${_selectedRevision['id_revision']}/aprobar',
        headers: {'X-Usuario': username},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showError("Revisión Aprobada Correctamente", isError: false);
        // Limpieza atómica para evitar RangeError por estado inconsistente tras recargar.
        setState(() {
          _revisiones = []; // CRÍTICO PARA EVITAR RANGE ERROR
          _selectedRevision = null;
          _arbol = [];
          _bomPlana = [];
          _selectedEnsamble = null;
        });
        await _fetchRevisiones();
      } else {
        _showError("Error al aprobar: ${response.rawBody}");
      }
    } catch (e) {
      if (mounted) _showError("Error de conexión: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchArbol() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/bom/arbol/${_selectedRevision['id_revision']}',
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          _arbol = response.decodeJson();
          _hasPendingChanges = false;
          _lastSavedAt = DateTime.now();
          // Actualizar selectedEnsamble si es que se borró o cambió
          if (_selectedEnsamble != null) {
            bool found = false;
            for (var est in _arbol) {
              for (var ens in est['ensambles']) {
                if (ens['id'] == _selectedEnsamble['id']) {
                  _selectedEnsamble = ens;
                  found = true;
                  break;
                }
              }
            }
            if (!found) _selectedEnsamble = null;
          }
        });
      } else {
        _showError("Error cargar árbol: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) _showError("Error al cargar árbol: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchBomPlana() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/bom/plana/${_selectedRevision['id_revision']}',
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          _bomPlana = response.decodeJson();
          _hasPendingChanges = false;
          _lastSavedAt = DateTime.now();
        });
      } else {
        _showError("Error al cargar vista plana: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) _showError("Error al cargar vista plana: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importarExcel() => _importarBomDesdeExcel(sumar: false);

  Future<void> _sumarExcel() => _importarBomDesdeExcel(sumar: true);

  void _showGuiaImportacionDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        final t = FluentTheme.of(dialogCtx).typography;
        return ContentDialog(
          title: const Text('Guía de Importación'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Importar Excel', style: t.bodyStrong),
                const SizedBox(height: 8),
                Text(
                  'Borra toda la lista de la versión y la reemplaza por el Excel.',
                  style: t.body,
                ),
                const SizedBox(height: 16),
                Text('Sumar Excel', style: t.bodyStrong),
                const SizedBox(height: 8),
                Text(
                  'Mantiene la lista actual, suma las cantidades y añade las piezas nuevas.',
                  style: t.body,
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Entendido'),
            ),
          ],
        );
      },
    );
  }

  /// [sumar]: false = reemplazo total de la revisión; true = upsert y suma de cantidades.
  Future<void> _importarBomDesdeExcel({required bool sumar}) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        withData: true,
      );
      if (!mounted) return;

      if (result == null || result.files.isEmpty) return;

      if (_selectedRevision == null) {
        _showError("Crea o selecciona una revisión primero");
        return;
      }

      final picked = result.files.single;
      String? filePath = picked.path;
      if (filePath == null || filePath.isEmpty) {
        final bytes = picked.bytes;
        if (bytes != null) {
          final dir = await getTemporaryDirectory();
          final safe =
              picked.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
          final prefix = sumar ? 'bom_sumar_' : 'bom_import_';
          filePath =
              '${dir.path}${Platform.pathSeparator}$prefix$safe';
          await File(filePath).writeAsBytes(bytes, flush: true);
        }
      }

      if (filePath == null || filePath.isEmpty) {
        if (mounted) {
          _showError(
            'No se pudo acceder al archivo (sin ruta ni datos en memoria).',
          );
        }
        return;
      }

      final resolvedPath = filePath;

      setState(() => _isLoading = true);

      final uploadFile = await ApiClient.fileField('file', resolvedPath);
      if (!mounted) return;

      final username = await _prefsUsername();
      if (!mounted) return;

      final idRev = _selectedRevision['id_revision'];
      final path = sumar
          ? '/api/bom/importar_sumar/$idRev'
          : '/api/bom/importar/$idRev';

      try {
        final data = await ApiClient.postMultipart(
          path,
          files: {'file': uploadFile},
          headers: {'X-Usuario': username},
        ) as Map<String, dynamic>;
        if (!mounted) return;

        final int importadas = data['insertados'] ?? 0;
        final int actualizadas = data['actualizados'] is int
            ? data['actualizados'] as int
            : int.tryParse('${data['actualizados']}') ?? 0;
        final List<dynamic> erroresRaw = data['errores'] ?? [];
        final List<String> errores =
            erroresRaw.map((e) => e.toString()).toList();

        final String okMsg = sumar
            ? '✅ Sumar Excel: $importadas líneas nuevas en estructura, '
                '$actualizadas cantidades actualizadas.'
            : '✅ Se cargaron $importadas piezas con éxito (reemplazo total).';

        if (errores.isEmpty) {
          _showError(
            okMsg,
            isError: false,
          );
        } else {
          final String intro = sumar
              ? '$okMsg\n\n'
                  'Los siguientes códigos no existen en el catálogo maestro y fueron omitidos:'
              : 'Se cargaron $importadas piezas con éxito.\n\n'
                  'Los siguientes códigos no existen en el catálogo maestro y fueron omitidos:';

          showDialog(
            context: context,
            builder: (dialogCtx) => ContentDialog(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
              title: Text(sumar ? 'Resumen Sumar Excel' : 'Resumen de Importación'),
              content: SizedBox(
                width: 480,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(intro),
                    const SizedBox(height: 12),
                    Text(
                      'Omitidos (${errores.length})',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: FluentTheme.of(dialogCtx)
                                .resources
                                .dividerStrokeColorDefault,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            vertical: 4,
                            horizontal: 8,
                          ),
                          itemCount: errores.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: SelectableText(
                                errores[index],
                                style: FluentTheme.of(context).typography.body,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString(
                      'bom_bridge_excel_path',
                      resolvedPath,
                    );
                    await prefs.setBool('bom_bridge_filter_nuevos', true);
                    if (!dialogCtx.mounted) return;
                    Navigator.pop(dialogCtx);
                    if (!mounted) return;
                    MainNav.goToPanePopOverlays(
                      context,
                      kMainPaneImportarExcel,
                    );
                  },
                  child: const Text('Registrar Piezas Nuevas en Catálogo'),
                ),
                Button(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: errores.join('\n')));
                    _showError(
                      'Lista copiada al portapapeles',
                      isError: false,
                    );
                  },
                  child: const Text('Copiar lista'),
                ),
                Button(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cerrar'),
                ),
              ],
            ),
          );
        }
        _fetchArbol();
      } on ApiException catch (e) {
        if (mounted) {
          _showError(
            sumar ? "Error al sumar Excel: $e" : "Error al importar: $e",
          );
        }
      }
    } catch (e) {
      if (mounted) {
        _showError(
          sumar
              ? "Error durante la suma desde Excel: $e"
              : "Error durante la importación: $e",
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _apiErrorDetail(dynamic decoded) {
    if (decoded is! Map) return 'Error desconocido';
    final d = decoded['detail'];
    if (d is String) return d;
    if (d is List && d.isNotEmpty) {
      final first = d.first;
      if (first is Map) {
        final msg = first['msg'];
        if (msg is String) return msg;
      }
    }
    return 'Error desconocido';
  }

  /// Mensaje legible desde [ApiHttpResult]: prioriza `detail` JSON y si no, el cuerpo crudo (p. ej. SQL en 500).
  String _apiErrorDetailFromResponse(ApiHttpResult response) {
    final decoded = response.decodeJsonLenient();
    var msg = _apiErrorDetail(decoded);
    if (msg == 'Error desconocido') {
      final raw = response.rawBody.trim();
      if (raw.isNotEmpty) {
        msg = raw.length > 2500 ? '${raw.substring(0, 2500)}…' : raw;
      } else {
        msg = 'Error HTTP ${response.statusCode}';
      }
    }
    return msg;
  }

  Future<void> _addEstacion(String nombre) async {
    if (_selectedRevision == null) return;
    setState(() => _manualBomMutating = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.postUnvalidated(
        '/api/bom/estaciones',
        headers: {'X-Usuario': username},
        body: {
          'id_revision': _selectedRevision['id_revision'],
          'nombre': nombre,
        },
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showError('Estación creada correctamente.', isError: false);
        _fetchArbol();
      } else {
        final decoded = response.decodeJsonLenient();
        _showError(_apiErrorDetail(decoded));
      }
    } catch (e) {
      if (mounted) _showError('Error al agregar la estación: $e');
    } finally {
      if (mounted) setState(() => _manualBomMutating = false);
    }
  }

  Future<void> _deleteEstacion(int id) async {
    try {
      final response = await ApiClient.deleteUnvalidated('/api/bom/estaciones/$id');
      if (!mounted) return;
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _arbol.any((est) => est['id'] == id)) {
          _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final decoded = response.decodeJsonLenient();
        final errorMsg =
            (decoded is Map ? decoded['detail'] : null) ?? "Error desconocido";
        _showError(errorMsg);
      }
    } catch (e) {
      if (mounted) _showError("Error al eliminar la estación: $e");
    }
  }

  Future<void> _addEnsamble(int idEstacion, String nombre) async {
    setState(() => _manualBomMutating = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.postUnvalidated(
        '/api/bom/ensambles',
        headers: {'X-Usuario': username},
        body: {'id_estacion': idEstacion, 'nombre': nombre},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showError('Ensamble creado correctamente.', isError: false);
        _fetchArbol();
      } else {
        final decoded = response.decodeJsonLenient();
        _showError(_apiErrorDetail(decoded));
      }
    } catch (e) {
      if (mounted) _showError('Error al agregar el ensamble: $e');
    } finally {
      if (mounted) setState(() => _manualBomMutating = false);
    }
  }

  Future<void> _deleteEnsamble(int id) async {
    try {
      final response = await ApiClient.deleteUnvalidated('/api/bom/ensambles/$id');
      if (!mounted) return;
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _selectedEnsamble['id'] == id) {
          _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final decoded = response.decodeJsonLenient();
        final errorMsg =
            (decoded is Map ? decoded['detail'] : null) ?? "Error desconocido";
        _showError(errorMsg);
      }
    } catch (e) {
      if (mounted) _showError("Error al eliminar el ensamble: $e");
    }
  }

  Future<void> _addPieza(
    String codigo,
    double cantidad,
    String obs, {
    Map<String, dynamic>? maestroRegistro,
  }) async {
    if (_selectedEnsamble == null) return;
    setState(() => _manualBomMutating = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      // `observaciones` → BOMPayload; si no hay fila en maestro, `maestro` → INSERT catálogo + BOM
      final body = <String, dynamic>{
        'id_ensamble': _selectedEnsamble['id'],
        'codigo_pieza': codigo,
        'cantidad': cantidad,
        'observaciones': obs,
      };
      if (maestroRegistro != null && maestroRegistro.isNotEmpty) {
        body['maestro'] = maestroRegistro;
      }
      final response = await ApiClient.postUnvalidated(
        '/api/bom/estructura',
        headers: {'X-Usuario': username},
        body: body,
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _showError('Pieza agregada al ensamble.', isError: false);
        _fetchArbol();
      } else {
        _showError(_apiErrorDetailFromResponse(response));
      }
    } catch (e) {
      if (mounted) _showError('Error al agregar la pieza: $e');
    } finally {
      if (mounted) setState(() => _manualBomMutating = false);
    }
  }

  Future<void> _deletePieza(int idBom) async {
    try {
      final response = await ApiClient.deleteUnvalidated('/api/bom/estructura/$idBom');
      if (!mounted) return;
      if (response.statusCode == 200) {
        if (_vistaPlana) {
          _fetchBomPlana();
        } else {
          _fetchArbol();
        }
      }
    } catch (e) {
      if (mounted) _showError("Error al eliminar la pieza: $e");
    }
  }

  Future<void> _updateCantidadPieza(int idBom, double nuevaCantidad) async {
    // Guard: nunca enviar si la revisión activa no es editable.
    // Previene 404/403 cuando el usuario interactúa con IDs de un clon previo.
    if (!_esEditable) {
      _showError(
        'No se puede editar una ingeniería bloqueada. Inicia un cambio ECR.',
      );
      return;
    }
    if (mounted) setState(() => _hasPendingChanges = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.putUnvalidated(
        '/api/bom/estructura/cantidad/$idBom',
        headers: {'X-Usuario': username},
        body: {'cantidad': nuevaCantidad},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        if (mounted) setState(() => _hasPendingChanges = false);
        _showError("✅ Cantidad actualizada correctamente", isError: false);
        if (_vistaPlana) {
          _fetchBomPlana();
        } else {
          _fetchArbol();
        }
      } else {
        final dynamic decoded = response.decodeJsonLenient();
        final String detail = (decoded is Map ? decoded['detail'] : null) ??
            'Error ${response.statusCode}';
        _showError(detail);
      }
    } catch (e) {
      if (mounted) _showError("Error de conexión: $e");
    }
  }

  Future<void> _exportarExcel() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final bytes = await ApiClient.getBytes(
        '/api/bom/exportar/${_selectedRevision['id_revision']}',
      );
      if (!mounted) return;
      final directory = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final filePath =
          '${directory.path}/BOM_Rev_${_selectedRevision['numero_revision']}.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      _showError("Archivo exportado en: $filePath", isError: false);
      OpenFile.open(filePath);
    } on ApiException catch (e) {
      if (mounted) _showError("Error al exportar: ${e.statusCode}");
    } catch (e) {
      if (mounted) _showError("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Verificación de VINs antes de permitir el borrado ─────────────────────
  Future<void> _checkAndShowDeleteDialog() async {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    // Refrescar VINs para tener datos al día antes de la comprobación.
    await _fetchVINs();
    if (!mounted) return;

    if (_vins.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 300),
          title: Row(
            children: [
              Icon(FluentIcons.error_badge, color: Colors.red, size: 18),
              const SizedBox(width: 8),
              const Text('Borrado Bloqueado',
                  style: TextStyle(fontSize: 14)),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withOpacity(0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(FluentIcons.error_badge,
                    size: 20, color: Colors.red),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No se puede borrar esta lista.\n\n'
                    'Tiene ${_vins.length} unidad(es) física(s) '
                    '(VINs) asignada(s). Primero desvincula las '
                    'unidades desde "Gestionar VINs" o cancélalas '
                    'en el sistema.',
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ],
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
      return;
    }

    // Sin VINs asignados → mostrar diálogo de borrado normal.
    _showDeleteRevisionDialog();
  }

  // ── Admin Delete Override ───────────────────────────────────────────────────
  void _showAdminDeleteDialog() {
    final TextEditingController pwdCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Anular Bloqueo (Admin)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Esta revisión es un archivo histórico. Ingrese clave admin:', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            PasswordBox(
              controller: pwdCtrl,
              placeholder: 'Contraseña maestra...',
              onSubmitted: (v) {
                if (v == 'ADMIN_ING_2024') {
                  Navigator.pop(ctx);
                  _deleteRevision(password: v, motivo: 'Forzado por Admin Override');
                } else {
                  _showError('Contraseña incorrecta');
                }
              },
            ),
          ],
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(ctx)),
          FilledButton(
            style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
            onPressed: () {
              if (pwdCtrl.text == 'ADMIN_ING_2024') {
                Navigator.pop(ctx);
                _deleteRevision(password: pwdCtrl.text, motivo: 'Forzado por Admin Override');
              } else {
                _showError('Contraseña incorrecta');
              }
            },
            child: const Text('Forzar Borrado'),
          ),
        ],
      ),
    );
  }

  // ── Control de Cambios (ECR) — Gatillo de Edición ─────────────────────────
  Future<void> _showBranchingDialog() async {
    if (_selectedRevision == null) return;
    await _ensureRevisionClientContext();
    if (!mounted) return;

    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('No se puede crear otra revisión. Ya existe una en edición permanente ("Borrador" / "Pendiente"). Finalízala primero.');
       return;
    }

    final int? idVersion = (_selectedRevision!['id_version'] as num?)?.toInt();
    if (idVersion == null) {
      _showError('No se pudo determinar la versión para cargar clientes.');
      return;
    }
    final int numRev =
        (_selectedRevision!['numero_revision'] as num?)?.toInt() ?? 0;

    // Cargar clientes para poder ofrecer la opción ESPECÍFICO
    List<Map<String, dynamic>> clientes = [];
    try {
      final resp = await ApiClient.getUnvalidated('/api/proyectos/clientes/$idVersion');
      if (resp.statusCode == 200) {
        clientes = List<Map<String, dynamic>>.from(resp.decodeJson() as List);
      }
    } catch (_) {}
    if (!mounted) return;

    String tipoCambio = 'GLOBAL';
    final Set<int> selectedClientes = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
          title: Row(
            children: [
              Icon(FluentIcons.build_definition, size: 18, color: _accentColor),
              const SizedBox(width: 8),
              const Text('Iniciar Cambio de Ingeniería (ECR)',
                  style: TextStyle(fontSize: 14)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rev. $numRev está APROBADA. Elige cómo aplicar el cambio:',
                style: const TextStyle(fontSize: 12, color: Color(0xFF616161)),
              ),
              const SizedBox(height: 16),
              // ── Opción GLOBAL ──────────────────────────────────────────
              RadioButton(
                checked: tipoCambio == 'GLOBAL',
                onChanged: (_) => setD(() => tipoCambio = 'GLOBAL'),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Cambio Global (Toda la Versión)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      'Crea Rev ${numRev + 1} en la misma versión para todos los '
                      'clientes vinculados. Ningún cliente es reasignado.',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF757575)),
                    ),
                  ],
                ),
              ),
              // ── Opción ESPECÍFICO — siempre visible (PLM v2) ──────────
              const SizedBox(height: 14),
              RadioButton(
                checked: tipoCambio == 'ESPECIFICO',
                onChanged: (_) => setD(() => tipoCambio = 'ESPECIFICO'),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Cambio para Cliente(s) Específico(s)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    const Text(
                      'Crea una nueva Versión de Ingeniería (V2) y mueve los clientes '
                      'seleccionados. Los demás mantienen la ingeniería actual.',
                      style: TextStyle(fontSize: 11, color: Color(0xFF757575)),
                    ),
                  ],
                ),
              ),
              if (tipoCambio == 'ESPECIFICO') ...[
                const SizedBox(height: 8),
                if (clientes.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFBDBDBD)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: clientes
                          .map((c) => Checkbox(
                                checked: selectedClientes.contains(c['id'] as int),
                                onChanged: (v) => setD(() {
                                  if (v == true) {
                                    selectedClientes.add(c['id'] as int);
                                  } else {
                                    selectedClientes.remove(c['id'] as int);
                                  }
                                }),
                                content: Text(c['nombre'] as String),
                              ))
                          .toList(),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      border: Border.all(color: const Color(0xFFF9A825)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Esta versión base no tiene clientes. Se creará la nueva versión vacía para asignar clientes posteriormente.',
                      style: TextStyle(fontSize: 11, color: Color(0xFFE65100)),
                    ),
                  ),
              ],
            ],
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(ctx),
            ),
            FilledButton(
              onPressed: () async {
                final result = await _ejecutarBranching(
                  tipoCambio,
                  selectedClientes.toList(),
                );
                if (!mounted || result == null) return;

                Navigator.of(ctx).pop();

                final idNuevo = result['nuevo_id_revision'];
                if (idNuevo == null) {
                  _showError("Error: API no devolvió ID de revisión.");
                  return;
                }

                final idVersionNueva = result['id_version_nueva'];
                if (idVersionNueva == null) {
                  _showError("Error: API no devolvió ID de versión.");
                  return;
                }

                Navigator.of(context).pushReplacement(
                  FluentPageRoute(
                    builder: (_) => BOMManagerScreen(
                      idVersion: (idVersionNueva as num).toInt(),
                      targetRevisionId: (idNuevo as num).toInt(),
                      tractoName: widget.tractoName,
                    ),
                  ),
                );
              },
              child: const Text('Crear Rama y Editar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _ejecutarBranching(
      String tipoCambio, List<int> listaClientes) async {
    if (_selectedRevision == null) return null;

    // 1. Limpieza atómica: invalidar TODOS los datos de la revisión anterior
    //    antes de hacer cualquier llamada de red para que el árbol no muestre
    //    IDs fantasma del clon.
    if (mounted) {
      setState(() {
        _isLoading         = true;
        _arbol             = [];
        _selectedEnsamble  = null;
        _vins              = [];
        _bomPlana          = [];
      });
    }

    try {
      final username = await _prefsUsername();
      if (!mounted) return null;
      final response = await ApiClient.postUnvalidated(
        '/api/bom/branching',
        headers: {'X-Usuario': username},
        body: {
          'id_revision_origen': _selectedRevision!['id_revision'],
          'tipo_cambio': tipoCambio,
          'lista_clientes': listaClientes,
        },
      );
      if (!mounted) return null;

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data   = response.decodeJson() as Map<String, dynamic>;
        final int nuevoId = data['nuevo_id_revision'] as int;

        if (tipoCambio == 'ESPECIFICO') {
          return data;
        } else {
          // ── GLOBAL ──────────────────────────────────────────────────────
          // 2. Recargar lista de revisiones (incluye la nueva)
          await _fetchRevisiones();
          if (!mounted) return null;

          // 3. Localizar la nueva revisión por su ID exacto (devuelto por el backend)
          final newRev = _revisiones.firstWhere(
            (r) => r['id_revision'] == nuevoId,
            orElse: () => null,
          );

          if (newRev != null && mounted) {
            // 4. Seleccionar atómicamente y borrar cualquier ensamble previo
            setState(() {
              _selectedRevision  = newRev;
              _arbol             = [];
              _selectedEnsamble  = null;
              _vins              = [];
              _bomPlana          = [];
            });

            // 5. Cargar árbol fresco — ahora con los IDs del clon
            await _fetchArbol();
            await _fetchVINs();
            if (_vistaPlana && mounted) await _fetchBomPlana();

            if (mounted) {
              _showError(
                '✅ Rev. ${data['numero_revision']} creada y lista para editar.',
                isError: false,
              );
            }
          }
        }
        return data;
      } else {
        final dynamic decoded = response.decodeJsonLenient();
        final detail = (decoded is Map ? decoded['detail'] : null) ??
            'Error desconocido (${response.statusCode})';
        if (mounted) _showError('Error al crear rama: $detail');
      }
    } catch (e) {
      if (mounted) _showError('Error de conexión durante branching: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    return null;
  }

  // ── NUEVO v60.1: Eliminar revisión con protección ──────────────────────────
  Future<void> _deleteRevision({
    String password = '',
    String motivo = '',
  }) async {
    if (_selectedRevision == null) return;
    final idRev = _selectedRevision['id_revision'];
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.deleteUnvalidated(
        '/api/bom/revisiones/$idRev',
        headers: {'X-Usuario': username},
        body: {'password': password, 'motivo': motivo},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        // 1. Limpiar TODO el estado dependiente ANTES de recargar la lista,
        //    para que el widget tree no intente renderizar un índice fantasma.
        setState(() {
          _selectedRevision = null;
          _arbol            = [];
          _selectedEnsamble = null;
          _vins             = [];
          _bomPlana         = [];
        });
        // 2. Esperar la recarga completa — _fetchRevisiones seleccionará la
        //    primera revisión disponible, o dejará _selectedRevision = null.
        await _fetchRevisiones();
        if (mounted) {
          _showError("✅ Revisión eliminada correctamente", isError: false);
        }
      } else if (response.statusCode == 401) {
        if (mounted) {
          _showError("❌ Contraseña incorrecta. Operación denegada.");
        }
      } else {
        final dynamic decoded = response.decodeJsonLenient();
        final detail = (decoded is Map ? decoded['detail'] : null)
            ?? 'Error desconocido (${response.statusCode})';
        if (mounted) _showError("Error al eliminar: $detail");
      }
    } catch (e) {
      if (mounted) {
        _showError(
          "No se pudo eliminar la revisión. "
          "Verifica la conexión con el servidor.",
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showDeleteRevisionDialog() {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    final bool isAprobada = _selectedRevision['estado'] == 'Aprobada';
    final String revLabel =
        "Rev. ${_selectedRevision['numero_revision']} — ${_selectedRevision['estado']}";
    String passwordInput = '';
    String motivoInput = '';

    showDialog(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setD) => ContentDialog(
                  constraints: const BoxConstraints(
                    maxWidth: 460,
                    maxHeight: 380,
                  ),
                  title: Row(
                    children: [
                      Icon(
                        FluentIcons.delete,
                        color: isAprobada ? Colors.red : Colors.orange,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isAprobada
                              ? "⚠️ Eliminar Revisión Aprobada"
                              : "Eliminar Revisión",
                          style: const TextStyle(fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isAprobada) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.1),
                            border: Border.all(color: Colors.red),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                FluentIcons.error_badge,
                                color: Colors.red,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "ADVERTENCIA: Esta revisión está APROBADA. "
                                  "Eliminarla borrará permanentemente toda su ingeniería. "
                                  "Se requiere contraseña de seguridad.",
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "Contraseña de Seguridad:",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        PasswordBox(
                          placeholder: 'Contraseña maestra...',
                          onChanged: (v) => setD(() => passwordInput = v),
                        ),
                        const SizedBox(height: 10),
                      ] else ...[
                        Text(
                          "¿Estás seguro de eliminar $revLabel?",
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "Se borrarán todas las estaciones, ensambles y piezas de esta revisión.",
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFF57C00),
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      const Text("Motivo del borrado (opcional):"),
                      const SizedBox(height: 4),
                      TextBox(
                        placeholder: "Describe el motivo...",
                        onChanged: (v) => setD(() => motivoInput = v),
                      ),
                    ],
                  ),
                  actions: [
                    Button(
                      child: const Text("Cancelar"),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                    FilledButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.all(Colors.red),
                      ),
                      child: const Text("ELIMINAR"),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _deleteRevision(
                          password: passwordInput,
                          motivo: motivoInput,
                        );
                      },
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _clonarBOM() async {
    if (_selectedRevision == null) return;
    final int idOrigen = _selectedRevision['id_revision'];
    setState(() => _isLoading = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.postUnvalidated(
        '/api/bom/clonar/$idOrigen',
        headers: {
          'Content-Type': 'application/json',
          'X-Usuario': username,
        },
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = response.decodeJson() as Map<String, dynamic>;
        final int nuevoId = data['nuevo_id_revision'];
        final int numRev = data['numero_revision'];
        final int piezas = data['piezas_clonadas'] ?? 0;
        _showError(
          "✅ BOM clonada: Rev $numRev creada con $piezas piezas.",
          isError: false,
        );
        // Re-cargar revisiones y seleccionar automáticamente la recién creada
        await _fetchRevisionesYSeleccionar(nuevoId);
      } else {
        final decoded = response.decodeJsonLenient();
        final detail =
            (decoded is Map ? decoded['detail'] : null) ?? 'Error desconocido';
        _showError("Error al clonar BOM: $detail");
      }
    } catch (e) {
      if (mounted) _showError("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Recarga la lista de revisiones y selecciona la indicada por [targetId].
  Future<void> _fetchRevisionesYSeleccionar(int targetId) async {
    setState(() => _isLoading = true);
    try {
      final path = _usingVersionMode
          ? '/api/bom/revisiones/version/$_masterId'
          : '/api/bom/revisiones/$_masterId';
      final response = await ApiClient.getUnvalidated(path);
      if (!mounted) return;
      if (response.statusCode == 200) {
        _clearData();
        setState(() {
          _revisiones = response.decodeJson();
          _selectedRevision = _revisiones.firstWhere(
            (r) => r['id_revision'] == targetId,
            orElse: () =>
                _revisiones.isNotEmpty ? _revisiones.last : null,
          );
        });
        _fetchArbol();
        if (_vistaPlana) _fetchBomPlana();
      }
    } catch (e) {
      if (mounted) _showError("Error al recargar revisiones: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateVINNotas(int idUnidad, String notas) async {
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.putUnvalidated(
        '/api/vins/$idUnidad/notas',
        headers: {'X-Usuario': username},
        body: {
          'vin': '',
          'notas': notas,
        }, // vin es requerido por el modelo pero ignorado si es vacío en el update
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        await _fetchVINs();
      }
    } catch (e) {
      if (mounted) _showError("Error guardando notas: $e");
    }
  }

  Future<void> _fetchVINs() async {
    if (_selectedRevision == null) return;
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/bom/revisiones/${_selectedRevision['id_revision']}/vins',
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          _vins = response.decodeJson();
        });
      }
    } catch (e) {
      if (mounted) _showError("Error al cargar VINs: $e");
    }
  }

  Future<void> _addVIN(String vin) async {
    if (_selectedRevision == null) return;
    // === TAREA 2: Leer usuario real para el header ===
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final username = prefs.getString('username')?.trim().isNotEmpty == true
        ? prefs.getString('username')!.trim()
        : 'Operador';
    try {
      final response = await ApiClient.postUnvalidated(
        '/api/bom/revisiones/${_selectedRevision['id_revision']}/vins',
        headers: {
          'X-Usuario': username,
        },
        body: {'vin': vin},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        await _fetchVINs();
      } else {
        _showError("Error al agregar VIN");
      }
    } catch (e) {
      if (mounted) _showError("Error: $e");
    }
  }

  Future<void> _deleteVIN(int idUnidad) async {
    // === TAREA 2: Leer usuario real para el header ===
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final username = prefs.getString('username')?.trim().isNotEmpty == true
        ? prefs.getString('username')!.trim()
        : 'Operador';
    try {
      final response = await ApiClient.deleteUnvalidated(
        '/api/bom/vins/$idUnidad',
        headers: {
          'Content-Type': 'application/json',
          'X-Usuario': username,
        },
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        await _fetchVINs();
      } else {
        _showError("Error al eliminar VIN");
      }
    } catch (e) {
      if (mounted) _showError("Error: $e");
    }
  }

  void _showError(String message, {bool isError = true}) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: Text(isError ? 'Error' : 'Éxito'),
          content:
              isError
                  ? ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 280,
                      maxWidth: 560,
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(message),
                    ),
                  )
                  : Text(message),
          severity: isError ? InfoBarSeverity.error : InfoBarSeverity.success,
          onClose: close,
        );
      },
    );
  }

  // DIALOGOS
  void _showAddDialog(String title, Function(String) onSave) {
    String inputValue = "";
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextBox(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  placeholder: 'Nombre...',
                  onChanged: (v) => inputValue = v,
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text('Guardar'),
                onPressed: () {
                  if (inputValue.trim().isNotEmpty) {
                    onSave(inputValue.trim());
                    Navigator.pop(context);
                  }
                },
              ),
            ],
          ),
    );
  }

  Future<void> _showAddPiezaDialog() async {
    List<String> materialesOficiales = [];
    try {
      final res = await ApiClient.getUnvalidated('/api/config/materiales');
      if (res.statusCode == 200) {
        final decoded = res.decodeJson();
        if (decoded is List) {
          materialesOficiales =
              decoded.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
        }
      }
    } catch (_) {}
    if (!mounted) return;

    final codigoCtrl = TextEditingController();
    final cantCtrl = TextEditingController();
    final obsCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final matSuggestCtrl = TextEditingController();
    String? procPrimario;
    String? procOpt1;
    String? procOpt2;
    String? procOpt3;
    final estado = <String, dynamic>{
      'inCatalog': null,
      'checking': false,
      'checkedCodigo': '',
    };
    Timer? debounce;

    Future<void> runCheck(void Function(void Function()) setD) async {
      final c = codigoCtrl.text.trim();
      if (c.isEmpty) {
        estado['inCatalog'] = null;
        estado['checkedCodigo'] = '';
        setD(() {});
        return;
      }
      estado['checking'] = true;
      setD(() {});
      final res = await ApiClient.getUnvalidated(
        '/api/catalog/pieza/${Uri.encodeComponent(c)}',
      );
      if (!context.mounted) return;
      estado['checking'] = false;
      estado['inCatalog'] = res.statusCode == 200;
      estado['checkedCodigo'] = c;
      setD(() {});
    }

    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setD) {
            final bool checking = estado['checking'] == true;
            final bool? inCat = estado['inCatalog'] as bool?;
            final String checked = estado['checkedCodigo'] as String;
            final String codeNow = codigoCtrl.text.trim();
            final bool stateApplies =
                checked.isNotEmpty && checked == codeNow;
            final String matTrim = matSuggestCtrl.text.trim();
            final bool matNoHomologado = matTrim.isNotEmpty &&
                !_materialHomologado(matTrim, materialesOficiales);

            return ContentDialog(
              title: const Text('Agregar Pieza'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InfoLabel(
                        label: 'Código de pieza',
                        child: TextBox(
                          controller: codigoCtrl,
                          placeholder: 'Catálogo o código nuevo',
                          onChanged: (_) {
                            estado['inCatalog'] = null;
                            estado['checkedCodigo'] = '';
                            debounce?.cancel();
                            debounce = Timer(
                              const Duration(milliseconds: 500),
                              () {
                                runCheck(setD);
                              },
                            );
                            setD(() {});
                          },
                        ),
                      ),
                      if (checking) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: ProgressRing(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Comprobando catálogo…',
                              style: TextStyle(
                                fontSize: 11,
                                color: FluentTheme.of(context)
                                    .typography
                                    .caption
                                    ?.color,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (stateApplies && inCat == true) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Pieza reconocida en el catálogo.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF1B5E20),
                          ),
                        ),
                      ],
                      if (stateApplies && inCat == false) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Esta pieza no está en el catálogo',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE65100),
                          ),
                        ),
                        const SizedBox(height: 12),
                        InfoLabel(
                          label: 'Descripción (obligatoria)',
                          child: TextBox(
                            controller: descCtrl,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 16,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        InfoLabel(
                          label: 'Material (obligatorio)',
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: AutoSuggestBox<String>(
                                  controller: matSuggestCtrl,
                                  placeholder:
                                      'Buscar en lista oficial o escribir…',
                                  items: materialesOficiales
                                      .map(
                                        (e) => AutoSuggestBoxItem<String>(
                                          value: e,
                                          label: e,
                                          child: Tooltip(
                                            message: e,
                                            child: Text(
                                              e,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onSelected: (_) => setD(() {}),
                                  onChanged: (_, __) => setD(() {}),
                                ),
                              ),
                              if (matNoHomologado) ...[
                                const SizedBox(width: 8),
                                Tooltip(
                                  message:
                                      'Material no homologado. Deberá estandarizarse luego.',
                                  child: Icon(
                                    FluentIcons.warning,
                                    size: 18,
                                    color: Colors.orange,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        InfoLabel(
                          label: 'Proceso primario (obligatorio)',
                          child: ComboBox<String?>(
                            placeholder: const Text('Seleccione de la lista oficial'),
                            value: procPrimario,
                            isExpanded: true,
                            items: _procesosOficialesAlta
                                .map(
                                  (e) => ComboBoxItem<String?>(
                                    value: e,
                                    child: Text(
                                      e,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setD(() => procPrimario = v),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InfoLabel(
                          label: 'Proceso adicional 1 (opcional)',
                          child: ComboBox<String?>(
                            placeholder: const Text('— Ninguno —'),
                            value: procOpt1,
                            isExpanded: true,
                            items: [
                              const ComboBoxItem<String?>(
                                value: null,
                                child: Text('— Ninguno —'),
                              ),
                              ..._procesosOficialesAlta.map(
                                (e) => ComboBoxItem<String?>(
                                  value: e,
                                  child: Text(
                                    e,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) => setD(() => procOpt1 = v),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InfoLabel(
                          label: 'Proceso adicional 2 (opcional)',
                          child: ComboBox<String?>(
                            placeholder: const Text('— Ninguno —'),
                            value: procOpt2,
                            isExpanded: true,
                            items: [
                              const ComboBoxItem<String?>(
                                value: null,
                                child: Text('— Ninguno —'),
                              ),
                              ..._procesosOficialesAlta.map(
                                (e) => ComboBoxItem<String?>(
                                  value: e,
                                  child: Text(
                                    e,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) => setD(() => procOpt2 = v),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InfoLabel(
                          label: 'Proceso adicional 3 (opcional)',
                          child: ComboBox<String?>(
                            placeholder: const Text('— Ninguno —'),
                            value: procOpt3,
                            isExpanded: true,
                            items: [
                              const ComboBoxItem<String?>(
                                value: null,
                                child: Text('— Ninguno —'),
                              ),
                              ..._procesosOficialesAlta.map(
                                (e) => ComboBoxItem<String?>(
                                  value: e,
                                  child: Text(
                                    e,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) => setD(() => procOpt3 = v),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      InfoLabel(
                        label: 'Cantidad',
                        child: TextBox(
                          controller: cantCtrl,
                          keyboardType: TextInputType.number,
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      InfoLabel(
                        label: 'Observaciones (BOM)',
                        child: TextBox(
                          controller: obsCtrl,
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                Button(
                  child: const Text('Cancelar'),
                  onPressed: () => Navigator.pop(dialogCtx),
                ),
                FilledButton(
                  child: const Text('Agregar'),
                  onPressed: () async {
                    final code = codigoCtrl.text.trim();
                    final cantStr = cantCtrl.text.trim();
                    if (code.isEmpty || cantStr.isEmpty) {
                      _showError('Código y cantidad son obligatorios.');
                      return;
                    }
                    final cant = double.tryParse(cantStr);
                    if (cant == null || cant <= 0) {
                      _showError('Cantidad inválida.');
                      return;
                    }
                    final String checkedNow =
                        estado['checkedCodigo'] as String;
                    final bool? inCatalogNow =
                        estado['inCatalog'] as bool?;
                    final bool appliesNow =
                        checkedNow.isNotEmpty && checkedNow == code;
                    if (inCatalogNow == null || !appliesNow) {
                      _showError(
                        'Espere a que termine la comprobación automática del código.',
                      );
                      return;
                    }
                    Map<String, dynamic>? maestro;
                    if (inCatalogNow == false) {
                      final d = descCtrl.text.trim();
                      final m = matSuggestCtrl.text.trim();
                      final p = procPrimario?.trim() ?? '';
                      if (d.isEmpty || m.isEmpty || p.isEmpty) {
                        _showError(
                          'Pieza nueva: complete descripción, material y proceso primario.',
                        );
                        return;
                      }
                      maestro = {
                        'descripcion': d,
                        'material': m,
                        'proceso_primario': p,
                        'proceso_1': procOpt1?.trim() ?? '',
                        'proceso_2': procOpt2?.trim() ?? '',
                        'proceso_3': procOpt3?.trim() ?? '',
                      };
                    }
                    Navigator.pop(dialogCtx);
                    await _addPieza(
                      code,
                      cant,
                      obsCtrl.text.trim(),
                      maestroRegistro: maestro,
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
      debounce?.cancel();
      codigoCtrl.dispose();
      cantCtrl.dispose();
      obsCtrl.dispose();
      descCtrl.dispose();
      matSuggestCtrl.dispose();
    });
  }

  void _confirmDelete(String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: const Text('Eliminar'),
            content: Text(title),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                style: ButtonStyle(
                  backgroundColor: ButtonState.all(Colors.red),
                ),
                child: const Text('Eliminar'),
                onPressed: () {
                  onConfirm();
                  Navigator.pop(context);
                },
              ),
            ],
          ),
    );
  }

  void _showVINManagementDialog() {
    if (_selectedRevision == null) return;
    String newVin = "";
    _fetchVINs();
    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              return ContentDialog(
                title: const Text("VINs Asignados - Gestión"),
                content: SizedBox(
                  width: 500,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextBox(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                              placeholder: "Nuevo VIN...",
                              onChanged: (v) => newVin = v,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            child: const Text("Agregar"),
                            onPressed: () {
                              if (newVin.trim().isNotEmpty) {
                                _addVIN(newVin.trim()).then((_) {
                                  setDialogState(() {});
                                });
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 400),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _vins.length,
                          itemBuilder: (context, index) {
                            final vin = _vins[index];
                            return ListTile(
                              title: Text(vin['vin']),
                              subtitle: Text(
                                vin['notas'] ?? "Sin notas",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(FluentIcons.edit_note),
                                    onPressed: () => _showNotasVINDialog(vin),
                                  ),
                                  IconButton(
                                    icon: const Icon(FluentIcons.delete),
                                    onPressed: () {
                                      _confirmDelete(
                                        "¿Seguro de eliminar el VIN ${vin['vin']}?",
                                        () {
                                          _deleteVIN(vin['id_unidad']).then((
                                            _,
                                          ) {
                                            setDialogState(() {});
                                          });
                                        },
                                      );
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  Button(
                    child: const Text("Cerrar"),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              );
            },
          ),
    );
  }

  void _showNotasVINDialog(dynamic vin) {
    String notasTemp = vin['notas'] ?? "";
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text("Notas del VIN: ${vin['vin']}"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextBox(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  controller: TextEditingController(text: notasTemp),
                  maxLines: 5,
                  placeholder: "Escribe notas aquí...",
                  onChanged: (v) => notasTemp = v,
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text("Cancelar"),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text("Guardar"),
                onPressed: () {
                  _updateVINNotas(vin['id_unidad'], notasTemp);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
    );
  }

  void _showClonarDialog() {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    final String revLabel =
        "Rev. ${_selectedRevision['numero_revision']} — ${_selectedRevision['estado']}";

    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 280),
        title: Row(
          children: [
            Icon(FluentIcons.copy, size: 18, color: _accentColor),
            const SizedBox(width: 8),
            const Text("Clonar Lista de Materiales"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "¿Deseas clonar esta Lista de Materiales?",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              "Se creará una copia exacta de $revLabel en estado Borrador, "
              "con todas sus estaciones, ensambles y piezas.",
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentColor.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(FluentIcons.info, size: 14, color: _accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "La nueva revisión se seleccionará automáticamente al finalizar.",
                      style: TextStyle(fontSize: 11, color: _accentColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Button(
            child: const Text("Cancelar"),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            child: const Text("Clonar Ahora"),
            onPressed: () {
              Navigator.pop(ctx);
              _clonarBOM();
            },
          ),
        ],
      ),
    );
  }

  // === AUDITORÍA DE PLANOS DXF/PDF ===

  /// Palabras clave de proceso que indican piezas que NO pasan por láser/punzonadora:
  /// - SIERRACINTA: corte con sierra de cinta (perfil estructural)
  /// - RECTO: corte recto / guillotina
  /// - COMERCIAL: compra directa, no se necesita plano de fabricación
  static const List<String> _procesosExcluidos = [
    'SIERRACINTA',
    'RECTO',
    'COMERCIAL',
  ];

  /// Catálogo cerrado para alta de pieza nueva (ComboBox en diálogo BOM).
  static const List<String> _procesosOficialesAlta = [
    'SIERRACINTA RECTO',
    'SIERRACINTA GRADOS',
    'TAILIFT',
    'LASER',
    'WATERJET',
    'DOBLEZ',
    'MAQUINADOS',
    'PUNZONADO',
    'COMERCIAL',
  ];

  bool _materialHomologado(String texto, List<String> oficiales) {
    final t = texto.trim().toUpperCase();
    if (t.isEmpty) return true;
    return oficiales.any((m) => m.toUpperCase() == t);
  }

  /// Devuelve true si la pieza debe omitirse del auditor de planos.
  bool _esPiezaSinPlano(Map<String, dynamic> row) {
    final String procesos =
        (row['procesos'] as String? ?? '').toUpperCase();
    final String material =
        (row['material'] as String? ?? '').toUpperCase();
    final String combinado = '$procesos|$material';
    return _procesosExcluidos.any((kw) => combinado.contains(kw));
  }

  Future<void> _buscarPlanos() async {
    final List<String> codigos = _bomPlana
        .where((r) => (r['nivel'] as num).toInt() == 3)
        .where((r) => !_esPiezaSinPlano(r))   // excluir corte recto, sierra, comercial
        .map<String>((r) => r['codigo_pieza']?.toString() ?? '')
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();

    if (codigos.isEmpty) {
      _showError("No hay piezas (Nivel 3) en la Vista Plana para auditar.");
      return;
    }

    // Pedir al usuario que elija la carpeta con los planos DXF/PDF
    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Selecciona la carpeta de Planos DXF/PDF',
    );
    if (selectedDirectory == null) return; // canceló el selector
    if (!mounted) return;

    setState(() => _isLoading = true);
    try {
      final username = await _prefsUsername();
      if (!mounted) return;
      final response = await ApiClient.postUnvalidated(
        '/api/bom/buscar_planos',
        headers: {'X-Usuario': username},
        body: {
          'codigos': codigos,
          'ruta_base': selectedDirectory,
        },
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = response.decodeJson() as Map<String, dynamic>;
        _showAuditoriaPlanosDialog(data);
      } else {
        _showError("Error al buscar planos: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) _showError("Error de conexión: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showAuditoriaPlanosDialog(Map<String, dynamic> data) {
    final List encontrados = data['encontrados'] as List? ?? [];
    final List faltantes = data['faltantes'] as List? ?? [];
    final String? advertencia = data['advertencia'] as String?;

    showDialog(
      context: context,
      builder: (ctx) {
        final typography = FluentTheme.of(ctx).typography;
        final Color bodyColor =
            typography.body?.color ?? Colors.black;
        final Color labelColor =
            typography.caption?.color ?? bodyColor.withOpacity(0.65);

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          title: Row(
            children: [
              Icon(FluentIcons.document_search, size: 18, color: _accentColor),
              const SizedBox(width: 8),
              const Text("Auditoría de Planos DXF / PDF"),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Banner de advertencia (ruta inexistente, permisos, etc.)
                if (advertencia != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.withOpacity(0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(FluentIcons.warning,
                            size: 14, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            advertencia,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.darker),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                // Resumen
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _accentColor.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _auditChip(
                        "${encontrados.length}",
                        "Encontrados",
                        const Color(0xFF2E7D32),
                        labelColor,
                      ),
                      _auditChip(
                        "${faltantes.length}",
                        "Faltantes",
                        Colors.red,
                        labelColor,
                      ),
                      _auditChip(
                        "${encontrados.length + faltantes.length}",
                        "Total",
                        _accentColor,
                        labelColor,
                      ),
                    ],
                  ),
                ),
                if (encontrados.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(FluentIcons.check_mark,
                          size: 14, color: Color(0xFF2E7D32)),
                      const SizedBox(width: 6),
                      Text("ENCONTRADOS (${encontrados.length})",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Color(0xFF2E7D32))),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ...encontrados.map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 2,
                              child: Text(
                                e['codigo']?.toString() ?? '',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                    color: bodyColor),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                e['archivo']?.toString() ?? '',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF388E3C)),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )),
                ],
                if (faltantes.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(FluentIcons.error_badge,
                          size: 14, color: Colors.red),
                      const SizedBox(width: 6),
                      Text("FALTANTES (${faltantes.length})",
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.red)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: faltantes
                        .map((c) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: Colors.red.withOpacity(0.4)),
                              ),
                              child: Text(
                                c.toString(),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.red.darker,
                                    fontWeight: FontWeight.w600),
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            Button(
              child: const Text("Cerrar"),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  Widget _auditChip(String valor, String label, Color color, Color labelColor) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          valor,
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: labelColor),
        ),
      ],
    );
  }
}
