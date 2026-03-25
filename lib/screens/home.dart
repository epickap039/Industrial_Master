import 'package:fluent_ui/fluent_ui.dart';
import '../widgets/compact_page_header.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Inicio',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      content: const Center(child: Text('Dashboard Placeholder')),
    );
  }
}
