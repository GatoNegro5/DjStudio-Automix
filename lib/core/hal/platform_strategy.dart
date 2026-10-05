import 'dart:io';

import '../../djiphone/iphone_library.dart';

/// Limitador final. Siempre va DESPUÉS del ecualizador y del nivelador:
/// cualquier realce que pase de 0 dBFS lo atrapa el limitador, no el recorte.
const String kHifiLimiter = 'alimiter=limit=0.95:level=disabled';

/// Nivelador de volumen (todas las canciones a la misma sonoridad).
/// Escritorio: EBU R128 (loudnorm) a -14 LUFS, el estándar de las
/// plataformas de streaming, con pico real máximo de -1.5 dBTP.
const String kLevelerDesktop = 'loudnorm=I=-14:LRA=9:TP=-1.5';

/// Celular: normalizador dinámico liviano (loudnorm remuestrea a 192 kHz y
/// con dos decks gastaría batería y CPU en segundo plano).
const String kLevelerMobile = 'dynaudnorm=f=500:g=15:p=0.9:m=8';

abstract class PlatformMixStrategy {
  /// Cadena completa de arranque: nivelador + limitador, sin coloración.
  String get hifiFilter;

  /// Color de la plataforma. Vacío = fidelidad plana (sin realces fijos).
  String get colorFilter;

  /// Nivelador de volumen (va después del ecualizador).
  String get levelerFilter;

  /// Limitador que cierra la cadena `af`.
  String get limiterFilter => kHifiLimiter;
  String getSessionPath();
  bool get supportsHighFidelityMastering;
}

class WindowsMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter => '$levelerFilter,$limiterFilter';

  @override
  String get colorFilter => '';

  @override
  String get levelerFilter => kLevelerDesktop;

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
  String get hifiFilter => '$levelerFilter,$limiterFilter';

  @override
  String get colorFilter => '';

  @override
  String get levelerFilter => kLevelerDesktop;

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
  String get hifiFilter => '$levelerFilter,$limiterFilter';

  @override
  String get colorFilter => '';

  @override
  String get levelerFilter => kLevelerMobile;

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
  String get hifiFilter => '$levelerFilter,$limiterFilter';

  @override
  String get colorFilter => '';

  @override
  String get levelerFilter => kLevelerMobile;

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
