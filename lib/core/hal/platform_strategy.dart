import 'dart:io';

import '../../djiphone/iphone_library.dart';

/// Limitador final. Siempre va DESPUÉS del ecualizador: cualquier realce
/// que pase de 0 dBFS lo atrapa el limitador, no el recorte digital.
const String kHifiLimiter = 'alimiter=limit=0.95:level=disabled';

abstract class PlatformMixStrategy {
  String get hifiFilter;

  /// `hifiFilter` sin el limitador (color de la plataforma).
  String get colorFilter;

  /// Limitador que cierra la cadena `af`.
  String get limiterFilter => kHifiLimiter;
  String getSessionPath();
  bool get supportsHighFidelityMastering;
}

class WindowsMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'bass=g=3:f=60,extrastereo=m=1.15,alimiter=limit=0.95:level=disabled';

  @override
  String get colorFilter => 'bass=g=3:f=60,extrastereo=m=1.15';

  @override
  String get limiterFilter => kHifiLimiter;

  @override
  String getSessionPath() {
    final dir = Directory(
      '${Platform.environment['USERPROFILE']}\\Music\\DjPlaylists',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}\\player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => true;
}

class MacOsMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'bass=g=3:f=60,extrastereo=m=1.15,alimiter=limit=0.95:level=disabled';

  @override
  String get colorFilter => 'bass=g=3:f=60,extrastereo=m=1.15';

  @override
  String get limiterFilter => kHifiLimiter;

  @override
  String getSessionPath() {
    final dir = Directory('${Platform.environment['HOME']}/Music/DjPlaylists');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => true;
}

class AndroidMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'bass=g=3:f=60,alimiter=limit=0.95:level=disabled';

  @override
  String get colorFilter => 'bass=g=3:f=60';

  @override
  String get limiterFilter => kHifiLimiter;

  @override
  String getSessionPath() {
    final dir = Directory('/storage/emulated/0/Music/DjPlaylists');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => false;
}

class MixStrategyFactory {
  static PlatformMixStrategy getStrategy() {
    if (Platform.isIOS) return IphoneMixStrategy();
    if (Platform.isWindows) return WindowsMixStrategy();
    if (Platform.isMacOS) return MacOsMixStrategy();
    if (Platform.isAndroid || Platform.isIOS) return AndroidMixStrategy();
    return WindowsMixStrategy();
  }
}

class IphoneMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'bass=g=3:f=60,alimiter=limit=0.95:level=disabled';

  @override
  String get colorFilter => 'bass=g=3:f=60';

  @override
  String get limiterFilter => kHifiLimiter;

  @override
  String getSessionPath() {
    final dir = Directory(IphoneLibrary.playlistsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => false;
}
