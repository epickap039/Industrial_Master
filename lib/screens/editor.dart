import 'package:fluent_ui/fluent_ui.dart';

class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScaffoldPage(
      header: PageHeader(title: Text('Editor de Datos')),
      content: Center(child: Text('CRUD Placeholder')),
    );
  }
}
