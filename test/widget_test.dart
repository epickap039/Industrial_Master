import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_manager_v15_5/main.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp(isDarkMode: false));

    // Verify that the title is present (verifies app built successfully)
    expect(find.text('Inicio'), findsOneWidget); 
  });
}
