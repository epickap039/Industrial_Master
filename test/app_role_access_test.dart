import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_manager_v15_5/services/app_role.dart';

void main() {
  group('AppRole parsing and access', () {
    test('parseAppRole recognizes ingenieria/metodos aliases', () {
      expect(parseAppRole('INGENIERIA_METODOS'), AppRole.ingenieriaMetodos);
      expect(parseAppRole('METODOS'), AppRole.ingenieriaMetodos);
      expect(parseAppRole('Ingenieria'), AppRole.ingenieriaMetodos);
    });

    test('produccion has restricted catalog actions', () {
      const role = AppRole.produccion;
      expect(role.catalogCanExportExcel, isFalse);
      expect(role.catalogCanExportPdf, isFalse);
      expect(role.catalogCanSearchDxf, isFalse);
      expect(role.catalogCanSelectColumns, isFalse);
      expect(role.catalogHideDxfColumns, isTrue);
    });

    test('calidad can export catalog as pdf only', () {
      const role = AppRole.calidad;
      expect(role.catalogCanExportExcel, isFalse);
      expect(role.catalogCanExportPdf, isTrue);
      expect(role.catalogCanEditRows, isFalse);
      expect(role.catalogHideModificadoPor, isTrue);
      expect(role.catalogHideRutaArchivo, isTrue);
    });

    test('mapa de ingenieria is visible for calidad and produccion', () {
      expect(AppRole.calidad.showsNavMapaIngenieria, isTrue);
      expect(AppRole.produccion.showsNavMapaIngenieria, isTrue);
    });

    test('operational lobby enabled for selected roles', () {
      expect(AppRole.calidad.showsLobbyOperativoAyudasCatalogo, isTrue);
      expect(AppRole.ingenieriaMetodos.showsLobbyOperativoAyudasCatalogo, isTrue);
      expect(AppRole.produccion.showsLobbyOperativoAyudasCatalogo, isTrue);
      expect(AppRole.gestion.showsLobbyOperativoAyudasCatalogo, isFalse);
    });
  });
}
