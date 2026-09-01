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

enum BroadcastMixStrategy { sequential, random }

enum BroadcastMixMode { activeSync, longBypass }

class BroadcastState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<File> queue;
  final String? currentTrackPath;
  final BroadcastMixMode currentMixMode;
  final int customCueInMs;
  final int customMixOutMs;

  BroadcastState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentTrackPath,
    this.currentMixMode = BroadcastMixMode.activeSync,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
  });

  BroadcastState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<File>? queue,
    String? currentTrackPath,
    BroadcastMixMode? currentMixMode,
    int? customCueInMs,
    int? customMixOutMs,
  }) {
    return BroadcastState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentTrackPath: currentTrackPath ?? this.currentTrackPath,
      currentMixMode: currentMixMode ?? this.currentMixMode,
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

  bool _isMixTrack(int durationMs) => durationMs > 600000; // > 10 minutos

  int _calculateSmartTrim(int durationMs) {
    if (_isMixTrack(durationMs)) return 0;
    if (durationMs > 30000) return 5000;
    return 0;
  }

  int _calculateRadioMixOut(int durationMs) {
    if (_isMixTrack(durationMs)) {
      return durationMs - 4000;
    }
    if (durationMs > 60000) return durationMs - 20000;
    return durationMs - 4000;
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_liveStrategy.getSessionPath());
      final data = {
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': state.currentTrackPath,
        'positionMs': state.position.inMilliseconds,
        'mixMode': state.currentMixMode.index,
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

      final mixModeIdx = data['mixMode'] as int? ?? 0;

      state = state.copyWith(
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        currentMixMode: BroadcastMixMode.values[mixModeIdx],
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
        final mode = _isMixTrack(dur.inMilliseconds)
            ? BroadcastMixMode.longBypass
            : BroadcastMixMode.activeSync;

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
    required BroadcastMixMode mixProfile,
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

      await incomingPlayer.setVolume(100.0);

      final fadeStopwatch = Stopwatch()..start();
      final fadeOutDurationMs = mixProfile == BroadcastMixMode.longBypass
          ? 4000
          : 20000;

      while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
        final progress = (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs)
            .clamp(0.0, 1.0);
        final rateOut = cos(progress * (pi / 2));

        await fadingPlayer.setVolume((rateOut * 100.0).clamp(0.0, 100.0));
        await Future.delayed(const Duration(milliseconds: 32));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      await incomingPlayer.setVolume(100.0);
      await incomingPlayer.setRate(1.0);
      platformIn?.setProperty('af', currentBaseFilter);

      platformOut?.setProperty('af', currentBaseFilter);
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

    if (!_isStandbyArmed || forceJit) {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
    }

    BroadcastMixMode nextMode = BroadcastMixMode.activeSync;

    try {
      final dur = await incomingPlayer.stream.duration
          .firstWhere((d) => d.inMilliseconds > 0)
          .timeout(const Duration(milliseconds: 1500));
      cueInMs = _calculateSmartTrim(dur.inMilliseconds);
      nextMode = _isMixTrack(dur.inMilliseconds)
          ? BroadcastMixMode.longBypass
          : BroadcastMixMode.activeSync;
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
      currentMixMode: nextMode,
    );

    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixProfile: state.currentMixMode,
    );
  }
}

final broadcastProvider = NotifierProvider<BroadcastNotifier, BroadcastState>(
  BroadcastNotifier.new,
);
