/// Color picker dialog para asignación de colores a usuarios.
///
/// MEJORA INTEGRAL v15.5: Permite que usuarios seleccionen su color
/// personal que aparecerá en tickets, calendario y estadísticas.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import '../../theme/app_themes.dart';

/// Diálogo interactivo para seleccionar color de usuario
Future<String?> showUserColorPickerDialog(
  BuildContext context, {
  required String currentHex,
  required Function(String hexColor) onColorSelected,
}) async {
  return showDialog<String?>(
    context: context,
    builder: (BuildContext ctx) {
      return UserColorPickerDialogContent(
        currentHex: currentHex,
        onColorSelected: onColorSelected,
      );
    },
  );
}

class UserColorPickerDialogContent extends StatefulWidget {
  final String currentHex;
  final Function(String hexColor) onColorSelected;

  const UserColorPickerDialogContent({
    super.key,
    required this.currentHex,
    required this.onColorSelected,
  });

  @override
  State<UserColorPickerDialogContent> createState() =>
      _UserColorPickerDialogContentState();
}

class _UserColorPickerDialogContentState
    extends State<UserColorPickerDialogContent> {
  late String selectedHex;
  late int selectedIndex;

  @override
  void initState() {
    super.initState();
    selectedHex = widget.currentHex;
    // Encontrar índice del color actual
    selectedIndex = UserColorPalette.userColorsHex.indexWhere(
      (hex) => hex.toUpperCase() == widget.currentHex.toUpperCase(),
    );
    if (selectedIndex < 0) selectedIndex = 0;
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: const Text('Selecciona tu color'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Preview del color seleccionado
            Container(
              height: 80,
              width: double.infinity,
              decoration: BoxDecoration(
                color: UserColorPalette.getColorByIndex(selectedIndex),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.24),
                  width: 2,
                ),
              ),
              child: Center(
                child: Text(
                  UserColorPalette.getNameByIndex(selectedIndex),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Grid de colores 3x4
            GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              shrinkWrap: true,
              itemCount: UserColorPalette.userColors.length,
              itemBuilder: (ctx, idx) {
                final color = UserColorPalette.getColorByIndex(idx);
                final name = UserColorPalette.getNameByIndex(idx);
                final isSelected = idx == selectedIndex;

                return _ColorButton(
                  color: color,
                  isSelected: isSelected,
                  name: name,
                  onTap: () {
                    setState(() {
                      selectedIndex = idx;
                      selectedHex = UserColorPalette.getHexByIndex(idx);
                    });
                  },
                );
              },
            ),
            const SizedBox(height: 20),

            // Info de contraste WCAG
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(FluentIcons.info, color: Colors.white, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Todos los colores cumplen con WCAG AA (contraste ≥ 4.5:1)',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            widget.onColorSelected(selectedHex);
            Navigator.pop(context, selectedHex);
          },
          child: const Text('Aceptar'),
        ),
      ],
    );
  }
}

/// Botón individual de color con efecto seleccionado
class _ColorButton extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final String name;
  final VoidCallback onTap;

  const _ColorButton({
    required this.color,
    required this.isSelected,
    required this.name,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return material.Tooltip(
      message: name,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Fondo del color
            Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.transparent,
                  width: isSelected ? 3 : 0,
                ),
                boxShadow:
                    isSelected
                        ? [
                          BoxShadow(
                            color: color.withValues(alpha: 0.5),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ]
                        : [],
              ),
            ),
            // Checkmark si está seleccionado
            if (isSelected)
              const Icon(FluentIcons.check_mark, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }
}
