import 'package:fluent_ui/fluent_ui.dart';

import '../../theme/ui_tokens.dart';
import 'crimp_profile.dart';

/// Referencia de crimpado: carrusel de fichas locales (assets) para operación/calidad.
class GuiaCrimpadoScreen extends StatefulWidget {
  const GuiaCrimpadoScreen({super.key});

  @override
  State<GuiaCrimpadoScreen> createState() => _GuiaCrimpadoScreenState();
}

class _GuiaCrimpadoScreenState extends State<GuiaCrimpadoScreen> {
  late final PageController _profileController;
  List<CrimpProfile> _profiles = const [];
  bool _loading = true;
  Object? _loadError;
  int _profileIndex = 0;

  @override
  void initState() {
    super.initState();
    _profileController = PageController();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final list = await CrimpProfile.loadFromAssets();
      if (!mounted) return;
      setState(() {
        _profiles = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _profileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    if (_loading) {
      return const Center(child: ProgressRing());
    }
    if (_loadError != null) {
      return Padding(
        padding: pagePadding(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InfoBar(
              title: const Text('No se pudieron cargar las fichas'),
              content: Text('$_loadError'),
              severity: InfoBarSeverity.error,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (_profiles.isEmpty) {
      return Padding(
        padding: pagePadding(),
        child: Center(
          child: Text(
            'Sin perfiles de crimpado en assets/guia_crimpado/profiles.json',
            style: TextStyle(color: palette.textSecondary, fontSize: 16),
          ),
        ),
      );
    }

    final n = _profiles.length;
    final idx = _profileIndex.clamp(0, n - 1);

    return Padding(
      padding: pagePadding(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Guía de crimpado',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              Text(
                '${idx + 1} / $n',
                style: TextStyle(
                  fontSize: 14,
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(FluentIcons.chevron_left, size: 18),
                onPressed: idx > 0
                    ? () {
                        _profileController.previousPage(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    : null,
              ),
              IconButton(
                icon: const Icon(FluentIcons.chevron_right, size: 18),
                onPressed: idx < n - 1
                    ? () {
                        _profileController.nextPage(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: PageView.builder(
              controller: _profileController,
              itemCount: n,
              onPageChanged: (i) => setState(() => _profileIndex = i),
              itemBuilder: (context, i) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _CrimpProfileBody(profile: _profiles[i], palette: palette),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CrimpProfileBody extends StatefulWidget {
  const _CrimpProfileBody({
    required this.profile,
    required this.palette,
  });

  final CrimpProfile profile;
  final UiSurfacePalette palette;

  @override
  State<_CrimpProfileBody> createState() => _CrimpProfileBodyState();
}

class _CrimpProfileBodyState extends State<_CrimpProfileBody> {
  int _displayIdx = 0;

  @override
  void didUpdateWidget(covariant _CrimpProfileBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id) {
      _displayIdx = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final palette = widget.palette;
    final theme = FluentTheme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 920;

    final imgs = p.imagenesPantalla;
    final displayIdx =
        imgs.isEmpty ? 0 : _displayIdx.clamp(0, imgs.length - 1);

    final heroStyle = TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w800,
      height: 1.05,
      color: palette.textPrimary,
    );

    Widget diagramCard() {
      final path = p.imagenConexion;
      return Container(
        constraints: BoxConstraints(
          maxHeight: wide ? 360 : 280,
          minHeight: 160,
        ),
        decoration: BoxDecoration(
          color: palette.surfaceCard,
          borderRadius: BorderRadius.circular(UiTokens.cardRadius * 1.25),
          border: Border.all(color: palette.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: path == null
            ? Center(
                child: Icon(
                  FluentIcons.photo2,
                  size: 64,
                  color: palette.textSecondary.withValues(alpha: 0.45),
                ),
              )
            : Image.asset(
                path,
                fit: BoxFit.contain,
                width: double.infinity,
              ),
      );
    }

    Widget heroCard() {
      final v = p.diametroExteriorDespuesMm;
      final tol = p.toleranciaExterior;
      const label = 'Diámetro exterior después del crimpado (mm)';
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: theme.accentColor
              .withValues(alpha: theme.brightness == Brightness.dark ? 0.18 : 0.12),
          borderRadius: BorderRadius.circular(UiTokens.cardRadius * 1.25),
          border: Border.all(
            color: theme.accentColor.withValues(alpha: 0.45),
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: palette.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              v ?? '—',
              style: heroStyle,
            ),
            if (tol != null) ...[
              const SizedBox(height: 4),
              Text(
                tol,
                style: TextStyle(
                  fontSize: 15,
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      );
    }

    Widget sectionTitle(String t) => Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            t,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: palette.textSecondary,
            ),
          ),
        );

    Widget kv(String k, String? v, {bool danger = false}) {
      if (v == null || v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: wide ? 200 : 140,
              child: Text(
                k,
                style: TextStyle(
                  fontSize: 13.5,
                  color: palette.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Expanded(
              child: danger
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: palette.actionDanger.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                        border:
                            Border.all(color: palette.actionDanger.withValues(alpha: 0.55)),
                      ),
                      child: Text(
                        v,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: palette.actionDanger,
                        ),
                      ),
                    )
                  : Text(
                      v,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
      );
    }

    final topeDanger = p.topeResaltarNoAplica;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          p.nombre,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        heroCard(),
        sectionTitle('Identificación'),
        kv('Tipo de conexión', p.tipoConexion),
        kv('Código de conjunto', p.codigoConjunto),
        kv('SKU', p.sku),
        sectionTitle('Conjunto manguera'),
        kv('Manguera hidráulica', p.manguera),
        kv('Tipo de malla', p.tipoMalla),
        kv('Marca / proveedor', p.marcaProveedor),
        sectionTitle('Mediciones (exterior)'),
        kv('Diámetro antes del crimpado (mm)', p.diametroExteriorAntesMm),
        sectionTitle('Presión y tope'),
        kv('Rango de presión (bar)', p.presionRangoBar),
        kv('Uso de tope (mm)', p.topeMm, danger: topeDanger),
        sectionTitle('Caudal interno'),
        kv(
          'Caudal interno después (mm)',
          p.caudalInternoDespuesMm == null
              ? null
              : p.toleranciaCaudalInterno != null
                  ? '${p.caudalInternoDespuesMm} (${p.toleranciaCaudalInterno})'
                  : p.caudalInternoDespuesMm,
        ),
        sectionTitle('Equipo y herramental'),
        kv('Tipo de matriz', p.tipoMatriz),
        kv('Tipo de máquina', p.tipoMaquina),
        sectionTitle('Interfaz del display'),
        if (imgs.isEmpty)
          Text(
            'Sin imagen de pantalla en datos.',
            style: TextStyle(color: palette.textSecondary, fontSize: 13),
          )
        else ...[
          Row(
            children: [
              if (imgs.length > 1) ...[
                IconButton(
                  icon: const Icon(FluentIcons.chevron_left, size: 16),
                  onPressed: displayIdx > 0 ? () => setState(() => _displayIdx--) : null,
                ),
              ],
              Expanded(
                child: Text(
                  imgs[displayIdx].etiqueta ?? 'Pantalla ${displayIdx + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
              if (imgs.length > 1) ...[
                IconButton(
                  icon: const Icon(FluentIcons.chevron_right, size: 16),
                  onPressed: displayIdx < imgs.length - 1
                      ? () => setState(() => _displayIdx++)
                      : null,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 280,
            decoration: BoxDecoration(
              color: palette.surfaceCard,
              borderRadius: BorderRadius.circular(UiTokens.cardRadius),
              border: Border.all(color: palette.borderSubtle),
            ),
            clipBehavior: Clip.antiAlias,
            child: InteractiveViewer(
              panEnabled: true,
              boundaryMargin: const EdgeInsets.all(64),
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: Image.asset(
                  imgs[displayIdx].asset,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Acercar: gesto o rueda; arrastrar para mover.',
            style: TextStyle(
              fontSize: 11.5,
              color: palette.textSecondary.withValues(alpha: 0.85),
            ),
          ),
        ],
        if (p.justificacion?.hasAny == true) ...[
          sectionTitle('Justificación y notas'),
          Expander(
            header: const Text('Ver texto de justificación y trazabilidad'),
            content: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.justificacion!.referenciaDocumento != null ||
                      p.justificacion!.versionTabla != null ||
                      p.justificacion!.fechaVigencia != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (p.justificacion!.referenciaDocumento != null)
                            _chip(
                              'Doc: ${p.justificacion!.referenciaDocumento}',
                              palette,
                            ),
                          if (p.justificacion!.versionTabla != null)
                            _chip(
                              'Tabla: ${p.justificacion!.versionTabla}',
                              palette,
                            ),
                          if (p.justificacion!.fechaVigencia != null)
                            _chip(
                              'Vigencia: ${p.justificacion!.fechaVigencia}',
                              palette,
                            ),
                        ],
                      ),
                    ),
                  if (p.justificacion!.comentarios != null)
                    SelectableText(
                      p.justificacion!.comentarios!,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: palette.textPrimary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );

    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                diagramCard(),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 7,
            child: details,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        diagramCard(),
        const SizedBox(height: 16),
        details,
      ],
    );
  }

  Widget _chip(String text, UiSurfacePalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: palette.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
