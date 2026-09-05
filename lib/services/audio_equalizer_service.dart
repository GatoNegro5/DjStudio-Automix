import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hal/platform_strategy.dart';
import '../providers/automix_provider.dart';
import '../providers/livedj_provider.dart';

class EqualizerPreset {
  final String name;
  final double preamp;
  final List<double> gains;

  const EqualizerPreset({
    required this.name,
    required this.preamp,
    required this.gains,
  });

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
  final Ref ref;
  String currentBaseFilter = '';
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

  AudioEqualizerService(this.ref) {
    _buildAndApply(preamp: 0.0, gains: List.filled(10, 0.0), enabled: true);
  }

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

    final String halFilter = MixStrategyFactory.getStrategy().hifiFilter;

    // 🎛️ INYECCIÓN DSP: Normalizador Dinámico de Nivel de Estudio (Auto-Gain)
    // f=150 (ventana rápida), g=11 (ganancia máxima), p=0.9 (protección de transitorios/kicks)
    const String autoGainFilter = "dynaudnorm=f=150:g=11:p=0.9";

    final List<String> eqFilters = [];

    if (enabled) {
      if (preamp != 0.0) {
        eqFilters.add('volume=volume=${preamp.toStringAsFixed(1)}dB');
      }
      for (int i = 0; i < bandFrequencies.length; i++) {
        final gain = gains[i].clamp(-12.0, 12.0);
        if (gain != 0.0) {
          eqFilters.add(
            'equalizer=f=${bandFrequencies[i]}:width_type=o:w=1:g=${gain.toStringAsFixed(1)}',
          );
        }
      }
    }

    // 🛡️ ENSAMBLAJE DEL PIPELINE: HAL -> Auto-Gain -> Ecualizador
    currentBaseFilter = '$halFilter,$autoGainFilter';
    if (eqFilters.isNotEmpty) {
      currentBaseFilter += ',${eqFilters.join(',')}';
    }

    // Aplicación atómica a todos los decks en vivo (DJ y liveDj)
    final activePlayers = [
      ...ref.read(automixProvider.notifier).deckPlayers,
      ...ref.read(liveDjProvider.notifier).deckPlayers,
    ];

    for (var player in activePlayers) {
      try {
        await (player.platform as dynamic)?.setProperty(
          'af',
          currentBaseFilter,
        );
      } catch (_) {}
    }
  }
}
