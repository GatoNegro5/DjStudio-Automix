import 'dart:io';

/// Perfil de Masterizar. La lógica de cada paso es la misma en las 4
/// plataformas; cambian el paralelismo, la pausa térmica y el karaoke `_K`.
class MasterProfile {
  /// Canciones a la vez. Celular: 1. Escritorio: 2–4.
  final int parallel;

  /// Pausa entre canciones para no cocinar el teléfono.
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
    thermalGap: Duration(seconds: 2),
    allowKaraoke: false,
  );

  static MasterProfile desktop() {
    final int cores = Platform.numberOfProcessors;
    final int lanes = cores >= 8 ? 4 : (cores >= 4 ? 3 : 2);
    return MasterProfile(
      parallel: lanes,
      thermalPause: false,
      thermalGap: Duration.zero,
      allowKaraoke: true,
    );
  }

  /// Android e iPhone: una canción y pausa. Windows, Mac y el resto de
  /// escritorio: 2–4 en paralelo, sin pausa, con `_K`.
  static MasterProfile current() {
    if (Platform.isAndroid || Platform.isIOS) return phone;
    return desktop();
  }
}
