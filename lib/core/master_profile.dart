import 'dart:io';

/// Perfil de Masterizar. Las 4 plataformas procesan una canción a la vez,
/// rotan un par de núcleos y enfrían 12 s. El karaoke `_K` sigue solo en escritorio.
class MasterProfile {
  /// Canciones a la vez. Siempre 1. Cada una usa un par de núcleos.
  final int parallel;

  /// Pausa de enfriamiento entre canción y canción.
  final bool thermalPause;

  final Duration thermalGap;

  /// Generar `_K` (karaoke IA). Solo escritorio.
  final bool allowKaraoke;

  const MasterProfile({
    required this.parallel,
    required this.thermalPause,
    required this.thermalGap,
    required this.allowKaraoke,
  });

  bool get isPhone => !allowKaraoke;

  static const MasterProfile phone = MasterProfile(
    parallel: 1,
    thermalPause: true,
    thermalGap: Duration(seconds: 12),
    allowKaraoke: false,
  );

  static MasterProfile desktop() {
    return const MasterProfile(
      parallel: 1,
      thermalPause: true,
      thermalGap: Duration(seconds: 12),
      allowKaraoke: true,
    );
  }

  /// Android, iPhone, Windows y Mac: una canción, par de núcleos turnado y
  /// enfriamiento de 12 s. `_K` solo en escritorio.
  static MasterProfile current() {
    if (Platform.isAndroid || Platform.isIOS) return phone;
    return desktop();
  }
}
