import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import '../core/hal/platform_strategy.dart';
import 'equalizer_provider.dart';

enum LiveDjMixStrategy { sequential, random }

enum LiveDjMixMode { activeSync, longBypass }

class LiveDjState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<File> queue;
  final String? currentTrackPath;
  final LiveDjMixMode currentMixMode;
  final int customCueInMs;
  final int customMixOutMs;
  final LiveDjMixStrategy mixStrategy;

  LiveDjState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentTrackPath,
    this.currentMixMode = LiveDjMixMode.activeSync,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
    this.mixStrategy = LiveDjMixStrategy.sequential,
  });

  LiveDjState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<File>? queue,
    String? currentTrackPath,
    LiveDjMixMode? currentMixMode,
    int? customCueInMs,
    int? customMixOutMs,
    LiveDjMixStrategy? mixStrategy,
  }) {
    return LiveDjState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentTrackPath: currentTrackPath ?? this.currentTrackPath,
      currentMixMode: currentMixMode ?? this.currentMixMode,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
      mixStrategy: mixStrategy ?? this.mixStrategy,
    );
  }
}

class LiveDjNotifier extends Notifier<LiveDjState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activePlayer => _usePlayerA ? _playerA : _playerB;
  Player get _standbyPlayer => _usePlayerA ? _playerB : _playerA;

  List<Player> get deckPlayers => [_playerA, _playerB];

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _completedSub;

  bool _isCrossfading = false;
  bool _isStandbyArmed = false;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;

  late final PlatformMixStrategy _liveStrategy;

  @override
  LiveDjState build() {
    _playerA = Player();
    _playerB = Player();

    _liveStrategy = MixStrategyFactory.getStrategy();

    (_playerA.platform as dynamic)?.setProperty('af', _liveStrategy.hifiFilter);
    (_playerB.platform as dynamic)?.setProperty('af', _liveStrategy.hifiFilter);

    _attachListeners(_playerA);
    _initPersistence();

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
    });

    return LiveDjState();
  }

  bool _isMixTrack(int durationMs) => durationMs > 600000;

  int _calculateSmartTrim(int durationMs) {
    if (_isMixTrack(durationMs)) return 0;
    if (durationMs > 30000) return 5000;
    return 0;
  }

  // 🎛️ INYECCIÓN ADN DJ: Ahora el Cartridge aplica la regla 65%-80%
  int _calculateRadioMixOut(int durationMs, String? path) {
    if (_isMixTrack(durationMs)) {
      return durationMs - 4000;
    }
    if (durationMs <= 0) return 0;

    final trackPathLower = path?.toLowerCase() ?? '';
    final isRemix = trackPathLower.contains('remix');
    final isEdm =
        trackPathLower.contains('electronica') ||
        trackPathLower.contains('house');
    final isTropical =
        trackPathLower.contains('salsa') ||
        trackPathLower.contains('cumbia') ||
        trackPathLower.contains('merengue');

    int safeMixOutMs = 0;
    if (isRemix || isEdm) {
      safeMixOutMs = (durationMs * 0.65).toInt();
    } else if (isTropical) {
      safeMixOutMs = (durationMs * 0.80).toInt();
    } else {
      safeMixOutMs = (durationMs * 0.75).toInt();
    }

    if (safeMixOutMs >= durationMs - 4000) {
      safeMixOutMs = durationMs - 4000;
    }

    return safeMixOutMs;
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_liveStrategy.getSessionPath());
      final data = {
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': state.currentTrackPath,
        'positionMs': state.position.inMilliseconds,
        'mixMode': state.currentMixMode.index,
        'mixStrategy': state.mixStrategy.index,
      };
      await file.writeAsString(jsonEncode(data));
      debugPrint("✅ [TRACKER] Snapshot guardado en disco correctamente.");
    } catch (e, stack) {
      debugPrint(
        "🔴 [TRACKER ERROR FATAL] Fallo al guardar Snapshot: $e\n$stack",
      );
    }
  }

  void shuffleQueue() {
    debugPrint(
      "🛠️ [TRACKER] shuffleQueue() INICIADO. Elementos en cola: ${state.queue.length}",
    );
    try {
      if (state.queue.length <= 1) {
        debugPrint("⚠️ [TRACKER] Cola muy pequeña. Forzando solo UI.");
        state = state.copyWith(mixStrategy: LiveDjMixStrategy.random);
        _saveSnapshot();
        return;
      }

      final list = List<File>.from(state.queue);
      list.shuffle(Random(DateTime.now().millisecondsSinceEpoch));

      state = state.copyWith(
        queue: list,
        mixStrategy: LiveDjMixStrategy.random,
      );

      debugPrint(
        "🔀 [TRACKER] Array barajado y Estado Mutado a RANDOM. Mandando señal a la UI...",
      );
      _saveSnapshot();
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Shuffle explotó: $e\n$stack");
    }
  }

  void toggleMixStrategy() {
    debugPrint(
      "🖱️ [TRACKER] Clic recibido en toggleMixStrategy(). Estrategia actual: ${state.mixStrategy.name}",
    );
    try {
      if (state.mixStrategy == LiveDjMixStrategy.sequential) {
        shuffleQueue();
      } else {
        state = state.copyWith(mixStrategy: LiveDjMixStrategy.sequential);
        debugPrint(
          "➡️ [TRACKER] Estado Mutado a SECUENCIAL. Mandando señal a la UI...",
        );
        _saveSnapshot();
      }
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Toggle explotó: $e\n$stack");
    }
  }

  Future<void> _initPersistence() async {
    try {
      final file = File(_liveStrategy.getSessionPath());
      if (!file.existsSync()) return;

      final content = await file.readAsString();
      final data = jsonDecode(content);

      final queuePaths = (data['queue'] as List?)?.cast<String>() ?? [];
      final queueFiles = queuePaths
          .map((p) => File(p))
          .where((f) => f.existsSync())
          .toList();
      final currentTrackPath = data['currentTrackPath'] as String?;
      final positionMs = data['positionMs'] as int?;

      final mixModeIdx = data['mixMode'] as int? ?? 0;
      final mixStrategyIdx = data['mixStrategy'] as int? ?? 0;

      state = state.copyWith(
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        currentMixMode: LiveDjMixMode.values[mixModeIdx],
        mixStrategy: LiveDjMixStrategy.values[mixStrategyIdx],
      );

      if (currentTrackPath != null) {
        await _activePlayer.open(Media(currentTrackPath), play: false);
        try {
          await _activePlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
        if (positionMs != null && positionMs > 0) {
          await _activePlayer.seek(Duration(milliseconds: positionMs));
        }
      }
    } catch (_) {}
  }

  void addTrack(File file) {
    if (!state.queue.any((f) => f.path == file.path)) {
      state = state.copyWith(queue: [...state.queue, file]);
      _saveSnapshot();
    }
  }

  void addAllTracks(List<File> files) {
    final currentPaths = state.queue.map((f) => f.path).toSet();
    final newFiles = files
        .where((f) => !currentPaths.contains(f.path))
        .toList();
    if (newFiles.isNotEmpty) {
      state = state.copyWith(queue: [...state.queue, ...newFiles]);
      _saveSnapshot();
    }
  }

  void removeTrack(String path) {
    final newQueue = state.queue.where((f) => f.path != path).toList();
    state = state.copyWith(queue: newQueue);
    _saveSnapshot();
  }

  void clearQueue() {
    state = state.copyWith(queue: []);
    _saveSnapshot();
  }

  Future<void> savePlaylist() async {
    if (state.queue.isEmpty) return;
    try {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'LiveDj_playlist.json',
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (result != null) {
        final file = File(result.path);
        final data = state.queue.map((f) => f.path).toList();
        await file.writeAsString(jsonEncode(data));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR] Guardando playlist: $e");
    }
  }

  Future<void> loadPlaylist() async {
    try {
      final XFile? result = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (result != null) {
        final file = File(result.path);
        final content = await file.readAsString();
        final List<dynamic> paths = jsonDecode(content);
        final List<File> newFiles = paths
            .map((p) => File(p.toString()))
            .where((f) => f.existsSync())
            .toList();

        if (newFiles.isNotEmpty) {
          state = state.copyWith(queue: [...state.queue, ...newFiles]);
          _saveSnapshot();
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR] Cargando playlist: $e");
    }
  }

  Future<void> playTrackFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length || _isCrossfading) return;

    final selectedFile = state.queue[index];

    List<File> newQueue = List.from(state.queue);
    newQueue.removeAt(index);
    newQueue.insert(0, selectedFile);

    state = state.copyWith(queue: newQueue);

    _isPrepModeBypass = false;
    await forceNext();
  }

  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) async {
      final posMs = pos.inMilliseconds;
      final durMs = state.duration.inMilliseconds;

      state = state.copyWith(position: pos);

      if ((posMs - _lastSavedPositionMs).abs() > 5000) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (durMs > 0 &&
          state.currentTrackPath != null &&
          state.queue.isNotEmpty) {
        final triggerMs = _calculateRadioMixOut(durMs, state.currentTrackPath);

        if (!_isStandbyArmed &&
            posMs >= (triggerMs - 10000) &&
            triggerMs > 10000) {
          _isStandbyArmed = true;
          await _standbyPlayer.setVolume(0.0);
          await _standbyPlayer.open(Media(state.queue.first.path), play: false);
        }

        if (posMs >= triggerMs) {
          if (!_isCrossfading && !_isPrepModeBypass) {
            _triggerCrossfade();
          }
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) async {
      state = state.copyWith(duration: dur);
      if (dur.inMilliseconds > 0 && state.currentTrackPath != null) {
        final triggerMs = _calculateRadioMixOut(
          dur.inMilliseconds,
          state.currentTrackPath,
        );
        final cueInMs = _calculateSmartTrim(dur.inMilliseconds);
        final mode = _isMixTrack(dur.inMilliseconds)
            ? LiveDjMixMode.longBypass
            : LiveDjMixMode.activeSync;

        state = state.copyWith(
          customCueInMs: cueInMs,
          customMixOutMs: triggerMs,
          currentMixMode: mode,
        );
      }
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (completed) {
        _isPrepModeBypass = false;
        _isCrossfading = false;
        forceNext();
      }
    });
  }

  Future<void> togglePlayPause() async {
    if (state.queue.isEmpty && state.currentTrackPath == null) return;
    if (state.currentTrackPath == null && state.queue.isNotEmpty) {
      await forceNext();
      return;
    }
    _isPrepModeBypass = false;
    await _activePlayer.playOrPause();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
  }

  Future<void> forceNext() async {
    if (_isCrossfading || state.queue.isEmpty) return;
    _triggerCrossfade(forceJit: true, isManualSkip: true);
  }

  Future<void> _triggerCrossfade({
    bool forceJit = false,
    bool isManualSkip = false,
  }) async {
    if (_isCrossfading || state.queue.isEmpty) return;
    _isCrossfading = true;

    final String nextTrack = state.queue.first.path;
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    if (!_isStandbyArmed || forceJit) {
      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
      } catch (_) {}
    }

    // 🚀 EXTRACCIÓN SÍNCRONA DIRECTA (SIN TIMEOUT)
    Duration trackDur = Duration.zero;
    try {
      trackDur = incomingPlayer.state.duration;
    } catch (_) {}

    final int cueInMs = _calculateSmartTrim(trackDur.inMilliseconds);
    final int triggerMs = _calculateRadioMixOut(
      trackDur.inMilliseconds,
      nextTrack,
    );
    final LiveDjMixMode nextMode = _isMixTrack(trackDur.inMilliseconds)
        ? LiveDjMixMode.longBypass
        : LiveDjMixMode.activeSync;

    try {
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    List<File> newQueue = List.from(state.queue);
    if (newQueue.isNotEmpty) newQueue.removeAt(0);

    state = state.copyWith(
      queue: newQueue,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: trackDur,
      customCueInMs: cueInMs,
      customMixOutMs: triggerMs,
      currentMixMode: nextMode,
    );

    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixProfile: state.currentMixMode,
      isManualSkip: isManualSkip,
    );
  }

  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required LiveDjMixMode mixProfile,
    bool isManualSkip = false,
  }) async {
    final String currentBaseFilter = ref
        .read(equalizerProvider.notifier)
        .currentBaseFilter;
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    try {
      platformIn?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty('audio-pitch-correction', 'yes');
      platformIn?.setProperty('af', currentBaseFilter);
      platformOut?.setProperty('af', currentBaseFilter);

      await incomingPlayer.setVolume(0.0);

      final fadeStopwatch = Stopwatch()..start();
      final fadeOutDurationMs = isManualSkip
          ? 4500
          : (mixProfile == LiveDjMixMode.longBypass ? 4000 : 18000);

      while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
        final progress = (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs)
            .clamp(0.0, 1.0);

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final rateIn = (progress * 1.8).clamp(0.0, 1.0);
        final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);

        final smoothRateIn = pow(rateIn, 1.2).toDouble();
        final smoothRateOut = pow(rateOut, 1.2).toDouble();

        await incomingPlayer.setVolume(
          (smoothRateIn * 100.0).clamp(0.0, 100.0),
        );
        await fadingPlayer.setVolume((smoothRateOut * 100.0).clamp(0.0, 100.0));

        await Future.delayed(const Duration(milliseconds: 32));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      try {
        await incomingPlayer.setVolume(100.0);
        await incomingPlayer.setRate(1.0);
        platformIn?.setProperty('af', currentBaseFilter);
        platformOut?.setProperty('af', currentBaseFilter);
        await fadingPlayer.setVolume(0.0);
        await fadingPlayer.setRate(1.0);
        await fadingPlayer.stop();
      } catch (_) {}

      _isCrossfading = false;
    }
  }
}

final liveDjProvider = NotifierProvider<LiveDjNotifier, LiveDjState>(
  LiveDjNotifier.new,
);
