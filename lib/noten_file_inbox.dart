import 'dart:io';

import 'package:flutter/services.dart';

/// Receives `.noten` files that iOS or Android opened with Ink Note.
///
/// Native code first copies the security-scoped/content URI into the app's
/// temporary directory. Dart then imports that local copy through the same
/// validated archive reader used by the file picker.
class NotenFileInbox {
  const NotenFileInbox._();

  static const MethodChannel _channel = MethodChannel('ink_note/noten_files');

  static void setFileAvailableHandler(void Function()? handler) {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fileAvailable') handler();
    });
  }

  static Future<String?> takePendingPath() async {
    if (!Platform.isIOS && !Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('takePendingPath');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
