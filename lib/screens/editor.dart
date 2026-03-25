import 'package:fluent_ui/fluent_ui.dart';
import '../widgets/compact_page_header.dart';

class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Editor de Datos',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      content: const Center(child: Text('CRUD Placeholder')),
    );
  }
}
