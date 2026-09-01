import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import '../core/hal/platform_strategy.dart';
import 'db_provider.dart';
import 'equalizer_provider.dart';

enum BroadcastMixStrategy { sequential, random }

enum BroadcastMixStyle { smooth, vinylBrake, echoOut, automixDsp }

class BroadcastState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<File> queue;
  final String? currentTrackPath;
  final Set<BroadcastMixStyle> activeMixStyles;
  final int customCueInMs;
  final int customMixOutMs;

  BroadcastState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentTrackPath,
    this.activeMixStyles = const {
      BroadcastMixStyle.smooth,
      BroadcastMixStyle.vinylBrake,
      BroadcastMixStyle.echoOut,
      BroadcastMixStyle.automixDsp,
    },
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
  });

  BroadcastState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<File>? queue,
    String? currentTrackPath,
    Set<BroadcastMixStyle>? activeMixStyles,
    int? customCueInMs,
    int? customMixOutMs,
  }) {
    return BroadcastState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentTrackPath: currentTrackPath ?? this.currentTrackPath,
      activeMixStyles: activeMixStyles ?? this.activeMixStyles,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
    );
  }
}

class BroadcastNotifier extends Notifier<BroadcastState> {
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
  BroadcastState build() {
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

    return BroadcastState();
  }

  int _calculateSmartTrim(int durationMs) {
    if (durationMs > 30000) return 10000;
    return 0;
  }

  int _calculateRadioMixOut(int durationMs) {
    if (durationMs > 60000) return durationMs - 20000;
    if (durationMs > 30000) return durationMs - 10000;
    return durationMs - 4000;
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_liveStrategy.getSessionPath());
      final data = {
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': state.currentTrackPath,
        'positionMs': state.position.inMilliseconds,
        'activeMixStyles': state.activeMixStyles.map((e) => e.index).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
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

      final activeMixStylesIdx =
          (data['activeMixStyles'] as List?)?.cast<int>() ?? [];
      final Set<BroadcastMixStyle> restoredStyles = activeMixStylesIdx
          .map((i) => BroadcastMixStyle.values[i])
          .toSet();

      state = state.copyWith(
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        activeMixStyles: restoredStyles.isNotEmpty
            ? restoredStyles
            : {BroadcastMixStyle.smooth},
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

  void shuffleQueue() {
    final list = List<File>.from(state.queue)..shuffle();
    state = state.copyWith(queue: list);
    _saveSnapshot();
  }

  Future<void> savePlaylist() async {
    if (state.queue.isEmpty) return;
    try {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'broadcast_playlist.json',
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

  void toggleMixStyle(BroadcastMixStyle style) {
    final currentStyles = Set<BroadcastMixStyle>.from(state.activeMixStyles);
    if (currentStyles.contains(style)) {
      if (currentStyles.length > 1) currentStyles.remove(style);
    } else {
      currentStyles.add(style);
    }
    state = state.copyWith(activeMixStyles: currentStyles);
    _saveSnapshot();
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
        final triggerMs = _calculateRadioMixOut(durMs);

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
        final triggerMs = _calculateRadioMixOut(dur.inMilliseconds);
        final cueInMs = _calculateSmartTrim(dur.inMilliseconds);
        state = state.copyWith(
          customCueInMs: cueInMs,
          customMixOutMs: triggerMs,
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

  Future<void> forceNext() async {
    if (_isCrossfading || state.queue.isEmpty) return;
    _triggerCrossfade(forceJit: true);
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
  }

  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required BroadcastMixStyle mixProfile,
  }) async {
    final String currentBaseFilter = ref
        .read(equalizerProvider.notifier)
        .currentBaseFilter;
    final String combinedFilter = currentBaseFilter;

    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    try {
      if (mixProfile == BroadcastMixStyle.echoOut) {
        platformOut?.setProperty('af', '$combinedFilter,aecho=0.8:0.9:500:0.5');
        await incomingPlayer.setVolume(100.0);
        await fadingPlayer.setVolume(50.0);
        await Future.delayed(const Duration(milliseconds: 1500));
      } else if (mixProfile == BroadcastMixStyle.vinylBrake) {
        platformOut?.setProperty('audio-pitch-correction', 'no');
        await incomingPlayer.setVolume(100.0);
        await fadingPlayer.setRate(0.05);
        await Future.delayed(const Duration(milliseconds: 1200));
      } else if (mixProfile == BroadcastMixStyle.automixDsp) {
        // Fallback dinámico a HAL
        final mixDuration = (Platform.isAndroid || Platform.isIOS)
            ? 4000
            : 8000;

        platformIn?.setProperty('af', '$combinedFilter,lowshelf=g=-24:f=250');
        await incomingPlayer.setVolume(100.0);
        await fadingPlayer.setVolume(100.0);

        await Future.delayed(Duration(milliseconds: mixDuration ~/ 2));

        platformOut?.setProperty('af', '$combinedFilter,lowshelf=g=-24:f=250');
        platformIn?.setProperty('af', combinedFilter);

        final fadeStopwatch = Stopwatch()..start();
        final fadeOutDurationMs = mixDuration ~/ 2;

        while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
          final progress =
              (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs).clamp(
                0.0,
                1.0,
              );
          final rateOut = cos(progress * (pi / 2));
          await fadingPlayer.setVolume((rateOut * 100.0).clamp(0.0, 100.0));
          await Future.delayed(const Duration(milliseconds: 32));
        }
      } else {
        await incomingPlayer.setVolume(100.0);
        final fadeStopwatch = Stopwatch()..start();
        const fadeOutDurationMs = 3000;

        while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
          final progress =
              (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs).clamp(
                0.0,
                1.0,
              );
          await fadingPlayer.setVolume(
            ((1.0 - progress) * 100).clamp(0.0, 100.0),
          );
          await Future.delayed(const Duration(milliseconds: 32));
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      await incomingPlayer.setVolume(100.0);
      await incomingPlayer.setRate(1.0);
      platformIn?.setProperty('audio-pitch-correction', 'yes');
      platformIn?.setProperty('af', combinedFilter);

      platformOut?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty('af', combinedFilter);
      await fadingPlayer.setVolume(100.0);
      await fadingPlayer.setRate(1.0);

      await fadingPlayer.stop();

      _isCrossfading = false;
    }
  }

  Future<void> _triggerCrossfade({bool forceJit = false}) async {
    if (_isCrossfading || state.queue.isEmpty) return;
    _isCrossfading = true;

    final String nextTrack = state.queue.first.path;
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 10000;

    final availableStyles = state.activeMixStyles.toList();
    BroadcastMixStyle mixProfile = BroadcastMixStyle.smooth;
    if (availableStyles.isNotEmpty) {
      mixProfile = availableStyles[Random().nextInt(availableStyles.length)];
    }

    if (!_isStandbyArmed || forceJit) {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
    }

    try {
      final dur = await incomingPlayer.stream.duration
          .firstWhere((d) => d.inMilliseconds > 0)
          .timeout(const Duration(milliseconds: 1500));
      cueInMs = _calculateSmartTrim(dur.inMilliseconds);
    } catch (_) {}

    if (cueInMs > 0) {
      await incomingPlayer.seek(Duration(milliseconds: cueInMs));
      await Future.delayed(const Duration(milliseconds: 200));
    }

    await incomingPlayer.setVolume(100.0);
    await incomingPlayer.play();

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    List<File> newQueue = List.from(state.queue);
    if (newQueue.isNotEmpty) newQueue.removeAt(0);

    state = state.copyWith(
      queue: newQueue,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
    );

    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixProfile: mixProfile,
    );
  }
}

final broadcastProvider = NotifierProvider<BroadcastNotifier, BroadcastState>(
  BroadcastNotifier.new,
);
