import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum BroadcastMixStrategy { sequential, random }

enum BroadcastMixStyle { smooth, vinylBrake, echoOut, slamCut }

class BroadcastState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<File> queue;
  final int currentIndex;
  final BroadcastMixStrategy mixStrategy;
  final Set<BroadcastMixStyle> activeMixStyles;

  BroadcastState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.queue = const [],
    this.currentIndex = -1,
    this.mixStrategy = BroadcastMixStrategy.sequential,
    this.activeMixStyles = const {
      BroadcastMixStyle.smooth,
      BroadcastMixStyle.echoOut,
      BroadcastMixStyle.slamCut,
    },
  });

  BroadcastState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<File>? queue,
    int? currentIndex,
    BroadcastMixStrategy? mixStrategy,
    Set<BroadcastMixStyle>? activeMixStyles,
  }) {
    return BroadcastState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
      mixStrategy: mixStrategy ?? this.mixStrategy,
      activeMixStyles: activeMixStyles ?? this.activeMixStyles,
    );
  }
}

class BroadcastNotifier extends Notifier<BroadcastState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activePlayer => _usePlayerA ? _playerA : _playerB;
  Player get _standbyPlayer => _usePlayerA ? _playerB : _playerA;

  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _completedSub;

  bool _isCrossfading = false;
  bool _isStandbyArmed = false;
  int _lastSavedPositionMs = 0;

  // 🛠️ CONFIGURACIÓN DE BROADCAST (Hardcoded Best Practices)
  final int _overlapDurationMs = 12000; // 12 Segundos de cruce estándar
  final int _preFlightTriggerMs = 24000; // Carga en memoria 24s antes

  // 🛠️ DSP BASE: Normalización EBU R128 + Ensanchador Estéreo
  final String _baseHifi =
      'loudnorm=I=-14:TP=-1.5:LRA=11,aresample=resampler=soxr:precision=28,crystalizer=i=2.0,bass=g=3:f=60,extrastereo=m=1.15';

  @override
  BroadcastState build() {
    _playerA = Player();
    _playerB = Player();

    (_playerA.platform as dynamic)?.setProperty('af', _baseHifi);
    (_playerB.platform as dynamic)?.setProperty('af', _baseHifi);

    _attachListeners(_playerA);
    _initPersistence();

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
      _playerA.dispose();
      _playerB.dispose();
    });

    return BroadcastState();
  }

  // ==========================================
  // PERSISTENCIA Y RECUPERACIÓN (Sandboxing)
  // ==========================================
  String _getSessionFilePath() {
    String baseDir = Platform.isWindows
        ? '${Platform.environment['USERPROFILE']}\\Music\\DjPlaylists'
        : '/storage/emulated/0/Music/DjPlaylists';
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_broadcast_session.json';
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_getSessionFilePath());
      final data = {
        'queue': state.queue.map((f) => f.path).toList(),
        'currentIndex': state.currentIndex,
        'positionMs': state.position.inMilliseconds,
        'mixStrategy': state.mixStrategy.index,
        'activeMixStyles': state.activeMixStyles.map((e) => e.index).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _initPersistence() async {
    try {
      final file = File(_getSessionFilePath());
      if (!file.existsSync()) return;

      final content = await file.readAsString();
      final data = jsonDecode(content);

      final queuePaths = (data['queue'] as List?)?.cast<String>() ?? [];
      final queueFiles = queuePaths
          .map((p) => File(p))
          .where((f) => f.existsSync())
          .toList();

      final index = data['currentIndex'] as int?;
      final positionMs = data['positionMs'] as int?;
      final mixStrategyIdx = data['mixStrategy'] as int? ?? 0;

      final activeMixStylesIdx =
          (data['activeMixStyles'] as List?)?.cast<int>() ?? [];
      final Set<BroadcastMixStyle> restoredStyles = activeMixStylesIdx
          .map((i) => BroadcastMixStyle.values[i])
          .toSet();

      state = state.copyWith(
        queue: queueFiles,
        currentIndex: index,
        mixStrategy: BroadcastMixStrategy.values[mixStrategyIdx],
        activeMixStyles: restoredStyles.isNotEmpty
            ? restoredStyles
            : {BroadcastMixStyle.smooth},
      );

      if (queueFiles.isNotEmpty &&
          index != null &&
          index >= 0 &&
          index < queueFiles.length) {
        await _activePlayer.open(Media(queueFiles[index].path), play: false);
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

  // ==========================================
  // CONTROLES DE COLA Y ESTADO
  // ==========================================
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
    state = state.copyWith(
      queue: [],
      currentIndex: -1,
      position: Duration.zero,
    );
    _activePlayer.stop();
    _saveSnapshot();
  }

  void setMixStrategy(BroadcastMixStrategy strategy) {
    state = state.copyWith(mixStrategy: strategy);
    _saveSnapshot();
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

  // ==========================================
  // MOTOR AOT (SHADOW LOADING)
  // ==========================================
  int _calculateNextIndex() {
    if (state.queue.isEmpty) return -1;
    if (state.mixStrategy == BroadcastMixStrategy.random) {
      return Random().nextInt(state.queue.length);
    }
    return (state.currentIndex + 1) < state.queue.length
        ? state.currentIndex + 1
        : (state.currentIndex == -1 ? 0 : -1);
  }

  Future<void> _shadowLoadNextTrack() async {
    if (_isStandbyArmed) return;
    final nextIdx = _calculateNextIndex();
    if (nextIdx == -1) return;

    _isStandbyArmed = true;
    final nextPath = state.queue[nextIdx].path;

    await _standbyPlayer.setVolume(0.0);
    await _standbyPlayer.open(Media(nextPath), play: false);

    debugPrint("⚡ [BROADCAST AOT]: Pista cargada en memoria: $nextPath");
  }

  // ==========================================
  // EVENT LOOP Y GATILLOS
  // ==========================================
  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) {
      final posMs = pos.inMilliseconds;
      final durMs = state.duration.inMilliseconds;

      state = state.copyWith(position: pos);

      if ((posMs - _lastSavedPositionMs).abs() > 5000) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (durMs > 0 && !_isCrossfading) {
        final timeRemainingMs = durMs - posMs;

        // Fase 1: Calentamiento de Codec (24 segs)
        if (timeRemainingMs <= _preFlightTriggerMs && !_isStandbyArmed) {
          _shadowLoadNextTrack();
        }

        // Fase 2: Ejecución Atómica (12 segs)
        if (timeRemainingMs <= _overlapDurationMs) {
          _triggerCrossfade();
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (completed && !_isCrossfading) {
        debugPrint("🔴 [EOF]: Failsafe activado. Forzando transición...");
        _triggerCrossfade();
      }
    });
  }

  // ==========================================
  // TRANSPORTE MANUAL
  // ==========================================
  Future<void> togglePlayPause() async {
    if (state.queue.isEmpty) return;
    if (state.currentIndex == -1) {
      await loadAndPlay(0);
      return;
    }
    await _activePlayer.playOrPause();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> loadAndPlay(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    _isStandbyArmed = false;
    _isCrossfading = false;

    state = state.copyWith(currentIndex: index);
    _saveSnapshot();

    final path = state.queue[index].path;
    await _activePlayer.setVolume(100.0);
    await _activePlayer.open(Media(path), play: true);
  }

  Future<void> forceNext() async {
    if (_isCrossfading) return;
    final nextIdx = _calculateNextIndex();
    if (nextIdx != -1) {
      _triggerCrossfade(forceJit: true);
    }
  }

  Future<void> seek(Duration position) async {
    if (_isCrossfading) return;
    await _activePlayer.seek(position);
  }

  // ==========================================
  // WALL-CLOCK MIX ENGINE (DSP INYECTADO)
  // ==========================================
  Future<void> _triggerCrossfade({bool forceJit = false}) async {
    if (_isCrossfading) return;
    _isCrossfading = true;

    final int nextIndex = _calculateNextIndex();
    if (nextIndex == -1) {
      _isCrossfading = false;
      return;
    }

    final String nextPath = state.queue[nextIndex].path;
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    // Fail-safe si el AOT no se gatilló (Ej. Salto manual)
    if (!_isStandbyArmed || forceJit) {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextPath), play: false);
      try {
        await incomingPlayer.stream.duration
            .firstWhere((d) => d.inMilliseconds > 0)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    // RNG Profile Selection
    final availableStyles = state.activeMixStyles.toList();
    final selectedStyle =
        availableStyles[Random().nextInt(availableStyles.length)];
    int mixDurationMs = _overlapDurationMs;

    // Ajuste dinámico de duración según el estilo
    if (selectedStyle == BroadcastMixStyle.vinylBrake) mixDurationMs = 5000;
    if (selectedStyle == BroadcastMixStyle.slamCut) mixDurationMs = 4000;

    // Inyección Pre-Filtros C++
    if (selectedStyle == BroadcastMixStyle.echoOut) {
      (fadingPlayer.platform as dynamic)?.setProperty(
        'af',
        '$_baseHifi,aecho=0.8:0.9:1000:0.5',
      );
    }

    // Disparo Atómico Físico (Rate bloqueado a 1.0 = Pureza total)
    await incomingPlayer.setRate(1.0);
    await incomingPlayer.play();

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    state = state.copyWith(currentIndex: nextIndex);
    _saveSnapshot();

    debugPrint(
      "🎛️ [BROADCAST MIX] Ejecutando: ${selectedStyle.name} ($mixDurationMs ms)",
    );

    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsedMilliseconds < mixDurationMs) {
      final double progress = (stopwatch.elapsedMilliseconds / mixDurationMs)
          .clamp(0.0, 1.0);
      double volOut = 100.0, volIn = 100.0;
      double rateOut = 1.0;

      switch (selectedStyle) {
        case BroadcastMixStyle.vinylBrake:
          if (progress < 0.4) {
            rateOut = 1.0 - (progress / 0.4) * 0.95;
            volOut = 100.0 - (progress / 0.4) * 80.0;
            volIn = progress * 100.0;
          } else {
            rateOut = 0.05;
            volOut = 0.0;
            volIn = 100.0;
          }
          break;
        case BroadcastMixStyle.echoOut:
          volOut = (1.0 - progress) * 100.0;
          volIn = progress * 100.0;
          break;
        case BroadcastMixStyle.slamCut:
          volIn = progress < 0.1 ? (progress / 0.1) * 100.0 : 100.0;
          volOut = progress < 0.3 ? 100.0 - (progress / 0.3) * 100.0 : 0.0;
          break;
        case BroadcastMixStyle.smooth:
          volOut = cos(progress * (pi / 2)) * 100.0;
          volIn = sin(progress * (pi / 2)) * 100.0;
          break;
      }

      await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
      await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));

      if (selectedStyle == BroadcastMixStyle.vinylBrake &&
          rateOut >= 0.05 &&
          rateOut <= 1.0) {
        await fadingPlayer.setRate(rateOut);
      }

      await Future.delayed(const Duration(milliseconds: 16));
    }

    // Purga de colas y reseteo C++
    await fadingPlayer.stop();
    await fadingPlayer.setVolume(100.0);
    await fadingPlayer.setRate(1.0);
    if (selectedStyle == BroadcastMixStyle.echoOut) {
      (fadingPlayer.platform as dynamic)?.setProperty('af', _baseHifi);
    }

    _isCrossfading = false;
  }
}

final broadcastProvider = NotifierProvider<BroadcastNotifier, BroadcastState>(
  BroadcastNotifier.new,
);
