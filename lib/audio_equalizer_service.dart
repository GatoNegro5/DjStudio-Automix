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

  // Presets calibrados acústicamente
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
  // 🛠️ FIX ARQUITECTURA: Soporte Multi-Deck. Recibe la lista para afectar a DECK A y DECK B al mismo tiempo.
  final List<Player> players;

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

  AudioEqualizerService(this.players);

  /// Construye y aplica el Grafo DSP Unificado (Hi-Fi Base + EQ Manual) sobre libmpv
  Future<void> applyEqualizer({
    required double preamp,
    required List<double> gains,
    required bool enabled,
  }) async {
    if (gains.length != 10) return;

    final List<String> filters = [];

    // 1. 💎 CAPA DE FIDELIDAD BASE (ZERO-LOSS & PSICOACÚSTICA)
    // ❌ PROHIBIDO usar loudnorm y acompressor aquí. El pipeline de Rust ya masterizó el archivo físico a -14 LUFS.
    // ✅ Inyectamos Remuestreo SoXR de 28-bit y Crystalizer para regenerar armónicos perdidos en la compresión.
    filters.add('aresample=resampler=soxr:precision=28');
    filters.add('crystalizer=i=2.0');

    // 2. 🎛️ CAPA DE ECUALIZACIÓN MANUAL / PRESETS
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

    // 3. 🌐 CAPA ESPACIAL Y SUB-GRAVES (Siempre al final de la cadena de fase)
    filters.add('bass=g=3:f=60');
    filters.add('extrastereo=m=1.15');

    // Enviar el grafo de filtros directamente al procesador C++ de libmpv
    final String afString = filters.join(',');

    // 🛠️ APLICACIÓN SIMULTÁNEA: Asegura que el AutoMix no pierda la ecualización al cruzar pistas
    for (var player in players) {
      await (player.platform as dynamic)?.setProperty('af', afString);
    }
  }
}
