import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  bool _isLoadingRevisions = true;
  bool _isLoadingData = false;
  List<dynamic> _revisionsList = [];
  dynamic _selectedRevisionId; // Cambiado a dynamic para soportar 'global'
  Map<String, dynamic>? _dashboardData;
  String? _errorMessage;

  final String _apiUrl = "http://192.168.1.73:8001";
  final _numFormat = NumberFormat('#,##0');

  @override
  void initState() {
    super.initState();
    _fetchRevisions();
  }

  Future<void> _fetchRevisions() async {
    try {
      final res = await http.get(Uri.parse('$_apiUrl/api/mapa/jerarquia'));
      
      // Lista base con la opción Global garantizada
      List<dynamic> safeRevisions = [
        {
          'id': 'global',
          'name': '🌎 ESTADÍSTICAS GLOBALES (Toda la base de datos)',
        }
      ];

      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        
        if (decoded is List) {
          for (var tracto in decoded) {
            String tractoName = tracto['nombre'] ?? '';
            final tipos = tracto['tipos'];
            if (tipos != null && tipos is List) {
              for (var tipo in tipos) {
                String tipoName = tipo['nombre'] ?? '';
                final versiones = tipo['versiones'];
                if (versiones != null && versiones is List) {
                  for (var version in versiones) {
                    final nombreVersion = version['nombre'] ?? '';
                    final revisiones = version['revisiones'];
                    if (revisiones != null && revisiones is List) {
                      for (var r in revisiones) {
                        final revId = r['id_revision']?.toString();
                        final revNum = r['numero_revision']?.toString() ?? '?';
                        final cliente = r['cliente']?.toString() ?? 'General';
                        if (revId != null) {
                          safeRevisions.add({
                            'id': revId,
                            'name': "$tractoName $tipoName ($cliente) - $nombreVersion REV $revNum",
                          });
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _revisionsList = safeRevisions;
          _selectedRevisionId = 'global'; // Valor por defecto
          _isLoadingRevisions = false;
        });
        _fetchDashboardData(); // Disparo automático de métricas globales
      }
    } catch (e) {
      debugPrint("Error fetching revisions: $e");
      // Fallback: Si la API falla, al menos dejamos el Dashboard en modo Global
      if (mounted) {
        setState(() {
          _revisionsList = [
            {'id': 'global', 'name': '🌎 ESTADÍSTICAS GLOBALES (Toda la base de datos)'}
          ];
          _selectedRevisionId = 'global';
          _isLoadingRevisions = false;
        });
        _fetchDashboardData();
      }
    }
  }

  Future<void> _fetchDashboardData() async {
    if (_selectedRevisionId == null) return;
    setState(() {
      _isLoadingData = true;
      _errorMessage = null;
    });

    try {
      final res = await http.get(Uri.parse('$_apiUrl/api/analytics/dashboard/$_selectedRevisionId'));
      if (res.statusCode == 200) {
        if (mounted) {
          setState(() {
            _dashboardData = json.decode(res.body);
            _isLoadingData = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = "Error del servidor: ${res.statusCode}";
            _isLoadingData = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = "Error de conexión: $e";
          _isLoadingData = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Dashboard Analytics - Control de Producción'),
        commandBar: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            _isLoadingRevisions
                ? const ProgressRing(strokeWidth: 2)
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 350),
                    child: ComboBox<dynamic>(
                      placeholder: const Text('Seleccionar Proyecto para Analizar'),
                      value: _selectedRevisionId,
                      items: _revisionsList.map((rev) {
                        return ComboBoxItem<dynamic>(
                          value: rev['id'],
                          child: Text(rev['name'] as String, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setState(() => _selectedRevisionId = val);
                        _fetchDashboardData();
                      },
                      isExpanded: true,
                    ),
                  ),
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _fetchDashboardData,
            ),
          ],
        ),
      ),
      content: _buildContent(isDark),
    );
  }

  Widget _buildContent(bool isDark) {
    if (_isLoadingData) return const Center(child: ProgressRing());
    if (_errorMessage != null) return Center(child: Text(_errorMessage!, style: TextStyle(color: Colors.red.darker)));
    if (_dashboardData == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.pie_single, size: 64, color: isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1)),
            const SizedBox(height: 15),
            const Text("Selecciona un proyecto arriba para generar el análisis visual."),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: ListView(
        children: [
          _buildKPICloud(isDark),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _buildBarChart(isDark)),
              const SizedBox(width: 24),
              Expanded(flex: 2, child: _buildPieChart(isDark)),
            ],
          ),
          const SizedBox(height: 24),
          _buildEnsambleChart(isDark),
        ],
      ),
    );
  }

  Widget _buildKPICloud(bool isDark) {
    final salud = _dashboardData!['salud_cad'];
    final total = salud['Validas'] + salud['Huerfanas'];
    final pct = total > 0 ? (salud['Validas'] / total * 100).toStringAsFixed(1) : "0";
    final sugerencia = _dashboardData!['sugerencia'] ?? "";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 24,
          alignment: WrapAlignment.spaceBetween,
          children: [
            _kpiCard(
              title: "Salud CAD",
              value: "$pct%",
              icon: FluentIcons.donut_chart,
              color: isDark ? Colors.blue.lighter : Colors.blue.darker,
              isDark: isDark,
            ),
            _kpiCard(
              title: "Total Piezas",
              value: "$total",
              icon: FluentIcons.database,
              color: isDark ? Colors.green.lighter : Colors.green.darker,
              isDark: isDark,
            ),
            _kpiCard(
              title: "Nesting Scrap",
              value: "15%",
              icon: FluentIcons.shopping_cart,
              color: isDark ? Colors.orange.lighter : Colors.orange.darker,
              isDark: isDark,
            ),
          ],
        ),
        if (sugerencia.isNotEmpty) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FluentTheme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: (isDark ? Colors.yellow.lighter : Colors.yellow.darker).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.lightbulb, color: isDark ? Colors.yellow.lighter : Colors.yellow.darker, size: 24),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    sugerencia,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.9)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _kpiCard({required String title, required String value, required IconData icon, required Color color, required bool isDark}) {
    return Container(
      width: 250,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 32, color: color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(fontSize: 13, color: isDark ? Colors.white.withValues(alpha: 0.6) : Colors.black.withValues(alpha: 0.6))),
                const SizedBox(height: 4),
                Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarChart(bool isDark) {
    final List<dynamic> top = _dashboardData!['top_piezas'];
    return Container(
      height: 450,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Top 10 Piezas Más Repetidas (BOM)", style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 30),
          Expanded(
            child: BarChart(
              BarChartData(
                alignment: BarChartAlignment.spaceAround,
                maxY: (top.isNotEmpty ? top[0]['Total_Piezas'] : 10) * 1.2,
                barTouchData: BarTouchData(
                  touchTooltipData: BarTouchTooltipData(
                    getTooltipColor: (_) => isDark ? Colors.grey[160] : Colors.grey[20],
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      return BarTooltipItem(
                        '${top[groupIndex]['Codigo_Pieza']}\n',
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        children: [
                          TextSpan(
                            text: '${rod.toY.toInt()} Piezas',
                            style: TextStyle(color: isDark ? Colors.blue.lighter : Colors.blue.darker),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (value, meta) {
                        int index = value.toInt();
                        if (index < 0 || index >= top.length) return const SizedBox();
                        String code = top[index]['Codigo_Pieza'];
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            code.length > 8 ? code.substring(0, 8) : code,
                            style: TextStyle(fontSize: 10, color: isDark ? Colors.white.withValues(alpha: 0.85) : Colors.black.withValues(alpha: 0.85)),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true, 
                      reservedSize: 50,
                      getTitlesWidget: (value, meta) => Text(_numFormat.format(value), style: const TextStyle(fontSize: 10)),
                    )
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 10, 
                  getDrawingHorizontalLine: (val) => FlLine(color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05), strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                barGroups: List.generate(top.length, (i) {
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: top[i]['Total_Piezas'].toDouble(),
                        color: Colors.blue,
                        width: 22,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPieChart(bool isDark) {
    final List<dynamic> dist = List.from(_dashboardData!['distribucion_material']);
    final colors = [Colors.blue, Colors.green, Colors.orange, Colors.red, Colors.magenta, Colors.teal, Colors.yellow, Colors.blue.darker];

    return Container(
      height: 450,
      padding: const EdgeInsets.only(top: 20, left: 20, bottom: 20, right: 60),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text("Distribución de Materiales (m²)", style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 30),
          Expanded(
            flex: 2,
            child: PieChart(
              PieChartData(
                sectionsSpace: 4,
                centerSpaceRadius: 50,
                sections: List.generate(dist.length > 8 ? 8 : dist.length, (i) {
                  final val = dist[i]['Total_m2'].toDouble();
                  return PieChartSectionData(
                    value: val,
                    title: '',
                    color: colors[i % colors.length],
                    radius: 70,
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            flex: 1,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(right: 15), // Evitar el scrollbar del Scaffold
              child: Column(
                children: List.generate(dist.length > 6 ? 6 : dist.length, (i) {
                  final val = dist[i]['Total_m2'].toDouble();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6.0),
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: colors[i % colors.length], shape: BoxShape.circle)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            dist[i]['Material'], 
                            overflow: TextOverflow.ellipsis, 
                            style: TextStyle(fontSize: 12, color: isDark ? Colors.white.withValues(alpha: 0.8) : Colors.black.withValues(alpha: 0.8))
                          )
                        ),
                        const SizedBox(width: 8),
                        Text('${val.toStringAsFixed(2)} m²', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnsambleChart(bool isDark) {
    if (!_dashboardData!.containsKey('distribucion_ensambles')) return const SizedBox.shrink();
    final List<dynamic> ens = _dashboardData!['distribucion_ensambles'];
    
    // Cálculo de máximo para escala dinámica
    double maxVal = 10.0;
    for (var item in ens) {
      double val = item['Total_Piezas'].toDouble();
      if (val > maxVal) maxVal = val;
    }
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Complejidad por Ensamble (Concentración de Piezas)", style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 32),
          SizedBox(
            height: 480, // Aumentado para dar espacio a etiquetas horizontales largas
            child: Padding(
              padding: const EdgeInsets.only(left: 140, right: 32, bottom: 20, top: 10),
              child: RotatedBox(
                quarterTurns: 1, // Rotación del widget completo para chart horizontal
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceEvenly,
                    maxY: maxVal * 1.15,
                    gridData: FlGridData(
                      show: true,
                      drawHorizontalLine: true,
                      drawVerticalLine: false,
                      horizontalInterval: maxVal / 5,
                      getDrawingHorizontalLine: (val) => FlLine(
                        color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05),
                        strokeWidth: 1,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      // Al rotar 1 cuarto (90 CW):
                      // bottomTitles (Original X) -> Aparece a la IZQUIERDA de la pantalla (Eje Y)
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 140,
                          getTitlesWidget: (value, meta) {
                            int idx = value.toInt();
                            if (idx < 0 || idx >= ens.length) return const SizedBox();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: RotatedBox(
                                quarterTurns: 3, // Contra-rotación para que el texto sea horizontal en pantalla
                                child: Text(
                                  ens[idx]['Ensamble'],
                                  style: TextStyle(fontSize: 10, color: isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black.withValues(alpha: 0.9)),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.end,
                                ),
                              ),
                            );
                          }
                        )
                      ),
                      // leftTitles (Original Y) -> Aparece en la parte SUPERIOR.
                      // Lo desactivamos y usamos rightTitles para que los números aparezcan abajo.
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true, 
                          reservedSize: 40,
                          interval: maxVal / 5,
                          getTitlesWidget: (value, meta) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: RotatedBox(
                                quarterTurns: 3, // Contra-rotación para números horizontales
                                child: Text(
                                  _numFormat.format(value), 
                                  style: const TextStyle(fontSize: 9)
                                ),
                              ),
                            );
                          }
                        )
                      ),
                    ),
                    barGroups: List.generate(ens.length, (i) {
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: ens[i]['Total_Piezas'].toDouble(),
                            color: Colors.orange,
                            width: 24, // Grosor ajustado para lectura horizontal
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          )
                        ]
                      );
                    }),
                  )
                ),
              ),
            )
          )
        ],
      ),
    );
  }
}
