import 'package:excel/excel.dart' as excel_lib;

class ExcelHelper {
  /// Limpia un valor para que sea un número puro (double) sin basura de texto.
  static double cleanToDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    
    String str = value.toString().replaceAll(',', '');
    // Elimina todo lo que no sea número o punto decimal
    str = str.replaceAll(RegExp(r'[^0-9.]'), '');
    
    return double.tryParse(str) ?? 0.0;
  }

  /// Limpia un valor para que sea un número entero (int).
  static int cleanToInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    
    String str = value.toString().replaceAll(',', '');
    str = str.replaceAll(RegExp(r'[^0-9]'), ''); // Solo números
    
    return int.tryParse(str) ?? 0;
  }

  /// Crea un estilo de cabecera profesional
  static excel_lib.CellStyle getHeaderStyle() {
    return excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#1E3A8A'), // Azul Oscuro Industrial
      fontColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),      // Color Blanco
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Center,
      verticalAlign: excel_lib.VerticalAlign.Center,
      // Usamos un borde sutil si es necesario
    );
  }

  /// Estilo para celdas de datos con bordes
  static excel_lib.CellStyle getDataStyle({bool isNumeric = false}) {
    return excel_lib.CellStyle(
      horizontalAlign: isNumeric ? excel_lib.HorizontalAlign.Right : excel_lib.HorizontalAlign.Left,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
  }

  /// Realiza el auto-ajuste de columnas basado en un mapa de anchos máximos.
  static void applyAutoFit(excel_lib.Sheet sheet, Map<int, int> maxColumnWidths) {
    maxColumnWidths.forEach((colIndex, maxLength) {
      // Aplicamos un margen de respiración (1.2x) y un mínimo de 10
      double width = (maxLength * 1.2).clamp(10.0, 50.0);
      sheet.setColumnWidth(colIndex, width);
    });
  }

  /// Actualiza el mapa de anchos máximos con el texto de una nueva celda
  static void updateMaxWith(Map<int, int> map, int colIndex, String? text) {
    if (text == null) return;
    int len = text.length;
    if (!map.containsKey(colIndex) || len > map[colIndex]!) {
      map[colIndex] = len;
    }
  }
  /// Parsea dinámicamente un valor para decidir si es DoubleCellValue o TextCellValue.
  /// Ideal para columnas mixtas como "Medida" o "Calibre".
  static excel_lib.CellValue parseDynamicCell(dynamic rawValue) {
    if (rawValue == null) return excel_lib.TextCellValue('');
    String strVal = rawValue.toString().trim();
    
    // 1. Eliminar apóstrofes accidentales iniciales
    if (strVal.startsWith("'")) strVal = strVal.substring(1);
    
    // 2. Intentar parseo numérico puro
    double? numVal = double.tryParse(strVal);
    if (numVal != null) {
      return excel_lib.DoubleCellValue(numVal); 
    }
    
    // 3. Fallback para texto puro (ej. "COMERCIAL")
    return excel_lib.TextCellValue(strVal);
  }
}
