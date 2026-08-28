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
  final List<Player> players;

  // Estado en memoria para que el Automix consulte la base antes de inyectar FX espaciales
  String currentBaseFilter = '';

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

  AudioEqualizerService(this.players) {
    // Inicialización del pipeline limpio
    _buildAndApply(preamp: 0.0, gains: List.filled(10, 0.0), enabled: true);
  }

  /// Construye y aplica el Grafo DSP Unificado
  Future<void> applyEqualizer({
    required double preamp,
    required List<double> gains,
    required bool enabled,
  }) async {
    await _buildAndApply(preamp: preamp, gains: gains, enabled: enabled);
  }

  Future<void> _buildAndApply({
    required double preamp,
    required List<double> gains,
    required bool enabled,
  }) async {
    if (gains.length != 10) return;

    final List<String> filters = [];

    // 1. CAPA DE HEADROOM Y NORMALIZACIÓN DINÁMICA (AGC EN TIEMPO REAL)
    filters.add('aformat=sample_fmts=fltp');
    // dynaudnorm: Ventana deslizante (f=150), ganancia máxima (g=15), target pico (p=0.95)
    filters.add('dynaudnorm=f=150:g=15:p=0.95');
    // alimiter: Techo de ladrillo a -1.5dB para evadir clipping tras la compresión
    filters.add('alimiter=limit=-1.5dB');

    // 2. CAPA DE FIDELIDAD (SOXR & ARMÓNICOS)
    filters.add('aresample=resampler=soxr:precision=28');
    filters.add('crystalizer=i=2.0');

    // 3. CAPA DE ECUALIZACIÓN MANUAL / PRESETS
    if (enabled) {
      if (preamp != 0.0) {
        filters.add('volume=volume=${preamp.toStringAsFixed(1)}dB');
      }

      for (int i = 0; i < bandFrequencies.length; i++) {
        final gain = gains[i].clamp(-12.0, 12.0);

        // ZERO-COST OPTIMIZATION: Si el usuario selecciona "Flat", no sobrecargamos la CPU
        if (gain != 0.0) {
          final freq = bandFrequencies[i];
          filters.add(
            'equalizer=f=$freq:width_type=o:w=1:g=${gain.toStringAsFixed(1)}',
          );
        }
      }
    }

    // 4. CAPA ESPACIAL Y SUB-GRAVES
    filters.add('bass=g=3:f=60');
    filters.add('extrastereo=m=1.15');

    currentBaseFilter = filters.join(',');

    // APLICACIÓN SIMULTÁNEA: Asegura que el AutoMix no pierda la ecualización al cruzar pistas
    for (var player in players) {
      await (player.platform as dynamic)?.setProperty('af', currentBaseFilter);
    }
  }
}
