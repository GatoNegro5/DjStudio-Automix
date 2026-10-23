import 'dart:io';

import 'package:flutter/services.dart';

import 'master_cool.dart';

/// Estado térmico del sistema. Android: PowerManager. iOS y macOS:
/// ProcessInfo.thermalState. Windows y Linux no reportan: no se alarga.
class ThermalProbe {
  static const MethodChannel channel = MethodChannel('gatomix/thermal');

  static Future<int?> read() async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      return null;
    }
    try {
      final Object? v = await channel.invokeMethod<Object?>('status');
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isHigh() async {
    final int? status = await read();
    final String platform = Platform.isAndroid
        ? 'android'
        : Platform.isIOS
        ? 'ios'
        : Platform.isMacOS
        ? 'macos'
        : 'other';
    return MasterCool.thermalIsHigh(platform: platform, status: status);
  }
}
