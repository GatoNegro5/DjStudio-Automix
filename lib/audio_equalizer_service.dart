import 'package:media_kit/media_kit.dart';

class EqualizerPreset {
  final String name;
  final double preamp;
  final List<double> gains; // 10 bandas

  const EqualizerPreset({
    required this.name,
    required this.preamp,
    required this.gains,
  });

  // Presets calibrados acusticamente
  static const List<EqualizerPreset> defaultPresets = [
    EqualizerPreset(
      name: 'Spotify Signature',
      preamp: -1.5,
      gains: [3.5, 2.5, 1.0, -0.5, -1.0, 0.0, 1.5, 2.5, 3.5, 4.0],
    ),
    EqualizerPreset(
      name: 'Flat / Studio',
      preamp: 0.0,
      gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    ),
    EqualizerPreset(
      name: 'Club DJ Punch',
      preamp: -2.0,
      gains: [5.0, 4.0, 2.0, 0.0, -1.0, -1.0, 0.0, 2.0, 3.5, 4.5],
    ),
    EqualizerPreset(
      name: 'Bass Master',
      preamp: -3.0,
      gains: [6.5, 5.5, 3.5, 1.0, 0.0, -1.5, -1.0, 0.0, 1.0, 1.5],
    ),
    EqualizerPreset(
      name: 'Vocal & Acoustic',
      preamp: -1.0,
      gains: [-2.0, -1.0, 0.0, 1.5, 3.0, 3.5, 2.5, 1.0, 0.5, 0.0],
    ),
  ];
}

class AudioEqualizerService {
  final Player player;

  // Frecuencias fijas de 10 bandas (ISO Standard)
  static const List<int> bandFrequencies = [
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  AudioEqualizerService(this.player);

  /// Aplica el filtro DSP de ecualización en tiempo real sobre libmpv
  Future<void> applyEqualizer({
    required double preamp,
    required List<double> gains,
    required bool enabled,
    bool enableAutoMastering = true, // El pipeline de Spotify
  }) async {
    if (gains.length != 10) return;

    final List<String> filters = [];

    // 1. Capa de Masterización Dinámica (Spotify Sound)
    if (enableAutoMastering) {
      // loudnorm: EBU R128 a -14 LUFS (Estándar de Streaming)
      // acompressor: Glue y punch (ratio 2.5:1, attack rápido, release suave)
      filters.add('loudnorm=I=-14:LRA=11:TP=-1.0');
      filters.add(
        'acompressor=threshold=-12dB:ratio=2.5:attack=5:release=50:makeup=1.5',
      );
    }

    // 2. Capa de Ecualización Manual / Presets
    if (enabled) {
      if (preamp != 0.0) {
        filters.add('volume=volume=${preamp.toStringAsFixed(1)}dB');
      }

      for (int i = 0; i < bandFrequencies.length; i++) {
        final freq = bandFrequencies[i];
        final gain = gains[i].clamp(-12.0, 12.0);
        filters.add(
          'equalizer=f=$freq:width_type=o:w=1:g=${gain.toStringAsFixed(1)}',
        );
      }
    }

    if (filters.isEmpty) {
      // Bypass total
      await (player.platform as dynamic)?.setProperty('af', '');
      return;
    }

    // Enviar el grafo de filtros directamente al procesador C++ de libmpv
    final String afString = filters.join(',');
    await (player.platform as dynamic)?.setProperty('af', afString);
  }
}
