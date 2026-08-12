import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  runApp(const ProviderScope(child: EqualizerSandboxApp()));
}

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
  final Player player;

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

  Future<void> applyEqualizer({
    required double preamp,
    required List<double> gains,
    required bool enabled,
  }) async {
    if (gains.length != 10) return;

    if (!enabled) {
      await (player.platform as dynamic)?.setProperty('af', '');
      return;
    }

    final List<String> filters = [];

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

    final String afString = filters.join(',');
    await (player.platform as dynamic)?.setProperty('af', afString);
  }
}

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

final playerProvider = Provider<Player>((ref) {
  final player = Player();
  ref.onDispose(() {
    player.dispose();
  });
  return player;
});

final equalizerServiceProvider = Provider<AudioEqualizerService>((ref) {
  final player = ref.watch(playerProvider);
  return AudioEqualizerService(player);
});

final equalizerProvider =
    StateNotifierProvider<EqualizerNotifier, EqualizerState>((ref) {
      final service = ref.watch(equalizerServiceProvider);
      return EqualizerNotifier(service);
    });

class EqualizerSandboxApp extends StatelessWidget {
  const EqualizerSandboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DSP Equalizer Sandbox',
      theme: ThemeData.dark(),
      home: const EqualizerTestPage(),
    );
  }
}

class EqualizerTestPage extends ConsumerWidget {
  const EqualizerTestPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eqState = ref.watch(equalizerProvider);
    final eqNotifier = ref.read(equalizerProvider.notifier);
    final player = ref.watch(playerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('DSP Sandbox: 10-Band EQ'),
        backgroundColor: Colors.black,
        actions: [
          Switch(
            value: eqState.enabled,
            onChanged: (val) => eqNotifier.toggleEnabled(val),
            activeColor: Colors.greenAccent,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.black45,
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    await player.open(
                      Media(
                        'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Reproducir Audio Test (Demo Stream)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    await player.pause();
                  },
                  icon: const Icon(Icons.pause),
                  label: const Text('Pausar'),
                ),
              ],
            ),
          ),
          Expanded(
            child: IgnorePointer(
              ignoring: !eqState.enabled,
              child: Opacity(
                opacity: eqState.enabled ? 1.0 : 0.4,
                child: Column(
                  children: [
                    _buildPresetSelector(eqState, eqNotifier),
                    const Divider(color: Colors.white24),
                    _buildPreampControl(eqState, eqNotifier),
                    const Divider(color: Colors.white24),
                    Expanded(child: _buildEqBands(eqState, eqNotifier)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetSelector(
    EqualizerState state,
    EqualizerNotifier notifier,
  ) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Preset:',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          DropdownButton<EqualizerPreset>(
            dropdownColor: Colors.grey[900],
            value:
                EqualizerPreset.defaultPresets.any(
                  (p) => p.name == state.currentPresetName,
                )
                ? EqualizerPreset.defaultPresets.firstWhere(
                    (p) => p.name == state.currentPresetName,
                  )
                : null,
            hint: Text(
              state.currentPresetName,
              style: const TextStyle(color: Colors.greenAccent),
            ),
            items: EqualizerPreset.defaultPresets.map((preset) {
              return DropdownMenuItem(
                value: preset,
                child: Text(
                  preset.name,
                  style: const TextStyle(color: Colors.white),
                ),
              );
            }).toList(),
            onChanged: (preset) {
              if (preset != null) notifier.applyPreset(preset);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPreampControl(EqualizerState state, EqualizerNotifier notifier) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          const Text('Preamp', style: TextStyle(color: Colors.white70)),
          Expanded(
            child: Slider(
              min: -12.0,
              max: 12.0,
              value: state.preamp,
              activeColor: Colors.greenAccent,
              inactiveColor: Colors.white24,
              onChanged: (val) => notifier.setPreamp(val),
            ),
          ),
          Text(
            '${state.preamp.toStringAsFixed(1)} dB',
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildEqBands(EqualizerState state, EqualizerNotifier notifier) {
    const labels = [
      '31',
      '62',
      '125',
      '250',
      '500',
      '1k',
      '2k',
      '4k',
      '8k',
      '16k',
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(10, (index) {
        return Column(
          children: [
            Text(
              state.gains[index].toStringAsFixed(1),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Expanded(
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  min: -12.0,
                  max: 12.0,
                  value: state.gains[index],
                  activeColor: Colors.greenAccent,
                  inactiveColor: Colors.white24,
                  onChanged: (val) => notifier.setBandGain(index, val),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0, top: 8.0),
              child: Text(
                labels[index],
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        );
      }),
    );
  }
}
