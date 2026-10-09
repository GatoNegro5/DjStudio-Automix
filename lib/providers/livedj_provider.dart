import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;
import '../core/hal/platform_strategy.dart';
import '../core/audio/af_caps.dart';
import '../services/track_tags.dart';
import '../core/audio/dj_audio_handler.dart';
import 'equalizer_provider.dart';
import 'mix_formula.dart';
import 'directory_provider.dart';
import '../djiphone/iphone_library.dart';

enum LiveDjMixStrategy { sequential, random }

enum LiveDjMixMode { activeSync, longBypass }

// 🎚️ Corte de graves de la permuta de bajos: Butterworth de 2 polos a 140 Hz.
// Idéntico al de Automix. Se inyecta en libmpv vía 'af'; cero DSP por muestras.
// Corte de graves con `equalizer` (único filtro de libavfilter que trae el
// libmpv empaquetado; `highpass` no existe y tumbaba toda la cadena `af`).
const String _bassKillFilter =
    'equalizer=f=45:width_type=o:w=2.5:g=-24,equalizer=f=110:width_type=o:w=1.6:g=-14';

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
  // ON AIR Radio: con la radio encendida la cola queda congelada y el motor
  // toma pistas del universo de Música filtrado por géneros.
  final bool radioOn;
  final Set<String> radioGenres;
  // Pista que la Radio ya eligió para sonar a continuación (null = sin elegir).
  final String? radioNextPath;

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
    this.radioOn = false,
    this.radioGenres = const <String>{},
    this.radioNextPath,
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
    bool? radioOn,
    Set<String>? radioGenres,
    String? radioNextPath,
    bool clearRadioNextPath = false,
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
      radioOn: radioOn ?? this.radioOn,
      radioGenres: radioGenres ?? this.radioGenres,
      radioNextPath: clearRadioNextPath
          ? null
          : (radioNextPath ?? this.radioNextPath),
    );
  }
}

/// Géneros de la Radio (id → carpetas de Música que lo componen, por nombre).
const List<String> kRadioGenreIds = [
  'actuales',
  'bailable',
  'romanticas',
  'ochenteras',
  'rock',
];

const Map<String, String> kRadioGenreLabels = {
  'actuales': 'Actuales',
  'bailable': 'Bailable',
  'romanticas': 'Románticas',
  'ochenteras': 'Ochenteras',
  'rock': 'Rock',
};

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
    if (match != null) return double.parse(match.group(1)!);
    // Sin BPM en el nombre: el que midió/guardó el masterizado (etiqueta TBPM).
    return TrackTags.peek(path)?.bpm ?? 0.0;
  }

  Future<int> _calculateSmartCueIn(String path, Player player) async {
    if (_isMixTrack(player.state.duration.inMilliseconds)) return 0;
    final int durMs = player.state.duration.inMilliseconds;
    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthCueInMs(durMs, const []);
    }
    // El silencio inicial medido por el masterizado nunca queda dentro del cue.
    final int leadMs = TrackTags.peek(path)?.leadMs ?? 0;
    if (durMs > 30000) return leadMs > 10000 ? leadMs : 10000;
    return leadMs < durMs ~/ 3 ? leadMs : 0;
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

    // El silencio final medido por el masterizado no cuenta como canción: el
    // cruce sale antes de que empiece (la pista ya no se recorta en disco).
    final int tailMs = TrackTags.peek(path)?.tailMs ?? 0;
    final int effDurMs = (tailMs > 0 && tailMs < durationMs ~/ 3)
        ? durationMs - tailMs
        : durationMs;
    if (effDurMs != durationMs) {
      safeMixOutMs = (safeMixOutMs * effDurMs / durationMs).toInt();
    }

    if (safeMixOutMs >= effDurMs - 4000) {
      safeMixOutMs = effDurMs - 4000;
    }

    if (ref.read(mixFormulaProvider) == MixFormula.stealthGap) {
      return stealthMixOutMs(
        durationMs: effDurMs,
        lyricMs: const [],
        bpm: _extractBpm(path),
      );
    }
    if (ref.read(mixFormulaProvider) == MixFormula.phraseGrid) {
      return snapPhraseGridMixOut(
        durationMs: effDurMs,
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
        'radioOn': state.radioOn,
        'radioGenres': state.radioGenres.toList(),
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

      // Radio: estado y géneros persisten; el historial vive en su propio archivo.
      final bool savedRadioOn = data['radioOn'] as bool? ?? false;
      final Set<String> savedGenres = ((data['radioGenres'] as List?) ?? [])
          .map((e) => e.toString())
          .where(kRadioGenreIds.contains)
          .toSet();
      _loadRadioHistory();

      if (state.queue.isNotEmpty || state.currentTrackPath != null) {
        return;
      }

      state = state.copyWith(
        radioOn: savedRadioOn,
        radioGenres: savedGenres,
        queue: queueFiles,
        currentTrackPath: currentTrackPath,
        currentMixMode: LiveDjMixMode.values[mixModeIdx],
        mixStrategy: LiveDjMixStrategy.values[mixStrategyIdx],
      );
      if (savedRadioOn) unawaited(_radioEnsureIndex());

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
      final bool wasEmpty = state.queue.isEmpty;
      state = state.copyWith(queue: [...state.queue, ...newFiles]);
      _saveSnapshot();
      // Cola vacía (p. ej. fin de cola) + shuffle activo: la carga nueva usa
      // el mismo banco de shuffle del botón, así no arranca secuencial.
      if (wasEmpty &&
          state.mixStrategy == LiveDjMixStrategy.random &&
          state.queue.length > 1) {
        _applyLiveShuffleBank(advance: true);
      }
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
            final bool wasEmpty = state.queue.isEmpty;
            state = state.copyWith(queue: [...state.queue, ...fresh]);
            _saveSnapshot();
            if (wasEmpty &&
                state.mixStrategy == LiveDjMixStrategy.random &&
                state.queue.length > 1) {
              _applyLiveShuffleBank(advance: true);
            }
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

  final Map<String, int> _exactDurCache = {};

  /// Duración real del archivo (Rust/symphonia). Si difiere de la estimada por
  /// libmpv en más de 1.5 s, manda la real. Sin dato: la de libmpv.
  Future<Duration> _trueDuration(String path, Duration mpv) async {
    // Etiquetas del masterizado (silencios, BPM) listas antes de calcular la mezcla.
    await TrackTags.load(path);
    try {
      int? ms = _exactDurCache[path];
      if (ms == null) {
        ms = (await rust_dsp.exactDurationMs(inputPath: path)).toInt();
        _exactDurCache[path] = ms;
      }
      if (ms > 0 && (ms - mpv.inMilliseconds).abs() > 1500) {
        debugPrint('⏱️ [LIVEDJ] Duración corregida ${mpv.inSeconds}s → ${ms ~/ 1000}s: $path');
        return Duration(milliseconds: ms);
      }
    } catch (_) {}
    return mpv;
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
          (state.queue.isNotEmpty || state.radioOn)) {
        final triggerMs = _calculateRadioMixOut(durMs, state.currentTrackPath);

        // No se arma durante un cruce: el deck "standby" es el que aún suena
        // (saliendo); recargarlo mete pistas fantasma y deja el armado huérfano.
        if (!_isStandbyArmed &&
            !_isCrossfading &&
            posMs >= (triggerMs - 10000) &&
            triggerMs > 10000) {
          _isStandbyArmed = true;
          _standbyArmedPath = null;
          // Radio encendida: la pista sale del universo de géneros, no de la cola.
          final String? armPathOrNull = state.radioOn
              ? await _radioNextPath()
              : (state.queue.isNotEmpty
                    ? state.queue[_nextQueueIndex()].path
                    : null);
          if (armPathOrNull == null) return;
          final String armPath = armPathOrNull;
          await _standbyPlayer.setVolume(0.0);
          await _standbyPlayer.open(
            Media(armPath),
            play: false,
          );
          // Solo se da por precargada cuando la carga terminó de verdad.
          _standbyArmedPath = armPath;
          ref.read(liveDjEqualizerProvider.notifier).adapt(_standbyPlayer, armPath);
        }

        if (posMs >= triggerMs) {
          if (!_isCrossfading && !_isPrepModeBypass) {
            _triggerCrossfade();
          }
        }
      }
    });

    _durationSub = player.stream.duration.listen((mpvDur) async {
      state = state.copyWith(duration: mpvDur);
      // libmpv ESTIMA la duración de algunos MP3 (sin Xing / con carátula) y se
      // pasa: la barra acaba al 70-80 % y la mezcla nunca llega. Se corrige.
      final String? durPath = state.currentTrackPath;
      Duration dur = mpvDur;
      if (durPath != null && mpvDur.inMilliseconds > 0) {
        dur = await _trueDuration(durPath, mpvDur);
        if (state.currentTrackPath != durPath) return;
        if (dur != mpvDur) state = state.copyWith(duration: dur);
      }
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
      if (state.queue.isNotEmpty || state.radioOn) {
        forceNext();
      } else {
        unawaited(_stopWhenNoNext());
      }
    });
  }

  Future<void> togglePlayPause() async {
    if (state.queue.isEmpty &&
        state.currentTrackPath == null &&
        !state.radioOn) {
      return;
    }

    _isPrepModeBypass = false;
    _freezePersist = false;

    if (state.currentTrackPath == null &&
        (state.queue.isNotEmpty || state.radioOn)) {
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
    if (state.queue.isEmpty && !state.radioOn) {
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

  /// `true` si el deck tiene cargada (y con duración) exactamente `path`.
  bool _deckHolds(Player deck, String path) {
    try {
      if (deck.state.duration.inMilliseconds <= 0) return false;
      final medias = deck.state.playlist.medias;
      final idx = deck.state.playlist.index;
      if (idx < 0 || idx >= medias.length) return false;
      String norm(String s) {
        var t = s;
        try {
          t = Uri.decodeFull(s);
        } catch (_) {}
        return t.replaceAll('\\', '/').replaceFirst('file:///', '').toLowerCase();
      }
      final loaded = norm(medias[idx].uri);
      final want = norm(path);
      return loaded == want || loaded.endsWith(want) || want.endsWith(loaded);
    } catch (_) {
      return true;
    }
  }

  // ───────────────────────── ON AIR Radio ─────────────────────────
  // La radio NO toca la cola (congelada). Solo decide qué pista sigue:
  // universo = carpetas de género dentro de Música (sin _K), salto de carpeta
  // cada 2 temas, BPM cercano, sin artista seguido y sin repetir (historial).
  Map<String, List<String>>? _radioIndex; // carpeta → pistas
  final Map<String, String> _radioFolderGenre = <String, String>{};
  Future<void>? _radioIndexing;
  final Set<String> _radioHistory = <String>{};
  String? _radioPending;
  String? _radioPendingFolder;
  String? _radioLastFolder;
  String _radioLastArtist = '';
  int _radioStreak = 0;
  final Random _radioRng = Random();

  static const Set<String> _radioExt = {
    'mp3', 'm4a', 'flac', 'wav', 'aac', 'ogg', 'opus', 'wma',
  };

  String _radioFold(String s) {
    const from = 'áàäâéèëêíìïîóòöôúùüûñ';
    const to = 'aaaaeeeeiiiioooouuuun';
    final b = StringBuffer();
    for (final ch in s.toLowerCase().split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }

  String _radioMusicRoot() {
    String base;
    if (Platform.isIOS) {
      base = IphoneLibrary.musicRoot;
    } else if (Platform.isAndroid) {
      base = '/storage/emulated/0/Music';
    } else if (Platform.isWindows) {
      final up = Platform.environment['USERPROFILE'];
      base = up != null ? '$up\\Music' : 'C:\\Music';
    } else {
      final home = Platform.environment['HOME'];
      base = home != null ? '$home/Music' : '/';
    }
    // Las carpetas de género viven en Música/ReGenial; si no existe, en Música.
    final regenial = Directory('$base${Platform.pathSeparator}ReGenial');
    return regenial.existsSync() ? regenial.path : base;
  }

  /// Género de una carpeta de Música por su nombre; null = fuera de la radio.
  String? _radioGenreOfFolder(String name) {
    final n = _radioFold(name);
    if (n.contains('_k')) return null; // Karaoke
    if (n.startsWith('actualidad')) return 'actuales';
    for (final k in const [
      'salsa', 'merengue', 'cumbia', 'guaracha', 'bachata', 'fiesta',
      'nacional',
    ]) {
      if (n.contains(k)) return 'bailable';
    }
    if (n.contains('balada')) return 'romanticas';
    if (n.contains('80s') || n.contains('ochent')) return 'ochenteras';
    if (n.contains('rock')) return 'rock';
    return null;
  }

  String _radioArtist(String path) {
    var name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    final i = name.indexOf(' - ');
    if (i <= 0) return '';
    return _radioFold(name.substring(0, i)).trim();
  }

  String _radioHistoryPath() =>
      '${File(_sessionFilePath()).parent.path}${Platform.pathSeparator}_livedj_radio.json';

  void _loadRadioHistory() {
    try {
      final f = File(_radioHistoryPath());
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      final list = (data['history'] as List?) ?? const [];
      _radioHistory
        ..clear()
        ..addAll(list.map((e) => e.toString()));
    } catch (_) {}
  }

  void _saveRadioHistory() {
    try {
      File(_radioHistoryPath())
          .writeAsStringSync(jsonEncode({'history': _radioHistory.toList()}));
    } catch (_) {}
  }

  Future<void> _radioEnsureIndex() {
    if (_radioIndex != null) return Future.value();
    return _radioIndexing ??= _radioBuildIndex();
  }

  Future<void> _radioBuildIndex() async {
    final Map<String, List<String>> index = <String, List<String>>{};
    try {
      final root = Directory(_radioMusicRoot());
      if (root.existsSync()) {
        final kFile = RegExp(r'_k\.[a-z0-9]+$', caseSensitive: false);
        await for (final e in root.list(followLinks: false)) {
          if (e is! Directory) continue;
          final name = e.path.replaceAll('\\', '/').split('/').last;
          final genre = _radioGenreOfFolder(name);
          if (genre == null) continue;
          final files = <String>[];
          try {
            await for (final f in e.list(recursive: true, followLinks: false)) {
              if (f is! File) continue;
              final fname = f.path.replaceAll('\\', '/').split('/').last;
              final dot = fname.lastIndexOf('.');
              if (dot < 0) continue;
              if (!_radioExt.contains(fname.substring(dot + 1).toLowerCase())) {
                continue;
              }
              if (kFile.hasMatch(fname)) continue; // pista _K de Karaoke
              files.add(f.path);
            }
          } catch (_) {}
          if (files.isNotEmpty) {
            index[e.path] = files;
            _radioFolderGenre[e.path] = genre;
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [RADIO] Índice: $e");
    }
    _radioIndex = index;
    debugPrint(
      "📻 [RADIO] Índice: ${index.length} carpetas, "
      "${index.values.fold<int>(0, (a, b) => a + b.length)} pistas.",
    );
  }

  /// BPM más cercano al actual (±12 %); sin BPM, sorteo simple.
  String _radioPickByBpm(List<String> list) {
    final double cur = _extractBpm(state.currentTrackPath);
    if (cur > 60) {
      final sample = List<String>.from(list)..shuffle(_radioRng);
      String? best;
      double bestDiff = double.infinity;
      for (final p in sample.take(80)) {
        final b = _extractBpm(p);
        if (b <= 60) continue;
        final ratio = cur / b;
        if (ratio < 0.88 || ratio > 1.12) continue;
        final d = (cur - b).abs();
        if (d < bestDiff) {
          bestDiff = d;
          best = p;
        }
      }
      if (best != null) return best;
    }
    return list[_radioRng.nextInt(list.length)];
  }

  /// Siguiente pista de la radio (se fija hasta consumirse o cambiar géneros).
  Future<String?> _radioNextPath() async {
    final pending = _radioPending;
    if (pending != null && File(pending).existsSync()) return pending;
    _radioPending = null;
    await _radioEnsureIndex();
    // Otra llamada pudo elegir mientras se esperaba el índice.
    final already = _radioPending;
    if (already != null && File(already).existsSync()) return already;
    final idx = _radioIndex;
    if (idx == null || idx.isEmpty) return null;

    final genres = state.radioGenres;
    final folders = <String>[
      for (final e in idx.entries)
        if (genres.isEmpty || genres.contains(_radioFolderGenre[e.key])) e.key,
    ];
    if (folders.isEmpty) return null;

    // La carpeta seleccionada en el Explorador queda fuera de la radio.
    String selPrefix = '';
    try {
      final sel = ref.read(liveDjDirectoryProvider).currentPath;
      if (sel.isNotEmpty) {
        selPrefix = sel + Platform.pathSeparator;
        if (Platform.isWindows) selPrefix = selPrefix.toLowerCase();
      }
    } catch (_) {}
    bool outsideSel(String p) {
      if (selPrefix.isEmpty) return true;
      return !(Platform.isWindows ? p.toLowerCase() : p).startsWith(selPrefix);
    }

    // nivel 0: estricto · 1: sin regla de artista · 2: historial reiniciado
    for (int level = 0; level < 3; level++) {
      if (level == 2) {
        _radioHistory.clear();
        _saveRadioHistory();
      }
      final cand = <String, List<String>>{};
      for (final f in folders) {
        final list = idx[f]!.where((p) {
          if (!outsideSel(p)) return false;
          if (level < 2 && _radioHistory.contains(p)) return false;
          if (level < 1 &&
              _radioLastArtist.isNotEmpty &&
              _radioArtist(p) == _radioLastArtist) {
            return false;
          }
          return true;
        }).toList();
        if (list.isNotEmpty) cand[f] = list;
      }
      if (cand.isEmpty) continue;

      String folder;
      final last = _radioLastFolder;
      if (last != null && _radioStreak < 2 && cand.containsKey(last)) {
        folder = last; // 2 temas por carpeta
      } else {
        final others = cand.keys.where((k) => k != last).toList();
        final pool = others.isNotEmpty ? others : cand.keys.toList();
        folder = pool[_radioRng.nextInt(pool.length)];
      }

      final pick = _radioPickByBpm(cand[folder]!);
      if (!File(pick).existsSync()) {
        idx[folder]!.remove(pick);
        return _radioNextPath();
      }
      _radioPending = pick;
      _radioPendingFolder = folder;
      state = state.copyWith(radioNextPath: pick);
      return pick;
    }
    return null;
  }

  void _radioConsumed(String path) {
    _radioHistory.add(path);
    final folder = _radioPendingFolder;
    if (folder != null) {
      if (folder == _radioLastFolder) {
        _radioStreak++;
      } else {
        _radioLastFolder = folder;
        _radioStreak = 1;
      }
    }
    _radioLastArtist = _radioArtist(path);
    _radioPending = null;
    _radioPendingFolder = null;
    state = state.copyWith(clearRadioNextPath: true);
    _saveRadioHistory();
  }

  Future<void> toggleRadio() async {
    final bool on = !state.radioOn;
    state = state.copyWith(radioOn: on, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (on) {
      unawaited(_radioEnsureIndex());
      if (state.currentTrackPath == null && !_isCrossfading) {
        _isPrepModeBypass = false;
        await forceNext();
      } else {
        unawaited(_radioNextPath()); // que el "siguiente" salga de inmediato
      }
    }
  }

  void clearRadioGenres() {
    state = state.copyWith(radioGenres: <String>{}, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (state.radioOn) unawaited(_radioNextPath());
  }

  void toggleRadioGenre(String genre) {
    if (!kRadioGenreIds.contains(genre)) return;
    final next = Set<String>.from(state.radioGenres);
    if (!next.remove(genre)) next.add(genre);
    state = state.copyWith(radioGenres: next, clearRadioNextPath: true);
    _radioPending = null;
    _radioPendingFolder = null;
    _saveSnapshot();
    if (state.radioOn) unawaited(_radioNextPath());
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
    if (_isCrossfading || (state.queue.isEmpty && !state.radioOn)) return;
    _isCrossfading = true;

    // Radio encendida y sin pista elegida a mano: la sigue la radio (la cola
    // queda congelada). Un toque explícito a una fila (queueIndex) sí suena.
    final bool radioPick = state.radioOn && queueIndex == null;
    final String nextTrack;
    if (radioPick) {
      final String? picked = await _radioNextPath();
      if (picked == null) {
        _isCrossfading = false;
        await _stopWhenNoNext();
        return;
      }
      nextTrack = picked;
    } else {
      final int nextIdx = queueIndex ?? _nextQueueIndex();
      if (nextIdx < 0 || nextIdx >= state.queue.length) {
        _isCrossfading = false;
        await _stopWhenNoNext();
        return;
      }
      nextTrack = state.queue[nextIdx].path;
    }
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

    // Verificación anti-fantasma (Android): si el deck entrante no tiene
    // cargada la pista pedida (carga lenta/fallida), se recarga una vez; si
    // sigue mal, se aborta el cruce en vez de reproducir lo que quedó en el deck.
    if (!_deckHolds(incomingPlayer, nextTrack)) {
      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
        ref.read(liveDjEqualizerProvider.notifier).adapt(incomingPlayer, nextTrack);
        try {
          await incomingPlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      } catch (e) {
        debugPrint("🔴 [LIVEDJ OPEN RETRY]: $e");
      }
      if (!_deckHolds(incomingPlayer, nextTrack)) {
        debugPrint("🔴 [LIVEDJ] Deck entrante sin la pista pedida. Cruce abortado.");
        _isStandbyArmed = false;
        _standbyArmedPath = null;
        _isCrossfading = false;
        return;
      }
    }

    Duration trackDur = Duration.zero;
    try {
      trackDur = incomingPlayer.state.duration;
    } catch (_) {}
    trackDur = await _trueDuration(nextTrack, trackDur);

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
    if (!radioPick) {
      final int removeAt = newQueue.indexWhere((f) => f.path == nextTrack);
      if (removeAt >= 0) newQueue.removeAt(removeAt);
    }
    // Empieza la última canción de la cola: la Radio se enciende sola.
    final bool autoRadio = !radioPick && !state.radioOn && newQueue.isEmpty;
    if (autoRadio) unawaited(_radioEnsureIndex());
    if (radioPick) _radioConsumed(nextTrack);

    state = state.copyWith(
      radioOn: autoRadio ? true : null,
      queue: newQueue,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: trackDur,
      customCueInMs: cueInMs,
      customMixOutMs: triggerMs,
      currentMixMode: nextMode,
    );

    _saveSnapshot();
    // Con la Radio encendida el siguiente se elige apenas empieza esta pista.
    if (state.radioOn) unawaited(_radioNextPath());

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
    final String lowCutIn = AfCaps.sanitize(
      [inBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
    final String lowCutOut = AfCaps.sanitize(
      [outBase(), _bassKillFilter].where((s) => s.isNotEmpty).join(','),
    );
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
      // El deck saliente quedó vacío: ningún armado previo sigue siendo válido.
      _standbyArmedPath = null;

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
