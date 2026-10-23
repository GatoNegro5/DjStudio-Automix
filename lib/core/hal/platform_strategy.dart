import 'dart:io';

import '../../djiphone/iphone_library.dart';
import '../audio/af_caps.dart';

/// Limitador final. Va DESPUÉS del ecualizador. Solo se aplica si el libmpv
/// empaquetado lo trae. En Windows, si `alimiter` no está, `AfCaps` prueba
/// un limitador equivalente y `WindowsMixStrategy` usa esa cadena. Sin
/// ninguno que la sonda acepte, no se inserta un filtro: un nombre inválido
/// tumbaría toda la cadena `af`.
const String kHifiLimiter = 'alimiter=limit=0.95:level=disabled';

abstract class PlatformMixStrategy {
  /// Cadena de arranque (solo filtros soportados; puede ser vacía).
  String get hifiFilter => limiterFilter;

  /// Color de la plataforma. Vacío = fidelidad plana (sin realces fijos).
  String get colorFilter => '';

  /// Filtro nivelador. VACÍO: la sonoridad igual de todas las canciones la
  /// hace `AdaptiveEq` con ReplayGain nativo de mpv (loudnorm/dynaudnorm no
  /// existen en el libmpv empaquetado).
  String get levelerFilter => '';

  /// Limitador que cierra la cadena `af` ('' si no está disponible).
  String get limiterFilter => AfCaps.has('alimiter') ? kHifiLimiter : '';

  String getSessionPath();
  bool get supportsHighFidelityMastering;
}

class WindowsMixStrategy extends PlatformMixStrategy {
  /// La cadena exacta que la sonda aceptó. Las otras plataformas siguen
  /// con [kHifiLimiter] solo si `AfCaps.has('alimiter')`.
  @override
  String get limiterFilter {
    if (AfCaps.windowsSafetyLimiter.isNotEmpty) {
      return AfCaps.windowsSafetyLimiter;
    }
    return super.limiterFilter;
  }

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

class MacOsMixStrategy extends PlatformMixStrategy {
  @override
  String getSessionPath() {
    final dir = Directory('${Platform.environment['HOME']}/Music/DjPlaylists');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => true;
}

class AndroidMixStrategy extends PlatformMixStrategy {
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

class IphoneMixStrategy extends PlatformMixStrategy {
  @override
  String getSessionPath() {
    final dir = Directory(IphoneLibrary.playlistsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => false;
}
