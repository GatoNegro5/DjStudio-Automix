import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import '../core/hal/platform_strategy.dart';
import 'adaptive_eq.dart';
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

/// Motor dueño de un ecualizador. Cada uno escribe `af` solo en sus decks.
enum EqualizerTarget { automix, liveDj }

class AudioEqualizerService {
  final Ref ref;
  final EqualizerTarget target;
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

  AudioEqualizerService(this.ref, this.target) {
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

    final strategy = MixStrategyFactory.getStrategy();
    final String halFilter = strategy.colorFilter;

    final List<String> eqFilters = [];

    if (enabled) {
      // Headroom automático: el preamp nunca es mayor que el realce máximo
      // en negativo, así los realces no empujan la señal sobre 0 dBFS.
      double maxBoost = 0.0;
      for (final g in gains) {
        final double c = g.clamp(-12.0, 12.0).toDouble();
        if (c > maxBoost) maxBoost = c;
      }
      final double effectivePreamp = preamp < -maxBoost ? preamp : -maxBoost;
      if (effectivePreamp != 0.0) {
        eqFilters.add('volume=volume=${effectivePreamp.toStringAsFixed(1)}dB');
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

    // Cadena: color (vacío = plano) -> EQ -> nivelador de volumen -> limitador.
    final List<String> chain = [
      if (halFilter.isNotEmpty) halFilter,
      ...eqFilters,
      strategy.levelerFilter,
      // Limitador SIEMPRE al final, después del ecualizador y el nivelador.
      strategy.limiterFilter,
    ];
    currentBaseFilter = chain.join(',');
    _preChain = [if (halFilter.isNotEmpty) halFilter, ...eqFilters];
    _postChain = [strategy.levelerFilter, strategy.limiterFilter];

    // Aplicación atómica solo a los decks del motor dueño.
    final activePlayers = target == EqualizerTarget.automix
        ? ref.read(automixProvider.notifier).deckPlayers
        : ref.read(liveDjProvider.notifier).deckPlayers;

    for (var player in activePlayers) {
      try {
        await (player.platform as dynamic)?.setProperty(
          'af',
          filterFor(player),
        );
      } catch (_) {}
    }
  }

  List<String> _preChain = const [];
  List<String> _postChain = const [];

  /// Cadena completa del [player]: EQ del usuario -> corrección adaptativa
  /// de SU canción -> nivelador -> limitador. Sin perfil = cadena base.
  String filterFor(Player player) {
    final a = AdaptiveEq.snippetFor(player);
    if (a.isEmpty || _postChain.isEmpty) return currentBaseFilter;
    return [..._preChain, a, ..._postChain].join(',');
  }

  /// Llamar tras `open()` en un deck: mide la canción y aplica su curva.
  void adapt(Player player, String path) {
    AdaptiveEq.attach(
      player,
      path,
      onReady: (_) {
        try {
          (player.platform as dynamic)?.setProperty('af', filterFor(player));
        } catch (_) {}
      },
    );
  }
}
