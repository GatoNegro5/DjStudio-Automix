import 'dart:io';

import 'package:flutter/services.dart';

import 'master_cool.dart';

/// Estado térmico del sistema. Android: PowerManager (estado y headroom
/// a 10 s). iOS y macOS: ProcessInfo.thermalState. Windows no reporta.
class ThermalProbe {
  static const MethodChannel channel = MethodChannel('gatomix/thermal');

  static String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    return 'other';
  }

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

  /// Solo Android, API 30+. `null` si el SO no lo da.
  static Future<double?> headroom() async {
    if (!Platform.isAndroid) return null;
    try {
      final Object? v = await channel.invokeMethod<Object?>('headroom');
      if (v is double) return v;
      if (v is num) return v.toDouble();
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isHigh() async {
    final int? status = await read();
    final double? room = await headroom();
    return MasterCool.shouldExtendPause(
      platform: platform,
      status: status,
      headroom: room,
    );
  }

  /// Texto del log de la canción.
  static Future<String> label() async {
    return MasterCool.thermalLabel(
      platform: platform,
      status: await read(),
      headroom: await headroom(),
    );
  }
}
