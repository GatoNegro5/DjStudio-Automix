import 'dart:io';

/// Perfil de Masterizar. Las 4 plataformas procesan una canción a la vez
/// y enfrían 12 s. Sin afinidad manual. El karaoke `_K` sigue solo en escritorio.
class MasterProfile {
  /// Canciones a la vez. Siempre 1.
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

  /// Android e iPhone: 1 hilo. Windows y Mac: 2. `_K` solo en escritorio.
  int get workerThreads => isPhone ? 1 : 2;

  /// Android, iPhone, Windows y Mac: una canción y enfriamiento de 12 s.
  /// `_K` solo en escritorio.
  static MasterProfile current() {
    if (Platform.isAndroid || Platform.isIOS) return phone;
    return desktop();
  }
}
