import 'dart:io';

import 'package:local_notifier/local_notifier.dart';

class ChatWindowsNotificationService {
  ChatWindowsNotificationService._();
  static final ChatWindowsNotificationService instance =
      ChatWindowsNotificationService._();

  bool _initialized = false;

  Future<void> init() async {
    if (!Platform.isWindows || _initialized) return;
    await localNotifier.setup(
      appName: 'Industrial Manager x Epickap',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
    _initialized = true;
  }

  Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    if (!Platform.isWindows) return;
    await init();
    final notification = LocalNotification(
      title: title,
      body: body,
      silent: false,
    );
    await notification.show();
  }
}
