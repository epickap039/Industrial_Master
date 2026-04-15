/// Breakpoints y medidas compartidas para ayudas visuales en tablet / ventana estrecha.
library;

const double kAyudasPdfTabletBreakpoint = 1120;
const double kAyudasPdfPhoneStackBreakpoint = 640;

bool ayudasPdfUseImmersiveChrome(double maxWidth) =>
    maxWidth < kAyudasPdfTabletBreakpoint;

bool ayudasPdfUseStackedTimeline(double maxWidth) =>
    maxWidth < kAyudasPdfPhoneStackBreakpoint;

double ayudasPdfTimelineHeight(double maxWidth) {
  if (maxWidth < 520) return 112;
  if (maxWidth < 720) return 136;
  if (maxWidth < kAyudasPdfTabletBreakpoint) return 164;
  return 220;
}

double ayudasPdfSidebarWidth(double maxWidth) =>
    maxWidth < 820 ? 212.0 : 280.0;

double ayudasPdfInitialZoom(double maxWidth) {
  if (!ayudasPdfUseImmersiveChrome(maxWidth)) return 1.0;
  if (maxWidth < 720) return 1.52;
  if (maxWidth < 900) return 1.42;
  return 1.34;
}

double ayudasPdfDualBarHeight(double maxWidth) =>
    ayudasPdfUseImmersiveChrome(maxWidth) ? 30.0 : 44.0;

/// Lobby: filas de acciones de ayudas en menú compacto (más acciones en un solo control).
bool ayudasLobbyAyudasCompacto(double screenWidth) => screenWidth < 920;
