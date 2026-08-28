import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'audio_equalizer_service.dart';
import 'player_provider.dart';
import 'broadcast_provider.dart';

class EqualizerState {
  final bool enabled;
  final double preamp;
  final List<double> gains;
  final String currentPresetName;

  EqualizerState({
    required this.enabled,
    required this.preamp,
    required this.gains,
    required this.currentPresetName,
  });

  EqualizerState copyWith({
    bool? enabled,
    double? preamp,
    List<double>? gains,
    String? currentPresetName,
  }) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      preamp: preamp ?? this.preamp,
      gains: gains ?? List.from(this.gains),
      currentPresetName: currentPresetName ?? this.currentPresetName,
    );
  }
}

class EqualizerNotifier extends StateNotifier<EqualizerState> {
  final AudioEqualizerService _service;

  EqualizerNotifier(this._service)
    : super(
        EqualizerState(
          enabled: true,
          preamp: EqualizerPreset.defaultPresets[0].preamp,
          gains: List.from(EqualizerPreset.defaultPresets[0].gains),
          currentPresetName: EqualizerPreset.defaultPresets[0].name,
        ),
      ) {
    _sync();
  }

  // EXPOSICIÓN AL AUTOMIX: Permite al Live DJ leer el estado antes de aplicar Ecos/Efectos
  String get currentBaseFilter => _service.currentBaseFilter;

  void toggleEnabled(bool value) {
    state = state.copyWith(enabled: value);
    _sync();
  }

  void setPreamp(double value) {
    state = state.copyWith(preamp: value, currentPresetName: 'Custom');
    _sync();
  }

  void setBandGain(int index, double gain) {
    final newGains = List<double>.from(state.gains);
    newGains[index] = gain;
    state = state.copyWith(gains: newGains, currentPresetName: 'Custom');
    _sync();
  }

  void applyPreset(EqualizerPreset preset) {
    state = state.copyWith(
      preamp: preset.preamp,
      gains: List.from(preset.gains),
      currentPresetName: preset.name,
    );
    _sync();
  }

  void _sync() {
    _service.applyEqualizer(
      preamp: state.preamp,
      gains: state.gains,
      enabled: state.enabled,
    );
  }
}

// INYECCIÓN DE DEPENDENCIAS: El Provider global
final equalizerProvider = StateNotifierProvider<EqualizerNotifier, EqualizerState>((
  ref,
) {
  // Extraemos la lista con AMBOS reproductores (Automix Semántico + Broadcast Radio)
  final players = [
    ...ref.read(playerProvider.notifier).deckPlayers,
    ...ref.read(broadcastProvider.notifier).deckPlayers,
  ];

  // Inicializamos el servicio Multi-Deck (Afectará a los 4 Decks físicos en RAM)
  final service = AudioEqualizerService(players);

  // Retornamos el controlador del ecualizador
  return EqualizerNotifier(service);
});
