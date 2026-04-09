import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:industrial_manager_v15_5/main.dart';

void main() {
  testWidgets('App boots and shows initial shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    // Smoke: la app monta correctamente y renderiza pantalla inicial.
    expect(find.byType(FluentApp), findsOneWidget);
  });
}
