import 'package:flutter/foundation.dart';

/// Se incrementa al mostrar el panel **Importar Excel** para que
/// [ArbitrationScreen] vuelva a leer prefs del puente BOM (el estado del
/// widget suele permanecer vivo entre pestañas).
class ArbitrationBridge {
  ArbitrationBridge._();

  static final ValueNotifier<int> consumeRequestTick = ValueNotifier<int>(0);

  static void notifyConsumePending() {
    consumeRequestTick.value++;
  }
}
