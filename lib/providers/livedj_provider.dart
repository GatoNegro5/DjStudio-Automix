import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import '../core/hal/platform_strategy.dart';
import '../core/audio/dj_audio_handler.dart';
import 'equalizer_provider.dart';
import 'mix_formula.dart';

enum LiveDjMixStrategy { sequential, random }

enum LiveDjMixMode { activeSync, longBypass }

// 🎚️ Corte de graves de la permuta de bajos: Butterworth de 2 polos a 140 Hz.
// Idéntico al de Automix. Se inyecta en libmpv vía 'af'; cero DSP por muestras.
const String _bassKillFilter = 'highpass=f=140:poles=2';

// 🎚️ Banda del fundido en cambios manuales; la pista entrante elige el punto.
const int _manualMixMinMs = 8000;
const int _manualMixMaxMs = 18000;

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
    bool clearCurrentTrackPath = false,
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
      currentTrackPath: clearCurrentTrackPath
          ? null
          : (currentTrackPath ?? this.currentTrackPath),
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
  bool _parking = false;
  bool _isStandbyArmed = false;
  // Pista realmente precargada en el deck standby. Si la cola cambia
  // (quitar, shuffle, otra pista) antes del cruce, se vuelve a cargar.
  String? _standbyArmedPath;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;
  int _lastUiPosMs = -1;
  int _sessionPositionMs = 0;
  bool _sessionWasPlaying = false;
  bool _freezePersist = false;
  bool _sessionHydrated = false;
  int _lastOsSecond = -1;

  late final PlatformMixStrategy _liveStrategy;

  @override
  LiveDjState build() {
    _playerA = Player();
    _playerB = Player();

    _liveStrategy = MixStrategyFactory.getStrategy();

    for (final Player deck in deckPlayers) {
      final dynamic platform = deck.platform;
      platform?.setProperty('vid', 'no');
      platform?.setProperty('af', _liveStrategy.hifiFilter);
    }

    _attachListeners(_playerA);
    _initPersistence();

    // TIPO DE MEZCLA persistente: cada cambio de fórmula baja a disco.
    ref.listen<MixFormula>(mixFormulaProvider, (previous, next) {
      if (previous == next || !_sessionHydrated) return;
      _saveSnapshot();
    });

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
    });

    return LiveDjState();
  }

  bool _isMixTrack(int durationMs) => durationMs > 600000;

  /// Cambio manual: el fundido lo dicta la pista entrante — compases 4/4 sobre
  /// su BPM acotados a 8–18 s. Idéntico criterio que Automix.
  int _planManualMixDurationMs(String? incomingPath, int incomingDurationMs) {
    final double bpm = _extractBpm(incomingPath);
    if (bpm >= 60 && bpm <= 200) {
      final double barMs = (60000.0 / bpm) * 4;
      for (final int bars in const [16, 8, 4, 2]) {
        final int span = (barMs * bars).round();
        if (span >= _manualMixMinMs && span <= _manualMixMaxMs) return span;
      }
    }
    if (incomingDurationMs > 0) {
      return (incomingDurationMs * 0.06).round().clamp(
        _manualMixMinMs,
        _manualMixMaxMs,
      );
    }
    return 12000;
  }

  double _extractBpm(String? path) {
    if (path == null) return 0.0;
    final fileName = path.replaceAll('\\', '/').split('/').last;
    final match = RegExp(
      r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
      caseSensitive: false,
    ).firstMatch(fileName);
    return match != null ? double.parse(match.group(1)!) : 0.0;
  }

  Future<int> _calculateSmartCueIn(String path, Player player) async {
    if (_isMixTrack(player.state.duration.inMilliseconds)) return 0;
    final int durMs = player.state.duration.inMilliseconds;
    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthCueInMs(durMs, const []);
    }
    if (durMs > 30000) return 10000;
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

    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthMixOutMs(
        durationMs: durationMs,
        lyricMs: const [],
        bpm: _extractBpm(path),
      );
    }
    if (ref.read(mixFormulaProvider) == MixFormula.phraseGrid) {
      return snapPhraseGridMixOut(
        durationMs: durationMs,
        dnaMixOutMs: safeMixOutMs,
        bpm: _extractBpm(path),
      );
    }
    return safeMixOutMs;
  }

  Future<void> persistSession() => _saveSnapshot();

  bool _pausedByInterruption = false;

  /// Llamada/alarma/otra app: pausa ambos decks (también a mitad de un cruce)
  /// sin tocar cola, posición ni sesión. Devuelve `true` si estaba sonando.
  Future<bool> pauseForInterruption() async {
    if (!state.isPlaying) return false;
    _pausedByInterruption = true;
    try {
      await _playerA.pause();
    } catch (_) {}
    try {
      await _playerB.pause();
    } catch (_) {}
    _saveSnapshot();
    return true;
  }

  /// Reanuda exactamente donde quedó, solo si la pausa la causó el sistema.
  Future<void> resumeAfterInterruption() async {
    if (!_pausedByInterruption) return;
    _pausedByInterruption = false;
    try {
      await _activePlayer.play();
    } catch (_) {}
    if (_isCrossfading) {
      try {
        await _standbyPlayer.play();
      } catch (_) {}
    }
  }

  int? _readSavedUiRoute() {
    try {
      final session = _liveStrategy.getSessionPath();
      final file = File(
        '${File(session).parent.path}${Platform.pathSeparator}_ui_route.json',
      );
      if (!file.existsSync()) return null;
      final data = jsonDecode(file.readAsStringSync());
      final route = data['route'];
      if (route is int && route >= 0 && route < 7) return route;
    } catch (_) {}
    return null;
  }

  String _sessionFilePath() {
    final shared = _liveStrategy.getSessionPath();
    return '${File(shared).parent.path}${Platform.pathSeparator}_livedj_session.json';
  }

  File _resolveSessionFile() {
    return File(_sessionFilePath());
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_sessionFilePath());
      final pos = _freezePersist
          ? _sessionPositionMs
          : state.position.inMilliseconds;
      final data = {
        'queue': state.queue.map((f) => f.path).toList(),
        'currentTrackPath': state.currentTrackPath,
        'positionMs': pos,
        'mixMode': state.currentMixMode.index,
        'mixStrategy': state.mixStrategy.index,
        'mixFormula': ref.read(mixFormulaProvider).index,
        'wasPlaying': _freezePersist ? _sessionWasPlaying : state.isPlaying,
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
      _applyLiveShuffleBank(advance: true);
    } catch (e, stack) {
      debugPrint("🔴 [TRACKER ERROR FATAL] El Shuffle explotó: $e\n$stack");
    }
  }

  String _liveShuffleBanksPath() {
    final session = File(_sessionFilePath());
    return '${session.parent.path}${Platform.pathSeparator}_livedj_shuffle_banks.json';
  }

  String _liveShuffleListKey(List<String> paths) {
    final sorted = List<String>.from(paths)..sort();
    return jsonEncode(sorted);
  }

  Map<String, dynamic> _readLiveShuffleBankFile() {
    try {
      final file = File(_liveShuffleBanksPath());
      if (!file.existsSync()) return <String, dynamic>{};
      final data = jsonDecode(file.readAsStringSync());
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    return <String, dynamic>{};
  }

  void _writeLiveShuffleBankFile(Map<String, dynamic> data) {
    try {
      File(_liveShuffleBanksPath()).writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  List<List<String>> _buildTenLiveShuffleBanks(List<String> paths) {
    final banks = <List<String>>[];
    final seen = <String>{};
    var salt = 1;
    while (banks.length < 10 && salt < 400) {
      final copy = List<String>.from(paths);
      copy.shuffle(Random(salt * 9973 + paths.length * 13));
      final sig = copy.join('\n');
      if (seen.add(sig)) banks.add(copy);
      salt++;
    }
    while (banks.length < 10) {
      banks.add(List<String>.from(paths));
    }
    return banks;
  }

  void _applyLiveShuffleBank({required bool advance}) {
    if (state.queue.length <= 1) {
      debugPrint("⚠️ [TRACKER] Cola muy pequeña. Forzando solo UI.");
      state = state.copyWith(mixStrategy: LiveDjMixStrategy.random);
      _saveSnapshot();
      return;
    }

    final paths = state.queue.map((f) => f.path).toList();
    final key = _liveShuffleListKey(paths);
    final all = _readLiveShuffleBankFile();
    final int spin = (all['spin'] as int?) ?? 0;
    final lists = Map<String, dynamic>.from(
      (all['lists'] as Map?) ?? <String, dynamic>{},
    );
    Map<String, dynamic> entry = <String, dynamic>{};
    final raw = lists[key];
    if (raw is Map) entry = Map<String, dynamic>.from(raw);

    List<List<String>> banks = <List<String>>[];
    final rawBanks = entry['banks'];
    if (rawBanks is List) {
      for (final row in rawBanks) {
        if (row is List) {
          banks.add(row.map((e) => e.toString()).toList());
        }
      }
    }
    final bool sameSet = banks.length == 10 &&
        banks.every((row) {
          if (row.length != paths.length) return false;
          final a = List<String>.from(row)..sort();
          final b = List<String>.from(paths)..sort();
          return listEquals(a, b);
        });
    if (!sameSet) {
      banks = _buildTenLiveShuffleBanks(paths);
      final int previous = (entry['cursor'] as int?) ?? -1;
      final int carried = previous >= 0 ? previous : (spin % 10) - 1;
      if (previous < 0) all['spin'] = (spin + 1) % 10;
      entry = <String, dynamic>{'cursor': carried, 'banks': banks};
    }

    final int last = (entry['cursor'] as int?) ?? -1;
    final int use = advance
        ? (last + 1) % 10
        : (last < 0 ? 0 : last % 10);
    final List<String> order = List<String>.from(banks[use]);
    final known = paths.toSet();
    final queued = <File>[
      for (final path in order)
        if (known.contains(path)) File(path),
    ];
    for (final path in paths) {
      if (!queued.any((f) => f.path == path)) queued.add(File(path));
    }

    entry['cursor'] = use;
    entry['banks'] = banks;
    lists[key] = entry;
    all['lists'] = lists;
    _writeLiveShuffleBankFile(all);

    state = state.copyWith(
      queue: queued,
      mixStrategy: LiveDjMixStrategy.random,
    );
    _saveSnapshot();
    debugPrint(
      "🔀 [TRACKER] Shuffle banco ${use + 1}/10. ${queued.length} pistas.",
    );
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
      final file = _resolveSessionFile();
      if (!file.existsSync()) return;

      final content = await file.readAsString();
      final data = jsonDecode(content);

      final queuePaths = (data['queue'] as List?)?.cast<String>() ?? [];
      final queueFiles = queuePaths
          .map((p) => File(p))
          .where((f) => f.existsSync())
          .toList();
      String? currentTrackPath = data['currentTrackPath'] as String?;
      if (currentTrackPath != null && !File(currentTrackPath).existsSync()) {
        currentTrackPath = null;
      }
      if (currentTrackPath == null && queueFiles.isNotEmpty) {
        // La pista que pasa a "actual" sale de la cola (cartridge destructiva);
        // si no, volvería a sonar al terminar.
        currentTrackPath = queueFiles.removeAt(0).path;
      }
      final positionMs = data['positionMs'] as int?;

      final mixModeIdx = data['mixMode'] as int? ?? 0;
      final mixStrategyIdx = data['mixStrategy'] as int? ?? 0;
      final mixFormulaIdx = data['mixFormula'] as int? ?? 0;
      if (mixFormulaIdx >= 0 && mixFormulaIdx < MixFormula.values.length) {
        ref.read(mixFormulaProvider.notifier).state =
            MixFormula.values[mixFormulaIdx];
      }

      if (state.queue.isNotEmpty || state.currentTrackPath != null) {
        return;
      }

      state = state.copyWith(
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        currentMixMode: LiveDjMixMode.values[mixModeIdx],
        mixStrategy: LiveDjMixStrategy.values[mixStrategyIdx],
      );

      _freezePersist = false;
      if (currentTrackPath != null && _readSavedUiRoute() == 5) {
        await _activePlayer.open(Media(currentTrackPath), play: false);
        ref.read(liveDjEqualizerProvider.notifier).adapt(_activePlayer, currentTrackPath);
        try {
          await _activePlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
        if (positionMs != null && positionMs > 0) {
          await _activePlayer.seek(Duration(milliseconds: positionMs));
          _sessionPositionMs = positionMs;
        }
        final wasPlaying = data['wasPlaying'] as bool? ?? false;
        if (wasPlaying) {
          await _activePlayer.play();
        }
      }
      // El orden guardado de la cola es la verdad: no se re-mezcla al reabrir.
    } catch (_) {
    } finally {
      _sessionHydrated = true;
    }
  }

  void addTrack(File file) {
    if (!state.queue.any((f) => f.path == file.path)) {
      // Cola estable: la pista nueva va al final; lo ya cargado no se mueve
      // ni cambia de modo (secuencial/shuffle solo lo cambia el botón).
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
      // Cola estable: solo se mezcla el lote nuevo (y solo en modo shuffle);
      // lo ya cargado conserva su orden.
      if (state.mixStrategy == LiveDjMixStrategy.random) {
        newFiles.shuffle(Random());
      }
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
          final currentPaths = state.queue.map((f) => f.path).toSet();
          final fresh = newFiles
              .where((f) => !currentPaths.contains(f.path))
              .toList();
          if (state.mixStrategy == LiveDjMixStrategy.random) {
            fresh.shuffle(Random());
          }
          if (fresh.isNotEmpty) {
            state = state.copyWith(queue: [...state.queue, ...fresh]);
            _saveSnapshot();
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR] Cargando playlist: $e");
    }
  }

  Future<void> playTrackFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length || _isCrossfading) return;

    // La pista tocada suena tal cual; el resto de la cola NO se reordena.
    _isPrepModeBypass = false;
    await forceNext(queueIndex: index);
  }

  void _attachListeners(Player player) {
    _lastUiPosMs = -1;
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) async {
      final posMs = pos.inMilliseconds;
      final durMs = state.duration.inMilliseconds;

      if ((posMs - _lastUiPosMs).abs() >= 120) {
        _lastUiPosMs = posMs;
        state = state.copyWith(position: pos);
      }

      // Servicio en primer plano (Android): sin esto el SO mata el proceso
      // en segundo plano / pantalla apagada. Un latido por segundo.
      final int osSecond = posMs ~/ 1000;
      if (osSecond != _lastOsSecond) {
        _lastOsSecond = osSecond;
        globalAudioHandler.syncOs(
          owner: 'livedj',
          path: state.currentTrackPath,
          duration: state.duration,
          playing: state.isPlaying,
          position: pos,
        );
      }

      if (!_freezePersist) {
        _sessionPositionMs = posMs;
        _sessionWasPlaying = state.isPlaying;
      }

      if ((posMs - _lastSavedPositionMs).abs() > 15000) {
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
          final String armPath = state.queue[_nextQueueIndex()].path;
          _standbyArmedPath = armPath;
          await _standbyPlayer.setVolume(0.0);
          await _standbyPlayer.open(
            Media(armPath),
            play: false,
          );
          ref.read(liveDjEqualizerProvider.notifier).adapt(_standbyPlayer, armPath);
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
        globalAudioHandler.syncOs(
          owner: 'livedj',
          path: state.currentTrackPath,
          duration: dur,
          playing: state.isPlaying,
          position: state.position,
        );
        final triggerMs = _calculateRadioMixOut(
          dur.inMilliseconds,
          state.currentTrackPath,
        );
        final cueInMs = await _calculateSmartCueIn(
          state.currentTrackPath!,
          player,
        );
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
      if (_parking) return;
      if (playing == state.isPlaying) return;
      state = state.copyWith(isPlaying: playing);
      if (playing) {
        // Controles de notificación/auriculares: el que suena es el dueño.
        globalAudioHandler.claim(
          'livedj',
          onPlayPause: () => togglePlayPause(),
          onPause: () async {
            if (state.isPlaying) await togglePlayPause();
          },
          onNext: () => forceNext(),
          // Anterior: reinicia la canción (la cola Live DJ es FIFO destructiva).
          onPrevious: () => seek(Duration.zero),
          onSeek: (pos) => seek(pos),
          isPlaying: () => state.isPlaying,
        );
      }
      globalAudioHandler.syncOs(
        owner: 'livedj',
        path: state.currentTrackPath,
        duration: state.duration,
        playing: playing,
        position: state.position,
      );
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (!completed || !_sessionHydrated) return;
      _isPrepModeBypass = false;
      _isCrossfading = false;
      if (state.queue.isNotEmpty) {
        forceNext();
      } else {
        unawaited(_stopWhenNoNext());
      }
    });
  }

  Future<void> togglePlayPause() async {
    if (state.queue.isEmpty && state.currentTrackPath == null) return;

    _isPrepModeBypass = false;
    _freezePersist = false;

    if (state.currentTrackPath == null && state.queue.isNotEmpty) {
      await forceNext();
      return;
    }

    final path = state.currentTrackPath;
    final deckEmpty = _activePlayer.state.duration.inMilliseconds <= 0;
    if (path != null && deckEmpty) {
      if (!File(path).existsSync()) {
        if (state.queue.isNotEmpty) {
          await forceNext();
        }
        return;
      }
      try {
        await _activePlayer.open(Media(path), play: true);
        ref.read(liveDjEqualizerProvider.notifier).adapt(_activePlayer, path);
        _attachListeners(_activePlayer);
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN]: $e");
        if (state.queue.isNotEmpty) await forceNext();
      }
      _saveSnapshot();
      return;
    }

    await _activePlayer.playOrPause();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
  }

  Future<void> forceNext({int? queueIndex}) async {
    if (_isCrossfading) return;
    if (state.queue.isEmpty) {
      await _stopWhenNoNext();
      return;
    }
    await _triggerCrossfade(
      forceJit: true,
      isManualSkip: true,
      queueIndex: queueIndex,
    );
  }

  Future<void> _stopWhenNoNext() async {
    _isCrossfading = false;
    try {
      await _playerA.pause();
    } catch (_) {}
    try {
      await _playerB.pause();
    } catch (_) {}
    try {
      await _playerA.stop();
    } catch (_) {}
    try {
      await _playerB.stop();
    } catch (_) {}
    // Fin de cola: no queda nada en memoria. Sin pista residual, la próxima
    // carga arranca desde la primera canción de la cola nueva.
    _isStandbyArmed = false;
    _isPrepModeBypass = false;
    _sessionPositionMs = 0;
    _sessionWasPlaying = false;
    _lastSavedPositionMs = 0;
    state = state.copyWith(
      isPlaying: false,
      clearCurrentTrackPath: true,
      position: Duration.zero,
      duration: Duration.zero,
      customCueInMs: -1,
      customMixOutMs: -1,
    );
    _saveSnapshot();
  }

  int _nextQueueIndex() {
    if (state.queue.isEmpty) return -1;
    if (ref.read(mixFormulaProvider) != MixFormula.stealthGap ||
        state.currentTrackPath == null) {
      return 0;
    }
    final int picked = pickStealthNextIndex(
      remaining: state.queue.map((f) => f.path).toList(),
      currentPath: state.currentTrackPath,
      bpmOf: _extractBpm,
    );
    return picked < 0 ? 0 : picked;
  }

  Future<void> _triggerCrossfade({
    bool forceJit = false,
    bool isManualSkip = false,
    int? queueIndex,
  }) async {
    if (_isCrossfading || state.queue.isEmpty) return;
    _isCrossfading = true;

    final int nextIdx = queueIndex ?? _nextQueueIndex();
    if (nextIdx < 0 || nextIdx >= state.queue.length) {
      _isCrossfading = false;
      await _stopWhenNoNext();
      return;
    }
    final String nextTrack = state.queue[nextIdx].path;
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    if (!_isStandbyArmed || forceJit || _standbyArmedPath != nextTrack) {
      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
        ref.read(liveDjEqualizerProvider.notifier).adapt(incomingPlayer, nextTrack);
        try {
          await incomingPlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN]: $e");
      }
    }

    Duration trackDur = Duration.zero;
    try {
      trackDur = incomingPlayer.state.duration;
    } catch (_) {}

    final int cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
    final int triggerMs = _calculateRadioMixOut(
      trackDur.inMilliseconds,
      nextTrack,
    );
    final LiveDjMixMode nextMode = _isMixTrack(trackDur.inMilliseconds)
        ? LiveDjMixMode.longBypass
        : LiveDjMixMode.activeSync;

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }

    try {
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    // Se quita por ruta (no por índice): la cola pudo cambiar durante la
    // carga (quitar, añadir, shuffle) y un índice viejo borraría otra pista.
    List<File> newQueue = List.from(state.queue);
    final int removeAt = newQueue.indexWhere((f) => f.path == nextTrack);
    if (removeAt >= 0) newQueue.removeAt(removeAt);

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
      mixProfile: nextMode,
      incomingRate: incomingRate,
      isManualSkip: isManualSkip,
      manualMixDurationMs: isManualSkip
          ? _planManualMixDurationMs(nextTrack, trackDur.inMilliseconds)
          : null,
    );
  }

  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required LiveDjMixMode mixProfile,
    double incomingRate = 1.0,
    bool isManualSkip = false,
    int? manualMixDurationMs,
  }) async {
    final eqN = ref.read(liveDjEqualizerProvider.notifier);
    String inBase() => eqN.filterFor(incomingPlayer);
    String outBase() => eqN.filterFor(fadingPlayer);
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    final bool useBassSwap = mixProfile == LiveDjMixMode.activeSync;
    final String lowCutIn = '${inBase()},$_bassKillFilter';
    final String lowCutOut = '${outBase()},$_bassKillFilter';
    bool bassSwapped = false;

    try {
      platformIn?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty('audio-pitch-correction', 'yes');
      platformIn?.setProperty(
        'af',
        useBassSwap ? lowCutIn : inBase(),
      );
      platformOut?.setProperty('af', outBase());

      await incomingPlayer.setVolume(0.0);

      final fadeStopwatch = Stopwatch()..start();
      final fadeOutDurationMs = isManualSkip
          ? (manualMixDurationMs ?? 12000)
          : (mixProfile == LiveDjMixMode.longBypass
                ? 4000
                : (ref.read(mixFormulaProvider) == MixFormula.phraseGrid ||
                          ref.read(mixFormulaProvider) == MixFormula.stealthGap
                      ? phraseFadeMs(
                          incomingBpm: _extractBpm(state.currentTrackPath),
                          incomingDurationMs: state.duration.inMilliseconds,
                        )
                      : 18000));

      while (fadeStopwatch.elapsedMilliseconds < fadeOutDurationMs) {
        final progress = (fadeStopwatch.elapsedMilliseconds / fadeOutDurationMs)
            .clamp(0.0, 1.0);

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final rateIn = (progress * 1.8).clamp(0.0, 1.0);
        final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);

        final smoothRateIn = pow(rateIn, 1.2).toDouble();
        final smoothRateOut = pow(rateOut, 1.2).toDouble();

        if (useBassSwap && !bassSwapped && progress >= 0.5) {
          bassSwapped = true;
          platformOut?.setProperty('af', lowCutOut);
          platformIn?.setProperty('af', inBase());
        }

        await incomingPlayer.setVolume(
          (smoothRateIn * 100.0).clamp(0.0, 100.0),
        );
        await fadingPlayer.setVolume((smoothRateOut * 100.0).clamp(0.0, 100.0));

        await Future.delayed(const Duration(milliseconds: 32));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP]: $e");
    } finally {
      final bool willGlideRate = incomingRate != 1.0;

      try {
        await incomingPlayer.setVolume(100.0);
        if (!willGlideRate) await incomingPlayer.setRate(1.0);
        platformIn?.setProperty('af', inBase());
        platformOut?.setProperty('af', outBase());
        await fadingPlayer.setVolume(0.0);
        await fadingPlayer.setRate(1.0);
        await fadingPlayer.stop();
      } catch (_) {}

      if (willGlideRate) {
        try {
          final pitchStopwatch = Stopwatch()..start();
          final double rateDiff = 1.0 - incomingRate;
          while (pitchStopwatch.elapsedMilliseconds < 3000) {
            final double p = (pitchStopwatch.elapsedMilliseconds / 3000).clamp(
              0.0,
              1.0,
            );
            final double curve = sin(p * (pi / 2));
            await incomingPlayer.setRate(incomingRate + (rateDiff * curve));
            await Future.delayed(const Duration(milliseconds: 50));
          }
        } catch (_) {}
        try {
          await incomingPlayer.setRate(1.0);
        } catch (_) {}
      }

      _isCrossfading = false;
    }
  }

  Future<void> parkIdleDecks({bool force = false}) async {
    if (_parking) return;
    if (!force && (state.isPlaying || _isCrossfading)) return;
    _parking = true;
    try {
      if (force) _isCrossfading = false;
      _sessionWasPlaying = state.isPlaying;
      if (state.position.inMilliseconds > 0) {
        _sessionPositionMs = state.position.inMilliseconds;
      }
      _freezePersist = true;
      if (state.currentTrackPath != null || state.queue.isNotEmpty) {
        await _saveSnapshot();
      }
      try {
        await _playerA.pause();
      } catch (_) {}
      try {
        await _playerB.pause();
      } catch (_) {}
      try {
        await _playerA.stop();
      } catch (_) {}
      try {
        await _playerB.stop();
      } catch (_) {}
      if (state.isPlaying) state = state.copyWith(isPlaying: false);
    } finally {
      _parking = false;
    }
  }
}

final liveDjProvider = NotifierProvider<LiveDjNotifier, LiveDjState>(
  LiveDjNotifier.new,
);
