import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Producción: última ayuda visual ya vista (para campana de barra y lobby).
class ProduccionAyudaNovedadPrefs {
  ProduccionAyudaNovedadPrefs._();

  static const String _kAckSig = 'prod_ayuda_novedad_ack_sig_v1';

  /// Se incrementa al guardar [writeAckSignature] para refrescar la campana al instante.
  static final ValueNotifier<int> ackChangeSignal = ValueNotifier<int>(0);

  static Future<String?> readAckSignature() async {
    final p = await SharedPreferences.getInstance();
    final s = (p.getString(_kAckSig) ?? '').trim();
    return s.isEmpty ? null : s;
  }

  static Future<void> writeAckSignature(String signature) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAckSig, signature.trim());
    ackChangeSignal.value++;
  }

  static Future<void> _writeAckSilent(String signature) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAckSig, signature.trim());
  }

  /// Primera ejecución: no marcar como “novedad” lo que ya existía al instalar.
  static Future<void> ensureBaselined(String? currentSignature) async {
    final sig = currentSignature?.trim();
    if (sig == null || sig.isEmpty) return;
    final existing = await readAckSignature();
    if (existing != null && existing.isNotEmpty) return;
    await _writeAckSilent(sig);
  }
}
