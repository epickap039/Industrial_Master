import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Datos crudos para un informe mensual del Centro de Monitoreo.
/// La UI del panel de estadísticas arma este payload y lo pasa al generador.
/// Grupo lista rapida: pendientes activos bajo un responsable (titulo una vez si multi-asignado).
class MonitoreoInformePendientesUsuario {
  MonitoreoInformePendientesUsuario({
    required this.usuario,
    required this.lineas,
  });

  final String usuario;
  final List<String> lineas;
}

class MonitoreoInformeMensualPayload {
  MonitoreoInformeMensualPayload({
    required this.mes,
    required this.generadoPor,
    required this.rolGeneradoPor,
    required this.kpis,
    required this.responsables,
    required this.resumenTextual,
    required this.graficas,
    this.historialTotalMisiones = 0,
    this.historialCerradasConFecha = 0,
    this.pendientesLista = const [],
  });

  /// Primer día del mes reportado (local).
  final DateTime mes;
  final String generadoPor;
  final String rolGeneradoPor;

  /// Pares `titulo -> valor` para la sección de KPIs.
  final List<({String titulo, String valor, String? pie})> kpis;

  /// Filas para la tabla resumen por responsable.
  final List<MonitoreoInformeFilaResponsable> responsables;

  /// Texto corto (4-6 lineas) a modo de resumen ejecutivo generado por el panel.
  final List<String> resumenTextual;

  /// Gráficas ya capturadas como PNG en memoria (título + bytes).
  final List<MonitoreoInformeGrafica> graficas;

  /// Misiones visibles en la bitacora (todo el historial cargado en pantalla).
  final int historialTotalMisiones;

  /// Con fecha de cierre registrada (terminadas o canceladas), mismo alcance cargado.
  final int historialCerradasConFecha;

  /// Activas sin cierre: lista breve por usuario (mision multi-asignada una sola vez, bajo asignado principal).
  final List<MonitoreoInformePendientesUsuario> pendientesLista;
}

class MonitoreoInformeFilaResponsable {
  MonitoreoInformeFilaResponsable({
    required this.usuario,
    required this.creadas,
    required this.cerradas,
    required this.canceladas,
    required this.activasFinMes,
    required this.leadTimeHorasProm,
    this.misionesCerradasMes = const [],
    this.finEstimadoLaboral = '-',
  });

  final String usuario;
  final int creadas;
  final int cerradas;
  final int canceladas;
  final int activasFinMes;
  final double leadTimeHorasProm;

  /// Titulos de misiones cerradas (no canceladas) en el mes, orden de captura.
  final List<String> misionesCerradasMes;

  /// Etiqueta tipo "lun 5 abr 16:30" si hay minutos estimados pendientes en activas.
  final String finEstimadoLaboral;
}

class MonitoreoInformeGrafica {
  MonitoreoInformeGrafica({
    required this.titulo,
    required this.descripcion,
    required this.imagenPng,
  });

  final String titulo;
  final String descripcion;
  final Uint8List imagenPng;
}

/// Captura un widget marcado con [RepaintBoundary] + [GlobalKey] y devuelve PNG.
///
/// Si el layout aún no terminó o el contexto se desmontó, devuelve null.
Future<Uint8List?> capturaRepaintBoundaryPng(
  GlobalKey key, {
  double pixelRatio = 2.6,
}) async {
  try {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    // Esperar dos frames para asegurar que fl_chart animó y pintó.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    final ui.Image image = await ro.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return null;
    return bytes.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Genera el PDF y lo abre con la app asociada (open_file).
/// Retorna la ruta del archivo final, o null si se cancela.
Future<String?> generarInformeMensualMonitoreoPdf(
  MonitoreoInformeMensualPayload data,
) async {
  final doc = pw.Document(
    title: 'Informe mensual Centro de Monitoreo',
    author: data.generadoPor,
    creator: 'Industrial Manager',
  );

  Uint8List? logoBytes;
  try {
    final bd = await rootBundle.load('assets/app_icon.png');
    logoBytes = bd.buffer.asUint8List();
  } catch (_) {
    logoBytes = null;
  }

  final theme = pw.ThemeData.withFont(
    base: pw.Font.helvetica(),
    bold: pw.Font.helveticaBold(),
    italic: pw.Font.helveticaOblique(),
    boldItalic: pw.Font.helveticaBoldOblique(),
  );

  try {
    await initializeDateFormatting('es_ES', null);
  } catch (_) {}
  final nfMes = DateFormat('MMMM yyyy', 'es_ES');
  final nfFecha = DateFormat('yyyy-MM-dd HH:mm');
  final tituloMes = _capitalizar(nfMes.format(data.mes));

  const azulHeader = PdfColor.fromInt(0xFF0B3D6E);
  const azulCelda = PdfColor.fromInt(0xFFEAF1F9);
  const grisSuave = PdfColor.fromInt(0xFFF4F5F7);
  const grisBorde = PdfColor.fromInt(0xFFD8DCE2);
  const textoTenue = PdfColor.fromInt(0xFF4A5463);

  /// Helvetica no dibuja bien em-dash, puntos medios ni comillas tipograficas.
  String asciiPdf(String s) {
    return s
        .replaceAll('\u2014', '-') // em dash
        .replaceAll('\u2013', '-') // en dash
        .replaceAll('\u00B7', '-') // middle dot
        .replaceAll('\u2212', '-') // minus
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'");
  }

  pw.Widget encabezado(pw.Context ctx) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: azulHeader, width: 1.4),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          if (logoBytes != null)
            pw.Container(
              width: 30,
              height: 30,
              margin: const pw.EdgeInsets.only(right: 10),
              child: pw.Image(pw.MemoryImage(logoBytes)),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  asciiPdf('Centro de Monitoreo - Informe mensual'),
                  style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    color: azulHeader,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'Periodo: $tituloMes',
                  style: pw.TextStyle(fontSize: 10, color: textoTenue),
                ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'Generado: ${nfFecha.format(DateTime.now())}',
                style: pw.TextStyle(fontSize: 9, color: textoTenue),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                asciiPdf('Por: ${data.generadoPor} (${data.rolGeneradoPor})'),
                style: pw.TextStyle(fontSize: 9, color: textoTenue),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget piePagina(pw.Context ctx) {
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: grisBorde, width: 0.8),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            asciiPdf('Industrial Manager - uso interno'),
            style: pw.TextStyle(fontSize: 8, color: textoTenue),
          ),
          pw.Text(
            'Página ${ctx.pageNumber} de ${ctx.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: textoTenue),
          ),
        ],
      ),
    );
  }

  pw.Widget kpiTile(({String titulo, String valor, String? pie}) k) {
    return pw.Container(
      height: 58,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: azulCelda,
        border: pw.Border.all(color: grisBorde, width: 0.6),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            asciiPdf(k.titulo),
            style: pw.TextStyle(
              fontSize: 8.5,
              color: textoTenue,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            asciiPdf(k.valor),
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
              color: azulHeader,
            ),
          ),
          if (k.pie != null && k.pie!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              asciiPdf(k.pie!),
              style: pw.TextStyle(fontSize: 7.5, color: textoTenue),
            ),
          ],
        ],
      ),
    );
  }

  pw.Widget grafica(MonitoreoInformeGrafica g) {
    return pw.Container(
      width: double.infinity,
      alignment: pw.Alignment.center,
      child: pw.Container(
        padding: const pw.EdgeInsets.all(8),
        margin: const pw.EdgeInsets.only(bottom: 10),
        decoration: pw.BoxDecoration(
          color: grisSuave,
          border: pw.Border.all(color: grisBorde, width: 0.6),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              asciiPdf(g.titulo),
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 10.5,
                fontWeight: pw.FontWeight.bold,
                color: azulHeader,
              ),
            ),
            if (g.descripcion.isNotEmpty) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                asciiPdf(g.descripcion),
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 8.5, color: textoTenue),
              ),
            ],
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.ClipRRect(
                horizontalRadius: 4,
                verticalRadius: 4,
                child: pw.Image(
                  pw.MemoryImage(g.imagenPng),
                  fit: pw.BoxFit.contain,
                  height: 168,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget tablaResponsables() {
    if (data.responsables.isEmpty) {
      return pw.Text(
        'Sin actividad registrada por responsable en el periodo.',
        style: pw.TextStyle(fontSize: 9.5, color: textoTenue),
      );
    }
    final headers = const [
      'Responsable',
      'Creadas',
      'Cerradas',
      'Canceladas',
      'Activas fin',
      'Lead time prom. (h)',
      'Fin est. laboral',
    ];
    final rows = data.responsables.map((r) {
      return [
        asciiPdf(r.usuario),
        r.creadas.toString(),
        r.cerradas.toString(),
        r.canceladas.toString(),
        r.activasFinMes.toString(),
        r.leadTimeHorasProm.isNaN
            ? '-'
            : r.leadTimeHorasProm.toStringAsFixed(1),
        asciiPdf(r.finEstimadoLaboral),
      ];
    }).toList();

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      border: pw.TableBorder.all(color: grisBorde, width: 0.5),
      headerStyle: pw.TextStyle(
        fontSize: 8.5,
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
      ),
      headerDecoration: const pw.BoxDecoration(color: azulHeader),
      cellStyle: const pw.TextStyle(fontSize: 8.5),
      cellAlignments: {
        0: pw.Alignment.centerLeft,
        1: pw.Alignment.center,
        2: pw.Alignment.center,
        3: pw.Alignment.center,
        4: pw.Alignment.center,
        5: pw.Alignment.centerRight,
        6: pw.Alignment.centerLeft,
      },
      rowDecoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: grisBorde, width: 0.3),
        ),
      ),
      oddRowDecoration: const pw.BoxDecoration(color: grisSuave),
      headerAlignment: pw.Alignment.center,
    );
  }

  pw.Widget cajaAlcanceHistorial() {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: azulCelda,
        border: pw.Border.all(color: grisBorde, width: 0.6),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            asciiPdf('Alcance del historial cargado en pantalla'),
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: azulHeader,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            asciiPdf(
              'Todo el tiempo: ${data.historialTotalMisiones} mision(es) en la bitacora; '
              '${data.historialCerradasConFecha} con fecha de cierre registrada.',
            ),
            style: pw.TextStyle(fontSize: 9, color: textoTenue),
          ),
        ],
      ),
    );
  }

  pw.Widget tituloSeccion(String txt) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 6),
      child: pw.Row(
        children: [
          pw.Container(
            width: 4,
            height: 14,
            color: azulHeader,
            margin: const pw.EdgeInsets.only(right: 6),
          ),
          pw.Text(
            asciiPdf(txt),
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
              color: azulHeader,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget listaMisionesCerradasMes() {
    final conLista =
        data.responsables.where((r) => r.misionesCerradasMes.isNotEmpty).toList()
          ..sort((a, b) => b.cerradas.compareTo(a.cerradas));
    if (conLista.isEmpty) {
      return pw.SizedBox();
    }
    const maxPorUsuario = 16;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        tituloSeccion('Misiones cerradas en el mes (lista breve)'),
        pw.Text(
          asciiPdf(
            'Titulos de misiones no canceladas, cerradas en el mes del informe, '
            'agrupadas por quien figura en el cierre.',
          ),
          style: pw.TextStyle(fontSize: 8.5, color: textoTenue),
        ),
        pw.SizedBox(height: 6),
        for (final r in conLista) ...[
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6, bottom: 2),
            child: pw.Text(
              asciiPdf('${r.usuario} (${r.cerradas} cierre(s) en tabla)'),
              style: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
                color: azulHeader,
              ),
            ),
          ),
          for (final m in r.misionesCerradasMes.take(maxPorUsuario))
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 8, bottom: 1.5),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(
                    width: 3,
                    height: 3,
                    margin: const pw.EdgeInsets.only(top: 3.5, right: 5),
                    decoration: const pw.BoxDecoration(
                      color: azulHeader,
                      shape: pw.BoxShape.circle,
                    ),
                  ),
                  pw.Expanded(
                    child: pw.Text(
                      asciiPdf(m),
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                  ),
                ],
              ),
            ),
          if (r.misionesCerradasMes.length > maxPorUsuario)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 16, bottom: 4),
              child: pw.Text(
                asciiPdf(
                  '... y ${r.misionesCerradasMes.length - maxPorUsuario} mas',
                ),
                style: pw.TextStyle(
                  fontSize: 8,
                  color: textoTenue,
                  fontStyle: pw.FontStyle.italic,
                ),
              ),
            ),
        ],
      ],
    );
  }

  pw.Widget listaMisionesPendientesActivas() {
    if (data.pendientesLista.isEmpty) {
      return pw.SizedBox();
    }
    const maxPorUsuario = 20;
    final ordenados = [...data.pendientesLista]
      ..sort(
        (a, b) => a.usuario.toLowerCase().compareTo(b.usuario.toLowerCase()),
      );
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        tituloSeccion('Misiones pendientes (lista breve)'),
        pw.Text(
          asciiPdf(
            'Activas sin cierre en el panel. Si hay varios responsables, '
            'el titulo aparece una sola vez bajo el asignado principal, con la lista de responsables.',
          ),
          style: pw.TextStyle(fontSize: 8.5, color: textoTenue),
        ),
        pw.SizedBox(height: 6),
        for (final g in ordenados)
          if (g.lineas.isNotEmpty) ...[
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6, bottom: 2),
              child: pw.Text(
                asciiPdf(g.usuario),
                style: pw.TextStyle(
                  fontSize: 9.5,
                  fontWeight: pw.FontWeight.bold,
                  color: azulHeader,
                ),
              ),
            ),
            for (final m in g.lineas.take(maxPorUsuario))
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8, bottom: 1.5),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      width: 3,
                      height: 3,
                      margin: const pw.EdgeInsets.only(top: 3.5, right: 5),
                      decoration: const pw.BoxDecoration(
                        color: azulHeader,
                        shape: pw.BoxShape.circle,
                      ),
                    ),
                    pw.Expanded(
                      child: pw.Text(
                        asciiPdf(m),
                        style: const pw.TextStyle(fontSize: 8.5),
                      ),
                    ),
                  ],
                ),
              ),
            if (g.lineas.length > maxPorUsuario)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 16, bottom: 4),
                child: pw.Text(
                  asciiPdf(
                    '... y ${g.lineas.length - maxPorUsuario} mas',
                  ),
                  style: pw.TextStyle(
                    fontSize: 8,
                    color: textoTenue,
                    fontStyle: pw.FontStyle.italic,
                  ),
                ),
              ),
          ],
      ],
    );
  }

  final pageTheme = pw.PageTheme(
    pageFormat: PdfPageFormat.a4.copyWith(
      marginLeft: 36,
      marginRight: 36,
      marginTop: 48,
      marginBottom: 42,
    ),
    theme: theme,
    buildBackground: (ctx) => pw.SizedBox.expand(),
  );

  doc.addPage(
    pw.MultiPage(
      pageTheme: pageTheme,
      header: encabezado,
      footer: piePagina,
      build: (ctx) {
        final kpisRows = <pw.Widget>[];
        for (var i = 0; i < data.kpis.length; i += 4) {
          final slice = data.kpis.sublist(
            i,
            (i + 4).clamp(0, data.kpis.length),
          );
          kpisRows.add(
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < slice.length; j++) ...[
                  pw.Expanded(child: kpiTile(slice[j])),
                  if (j < slice.length - 1) pw.SizedBox(width: 6),
                ],
              ],
            ),
          );
          kpisRows.add(pw.SizedBox(height: 6));
        }

        return [
          tituloSeccion('Resumen ejecutivo'),
          if (data.resumenTextual.isEmpty)
            pw.Text(
              'Sin comentarios adicionales.',
              style: pw.TextStyle(fontSize: 9.5, color: textoTenue),
            )
          else
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final linea in data.resumenTextual)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 2),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          width: 3,
                          height: 3,
                          margin: const pw.EdgeInsets.only(top: 4, right: 5),
                          decoration: const pw.BoxDecoration(
                            color: azulHeader,
                            shape: pw.BoxShape.circle,
                          ),
                        ),
                        pw.Expanded(
                          child: pw.Text(
                            asciiPdf(linea),
                            style: const pw.TextStyle(fontSize: 9.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          pw.SizedBox(height: 10),
          cajaAlcanceHistorial(),
          pw.SizedBox(height: 12),
          tituloSeccion('Indicadores clave (KPIs)'),
          ...kpisRows,
          pw.SizedBox(height: 6),
          tituloSeccion('Gráficas mensuales'),
          // Salto de pagina si no cabe ~una grafica completa (titulo + imagen centrada).
          for (final g in data.graficas) ...[
            pw.NewPage(freeSpace: 230),
            grafica(g),
          ],
          pw.SizedBox(height: 6),
          tituloSeccion('Resumen por responsable'),
          tablaResponsables(),
          listaMisionesCerradasMes(),
          listaMisionesPendientesActivas(),
          pw.SizedBox(height: 10),
          pw.Text(
            asciiPdf(
              'Este informe se genera a partir de las misiones registradas '
              'en el Centro de Monitoreo (misiones manuales y del Radar de '
              'impacto). Las cifras consideran solo misiones visibles para el '
              'rol actual y cierres con fecha dentro del periodo indicado.',
            ),
            style: pw.TextStyle(
              fontSize: 8.5,
              color: textoTenue,
              fontStyle: pw.FontStyle.italic,
            ),
          ),
        ];
      },
    ),
  );

  final bytes = await doc.save();
  // Windows: carpeta "Documentos" del usuario (getApplicationDocumentsDirectory).
  // Archivo: informe_monitoreo_YYYY_MM.pdf (o _1, _2... si ya existe).
  final dir = await getApplicationDocumentsDirectory();
  final slug = DateFormat('yyyy_MM').format(data.mes);
  final rutaBase =
      '${dir.path}${Platform.pathSeparator}informe_monitoreo_$slug';
  var ruta = '$rutaBase.pdf';
  var i = 1;
  while (await File(ruta).exists()) {
    ruta = '${rutaBase}_$i.pdf';
    i++;
    if (i > 50) break;
  }
  final file = File(ruta);
  await file.writeAsBytes(bytes, flush: true);
  try {
    await OpenFile.open(ruta);
  } catch (_) {}
  return ruta;
}

String _capitalizar(String s) {
  if (s.isEmpty) return s;
  return '${s[0].toUpperCase()}${s.substring(1)}';
}
