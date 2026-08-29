import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'db_provider.dart';
import 'nlp_provider.dart';
import 'package:flutter/foundation.dart';
import 'equalizer_provider.dart';

enum MixStrategy { sequential, random }

enum AutomixMode { semantic, radio_broadcast }

class LyricLine {
  final Duration timestamp;
  final String text;
  LyricLine({required this.timestamp, required this.text});
}

class PlayerState {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final List<String> playlist;
  final int currentIndex;
  final String? currentTrackPath;
  final List<LyricLine> lyrics;
  final int activeLyricIndex;
  final String? nextTrackPath;
  final int triggerRemainingMs;
  final MixStrategy mixStrategy;
  final AutomixMode automixMode;
  final int customCueInMs;
  final int customMixOutMs;
  final bool autoMixArmed;

  PlayerState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playlist = const [],
    this.currentIndex = -1,
    this.currentTrackPath,
    this.lyrics = const [],
    this.activeLyricIndex = -1,
    this.nextTrackPath,
    this.triggerRemainingMs = 4000,
    this.mixStrategy = MixStrategy.sequential,
    this.automixMode = AutomixMode.semantic,
    this.customCueInMs = -1,
    this.customMixOutMs = -1,
    this.autoMixArmed = true,
  });

  PlayerState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    List<String>? playlist,
    int? currentIndex,
    String? currentTrackPath,
    List<LyricLine>? lyrics,
    int? activeLyricIndex,
    String? nextTrackPath,
    int? triggerRemainingMs,
    MixStrategy? mixStrategy,
    AutomixMode? automixMode,
    int? customCueInMs,
    int? customMixOutMs,
    bool? autoMixArmed,
  }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playlist: playlist ?? this.playlist,
      currentIndex: currentIndex ?? this.currentIndex,
      currentTrackPath: currentTrackPath ?? this.currentTrackPath,
      lyrics: lyrics ?? this.lyrics,
      activeLyricIndex: activeLyricIndex ?? this.activeLyricIndex,
      nextTrackPath: nextTrackPath ?? this.nextTrackPath,
      triggerRemainingMs: triggerRemainingMs ?? this.triggerRemainingMs,
      mixStrategy: mixStrategy ?? this.mixStrategy,
      automixMode: automixMode ?? this.automixMode,
      customCueInMs: customCueInMs ?? this.customCueInMs,
      customMixOutMs: customMixOutMs ?? this.customMixOutMs,
      autoMixArmed: autoMixArmed ?? this.autoMixArmed,
    );
  }
}

class PlayerNotifier extends Notifier<PlayerState> {
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
  final int _triggerRemainingMs = 4000;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;

  @override
  PlayerState build() {
    _playerA = Player();
    _playerB = Player();

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

    return PlayerState();
  }

  Future<void> setMixPoint(String type) async {
    if (state.currentTrackPath == null) return;
    final currentPosMs = state.position.inMilliseconds;
    final db = ref.read(dbServiceProvider);

    if (type == 'IN') {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        cueInMs: currentPosMs,
        isManualCue: true,
      );
      state = state.copyWith(customCueInMs: currentPosMs);
    } else {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        mixOutMs: currentPosMs,
        isManualCue: true,
      );
      state = state.copyWith(customMixOutMs: currentPosMs, autoMixArmed: true);
      _recalculateMixWindow();
      if (!state.isPlaying) _isPrepModeBypass = true;
    }
  }

  String _getSessionFilePath() {
    String baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseDir = userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      baseDir = home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    } else {
      baseDir = '/storage/emulated/0/Music/DjPlaylists';
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_player_session.json';
  }

  Future<void> _saveSnapshot() async {
    try {
      final file = File(_getSessionFilePath());
      final data = {
        'playlist': state.playlist,
        'currentIndex': state.currentIndex,
        'positionMs': state.position.inMilliseconds,
        'mixStrategy': state.mixStrategy.index,
        'automixMode': state.automixMode.index,
        'autoMixArmed': state.autoMixArmed,
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

      final playlist = (data['playlist'] as List?)?.cast<String>();
      final index = data['currentIndex'] as int?;
      final positionMs = data['positionMs'] as int?;
      final mixStrategyIdx = data['mixStrategy'] as int? ?? 0;
      final automixModeIdx = data['automixMode'] as int? ?? 0;
      final autoMixArmed = data['autoMixArmed'] as bool? ?? true;

      if (playlist != null &&
          playlist.isNotEmpty &&
          index != null &&
          index >= 0) {
        state = state.copyWith(
          playlist: playlist,
          currentIndex: index,
          currentTrackPath: playlist[index],
          mixStrategy: MixStrategy.values[mixStrategyIdx],
          automixMode: AutomixMode.values[automixModeIdx],
          autoMixArmed: autoMixArmed,
        );

        await _loadLyrics(playlist[index]);
        await _loadTrackMetadata(playlist[index]);
        await _activePlayer.open(Media(playlist[index]), play: false);

        try {
          await _activePlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}

        if (positionMs != null && positionMs > 0) {
          await _activePlayer.seek(Duration(milliseconds: positionMs));
        } else if (state.customCueInMs > 0) {
          await _activePlayer.seek(Duration(milliseconds: state.customCueInMs));
        }
      }
    } catch (_) {}
  }

  void setMixStrategy(MixStrategy strategy) {
    state = state.copyWith(mixStrategy: strategy);
    _saveSnapshot();
    _recalculateMixWindow();
  }

  void toggleAutomixMode() {
    final newMode = state.automixMode == AutomixMode.semantic
        ? AutomixMode.radio_broadcast
        : AutomixMode.semantic;
    state = state.copyWith(automixMode: newMode);
    _saveSnapshot();
    _recalculateMixWindow();
  }

  void toggleAutoMixBypass() {
    state = state.copyWith(autoMixArmed: !state.autoMixArmed);
    _saveSnapshot();
  }

  void syncDynamicPlaylist(List<String> newPlaylistOrdered) {
    if (listEquals(state.playlist, newPlaylistOrdered)) return;
    int newCurrentIndex = -1;
    if (state.currentTrackPath != null) {
      newCurrentIndex = newPlaylistOrdered.indexOf(state.currentTrackPath!);
    }
    state = state.copyWith(
      playlist: newPlaylistOrdered,
      currentIndex: newCurrentIndex,
    );
    _saveSnapshot();
    _recalculateMixWindow();
  }

  Future<List<Map<String, dynamic>>> searchLyrics(String query) async {
    List<Map<String, dynamic>> allResults = [];
    try {
      final uriGlobal = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}',
      );
      final resGlobal = await http
          .get(uriGlobal)
          .timeout(const Duration(seconds: 5));
      if (resGlobal.statusCode == 200) {
        allResults.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(resGlobal.body)),
        );
      }

      if (!query.contains('-')) {
        final uriArtist = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(query.trim())}',
        );
        final resArtist = await http
            .get(uriArtist)
            .timeout(const Duration(seconds: 5));
        if (resArtist.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resArtist.body)),
          );
        }
      } else {
        final parts = query.split('-');
        final uriAdvanced = Uri.parse(
          'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(parts[0].trim())}&track_name=${Uri.encodeComponent(parts.sublist(1).join(' ').trim())}',
        );
        final resAdvanced = await http
            .get(uriAdvanced)
            .timeout(const Duration(seconds: 5));
        if (resAdvanced.statusCode == 200) {
          allResults.addAll(
            List<Map<String, dynamic>>.from(jsonDecode(resAdvanced.body)),
          );
        }
      }

      final uniqueById = <int, Map<String, dynamic>>{};
      for (var item in allResults) {
        if (item['id'] != null) uniqueById[item['id']] = item;
      }
      return uniqueById.values.toList();
    } catch (_) {}
    return [];
  }

  Future<void> applyManualLyrics(String audioPath, String syncedLyrics) async {
    try {
      final lrcPath = audioPath.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      await File(lrcPath).writeAsString(syncedLyrics);
      if (state.currentTrackPath == audioPath) await _loadLyrics(audioPath);
    } catch (_) {}
  }

  Future<void> _loadTrackMetadata(String audioPath) async {
    final metadata = await ref
        .read(dbServiceProvider)
        .getTrackMetadata(audioPath);

    state = state.copyWith(
      customCueInMs: metadata?.cueInMs ?? -1,
      customMixOutMs: metadata?.mixOutMs ?? -1,
      autoMixArmed: true,
    );
    _recalculateMixWindow();
  }

  Future<void> _shadowLoadNextTrack() async {
    if (_isStandbyArmed || state.nextTrackPath == null) return;
    _isStandbyArmed = true;

    final String nextTrack = state.nextTrackPath!;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    if (state.automixMode == AutomixMode.semantic) {
      final meta = await ref
          .read(dbServiceProvider)
          .getTrackMetadata(nextTrack);
      if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;
    }

    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(Media(nextTrack), play: false);

    if (cueInMs > 0) {
      try {
        await incomingPlayer.stream.duration
            .firstWhere((d) => d.inMilliseconds > 0)
            .timeout(const Duration(seconds: 2));
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
      } catch (e) {
        debugPrint(
          "⚠️ [PRE-FLIGHT ERROR]: No se pudo montar el buffer para $nextTrack",
        );
      }
    }

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) incomingRate = ratio;
    }
    await incomingPlayer.setRate(incomingRate);
  }

  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) {
      final posMs = pos.inMilliseconds;

      state = state.copyWith(position: pos);

      if ((posMs - _lastSavedPositionMs).abs() > 5000) {
        _lastSavedPositionMs = posMs;
        _saveSnapshot();
      }

      if (state.automixMode == AutomixMode.semantic &&
          state.customCueInMs > 0 &&
          posMs < state.customCueInMs &&
          posMs < 1000) {
        player.seek(Duration(milliseconds: state.customCueInMs));
        return;
      }

      if (state.autoMixArmed &&
          state.customMixOutMs > 0 &&
          state.nextTrackPath != null) {
        if (!_isStandbyArmed &&
            posMs >= (state.customMixOutMs - 12000) &&
            state.customMixOutMs > 12000) {
          _shadowLoadNextTrack();
        }

        if (posMs >= (state.customMixOutMs - 150)) {
          if (!_isCrossfading && !_isPrepModeBypass) {
            _triggerCrossfade();
          }
        }
      }

      int newLyricIndex = -1;
      if (state.lyrics.isNotEmpty) {
        for (int i = state.lyrics.length - 1; i >= 0; i--) {
          if (pos >= state.lyrics[i].timestamp) {
            newLyricIndex = i;
            break;
          }
        }
      }

      state = state.copyWith(
        activeLyricIndex: newLyricIndex,
        triggerRemainingMs: _triggerRemainingMs,
      );

      if (state.autoMixArmed &&
          state.customMixOutMs <= 0 &&
          !_isCrossfading &&
          state.duration.inMilliseconds > 0 &&
          state.nextTrackPath != null) {
        int timeRemaining = state.duration.inMilliseconds - posMs;
        if (timeRemaining > _triggerRemainingMs) _isPrepModeBypass = false;

        if (!_isStandbyArmed &&
            timeRemaining <= 12000 &&
            timeRemaining > _triggerRemainingMs) {
          _shadowLoadNextTrack();
        }

        if (timeRemaining <= _triggerRemainingMs) {
          if (!_isPrepModeBypass) _triggerCrossfade();
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
      _recalculateMixWindow();
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (completed &&
          state.autoMixArmed &&
          !_isCrossfading &&
          state.nextTrackPath != null) {
        _isPrepModeBypass = false;
        _triggerCrossfade();
      }
    });
  }

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activePlayer.seek(position);
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

  // 🛠️ MOTOR DSP HÍBRIDO (FFmpeg Raw en Windows | Dart-Native en Mac/Android)
  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required int mixDurationMs,
    required String mixProfile,
    required double incomingRate,
  }) async {
    final stopwatch = Stopwatch()..start();
    final String currentBaseFilter = ref
        .read(equalizerProvider.notifier)
        .currentBaseFilter;
    final bool useFfmpeg = Platform.isWindows;

    debugPrint(
      "🎛️ [MIX ENGINE] Engine: ${useFfmpeg ? 'FFmpeg (C++)' : 'Dart (Native CPU)'} | Curva: $mixProfile",
    );

    if (mixProfile == 'echo_out' || mixProfile == 'slam_cut') {
      // 🛠️ TROPICAL & FOLKLORE: Corte Seco y Rebote
      if (useFfmpeg && mixProfile == 'echo_out') {
        (fadingPlayer.platform as dynamic)?.setProperty(
          'af',
          '$currentBaseFilter,aecho=0.8:0.9:500:0.5',
        );
      }
      await fadingPlayer.setVolume(0.0);
      await incomingPlayer.setVolume(100.0);
      // El Delay de 2s solo aplica si FFmpeg inyectó el eco, si no, es un Slam Cut rápido.
      await Future.delayed(
        Duration(
          milliseconds: (useFfmpeg && mixProfile == 'echo_out') ? 2000 : 500,
        ),
      );
      await fadingPlayer.stop();
    } else if (mixProfile == 'brake_stop') {
      // 🛠️ CUMBIA & NACIONAL: Simulación de Freno de Vinilo vía interpolación (Universal)
      double rateOut = 1.0;
      double volIn = 0.0;
      int brakeDuration = 800;
      while (stopwatch.elapsedMilliseconds < brakeDuration) {
        final progress = (stopwatch.elapsedMilliseconds / brakeDuration).clamp(
          0.0,
          1.0,
        );
        rateOut = 1.0 - (progress * 0.95);
        volIn = progress * 100.0;

        await fadingPlayer.setRate(rateOut.clamp(0.05, 1.0));
        await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
        await Future.delayed(const Duration(milliseconds: 16));
      }
      await fadingPlayer.setVolume(0.0);
      await fadingPlayer.stop();
      await incomingPlayer.setVolume(100.0);
    } else {
      // 🛠️ TRANSICIONES LARGAS (Constant Power, Quick Fade, Bass Swap)
      if (useFfmpeg && mixProfile == 'bass_swap') {
        // Suprime el sub-grave del Deck A (Saliente)
        (fadingPlayer.platform as dynamic)?.setProperty(
          'af',
          '$currentBaseFilter,lowshelf=g=-12:f=80',
        );
      } else if (useFfmpeg &&
          (mixProfile == 'eq_kill' || mixProfile == 'quick_fade')) {
        // Suprime el sub-grave del Deck B (Entrante)
        (incomingPlayer.platform as dynamic)?.setProperty(
          'af',
          '$currentBaseFilter,lowshelf=g=-12:f=120',
        );
      }

      while (stopwatch.elapsedMilliseconds < mixDurationMs) {
        final double progress = (stopwatch.elapsedMilliseconds / mixDurationMs)
            .clamp(0.0, 1.0);
        double volOut = 100.0;
        double volIn = 100.0;

        if (mixProfile == 'eq_kill' || mixProfile == 'quick_fade') {
          volOut = pow(1.0 - progress, 2.5) * 100.0;
          volIn = 70.0 + (progress * 30.0);
        } else {
          volOut = cos(progress * (pi / 2)) * 100.0;
          volIn = sin(progress * (pi / 2)) * 100.0;
        }

        await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
        await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
        await Future.delayed(const Duration(milliseconds: 20));
      }
      await fadingPlayer.stop();
    }

    // 🛠️ LIMPIEZA ATÓMICA DE ESTADOS Y FILTROS
    await fadingPlayer.setVolume(100.0);
    await fadingPlayer.setRate(1.0);
    if (useFfmpeg) {
      (fadingPlayer.platform as dynamic)?.setProperty('af', currentBaseFilter);
      (incomingPlayer.platform as dynamic)?.setProperty(
        'af',
        currentBaseFilter,
      );
    }

    // 🛠️ AJUSTE BEATMATCHING ALGÓRITMICO
    if (incomingRate != 1.0 &&
        mixProfile != 'echo_out' &&
        mixProfile != 'brake_stop' &&
        mixProfile != 'slam_cut') {
      final pitchStopwatch = Stopwatch()..start();
      const int pitchReleaseDurationMs = 3000;
      final double rateDiff = 1.0 - incomingRate;

      while (pitchStopwatch.elapsedMilliseconds < pitchReleaseDurationMs) {
        if ((_usePlayerA && incomingPlayer == _playerA) ||
            (!_usePlayerA && incomingPlayer == _playerB)) {
          final double p =
              (pitchStopwatch.elapsedMilliseconds / pitchReleaseDurationMs)
                  .clamp(0.0, 1.0);
          final double currentRate = incomingRate + (rateDiff * p);

          await incomingPlayer.setRate(currentRate.clamp(0.5, 2.0));
          await Future.delayed(const Duration(milliseconds: 50));
        } else {
          break;
        }
      }
      await incomingPlayer.setRate(1.0);
    }
  }

  Future<void> _recalculateMixWindow() async {
    if (state.duration.inMilliseconds == 0) return;
    final nextIdx = _calculateNextIndex();
    final nextPath = nextIdx != -1 ? state.playlist[nextIdx] : null;

    int safeMixOutMs = state.customMixOutMs;
    int safeCueInMs = state.customCueInMs;
    int triggerMs;
    int dynamicMixDurationMs;

    if (state.automixMode == AutomixMode.radio_broadcast) {
      dynamicMixDurationMs = 12000;

      if (nextPath != null) {
        final nextMeta = await ref
            .read(dbServiceProvider)
            .getTrackMetadata(nextPath);
        safeCueInMs = nextMeta?.cueInMs ?? 0;
      } else {
        safeCueInMs = 0;
      }

      if (safeMixOutMs <= 0) {
        safeMixOutMs = state.duration.inMilliseconds - dynamicMixDurationMs;
      }

      if (safeMixOutMs >=
          state.duration.inMilliseconds - dynamicMixDurationMs) {
        safeMixOutMs =
            state.duration.inMilliseconds - dynamicMixDurationMs - 1000;
      }
      if (safeMixOutMs < 0) safeMixOutMs = 0;
      triggerMs = dynamicMixDurationMs;
    } else {
      dynamicMixDurationMs = 6000;
      if (nextPath != null) {
        final nextMeta = await ref
            .read(dbServiceProvider)
            .getTrackMetadata(nextPath);
        if (nextMeta != null) dynamicMixDurationMs = nextMeta.mixDurationMs;
      }

      if (safeMixOutMs > 0 &&
          safeMixOutMs >=
              state.duration.inMilliseconds - dynamicMixDurationMs) {
        safeMixOutMs =
            state.duration.inMilliseconds - dynamicMixDurationMs - 1000;
      }
      if (safeCueInMs > 0 && safeCueInMs > state.duration.inMilliseconds ~/ 2) {
        safeCueInMs = 0;
      }

      if (safeMixOutMs > 0) {
        triggerMs = state.duration.inMilliseconds - safeMixOutMs;
        if (triggerMs < dynamicMixDurationMs) {
          triggerMs = dynamicMixDurationMs;
        }
      } else {
        triggerMs = dynamicMixDurationMs + 2000;
      }
    }

    state = state.copyWith(
      nextTrackPath: nextPath,
      triggerRemainingMs: triggerMs,
      customMixOutMs: safeMixOutMs,
      customCueInMs: safeCueInMs,
    );
  }

  Future<void> forceTransition(int index) async {
    if (index < 0 || index >= state.playlist.length || _isCrossfading) return;
    _isCrossfading = true;
    _isPrepModeBypass = false;
    _isStandbyArmed = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 5000;
    String mixProfile = 'constant_power';

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);

    if (state.automixMode == AutomixMode.radio_broadcast) {
      if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = 12000;
      final djEffects = [
        'constant_power',
        'echo_out',
        'bass_swap',
        'brake_stop',
      ];
      mixProfile = djEffects[Random().nextInt(djEffects.length)];
    } else {
      if (meta != null) {
        if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
        mixDurationMs = meta.mixDurationMs;
        mixProfile = meta.mixProfile;
      }
      if (mixDurationMs < 5000) mixDurationMs = 5000;
    }

    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(Media(nextTrack), play: false);

    if (cueInMs > 0) {
      try {
        await incomingPlayer.stream.duration
            .firstWhere((d) => d.inMilliseconds > 0)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      await incomingPlayer.seek(Duration(milliseconds: cueInMs));
    }

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }
    await incomingPlayer.setRate(incomingRate);

    await incomingPlayer.play();
    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);

    state = state.copyWith(
      currentIndex: index,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
    );

    Future.wait([
      _loadLyrics(nextTrack),
      if (state.automixMode == AutomixMode.semantic)
        _loadTrackMetadata(nextTrack),
      _saveSnapshot(),
    ]);

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: mixDurationMs,
      mixProfile: mixProfile,
      incomingRate: incomingRate,
    );

    _isCrossfading = false;
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= state.playlist.length || _isCrossfading) return;
    if (state.currentIndex == index && state.isPlaying) return;

    _isCrossfading = true;
    _isPrepModeBypass = false;
    _isStandbyArmed = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 6000;
    String mixProfile = 'constant_power';

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);

    if (state.automixMode == AutomixMode.radio_broadcast) {
      if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = 12000;
      final djEffects = [
        'constant_power',
        'echo_out',
        'bass_swap',
        'brake_stop',
      ];
      mixProfile = djEffects[Random().nextInt(djEffects.length)];
    } else {
      if (meta != null) {
        if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
        mixDurationMs = meta.mixDurationMs;
        mixProfile = meta.mixProfile;
      }
      if (cueInMs < 0) cueInMs = 0;
    }

    await incomingPlayer.setVolume(0.0);
    await incomingPlayer.open(Media(nextTrack), play: false);

    if (cueInMs > 0) {
      try {
        await incomingPlayer.stream.duration
            .firstWhere((d) => d.inMilliseconds > 0)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      await incomingPlayer.seek(Duration(milliseconds: cueInMs));
    }

    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }
    await incomingPlayer.setRate(incomingRate);

    await incomingPlayer.play();
    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);

    state = state.copyWith(
      currentIndex: index,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
    );

    Future.wait([
      _loadLyrics(nextTrack),
      if (state.automixMode == AutomixMode.semantic)
        _loadTrackMetadata(nextTrack),
      _saveSnapshot(),
    ]);

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: mixDurationMs,
      mixProfile: mixProfile,
      incomingRate: incomingRate,
    );

    _isCrossfading = false;
  }

  Future<void> _triggerCrossfade() async {
    if (_isCrossfading || state.nextTrackPath == null) return;
    _isCrossfading = true;
    final int nextIndex = _calculateNextIndex();
    if (nextIndex == -1) {
      _isCrossfading = false;
      return;
    }

    final String nextTrack = state.playlist[nextIndex];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 6000;
    String mixProfile = 'constant_power';

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);

    if (state.automixMode == AutomixMode.radio_broadcast) {
      if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = 12000;
      final djEffects = [
        'constant_power',
        'echo_out',
        'bass_swap',
        'brake_stop',
      ];
      mixProfile = djEffects[Random().nextInt(djEffects.length)];
    } else {
      if (meta != null) {
        if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
        mixDurationMs = meta.mixDurationMs;
        mixProfile = meta.mixProfile;
      }
      if (cueInMs < 0) cueInMs = 0;
    }

    if (!_isStandbyArmed) {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);

      if (cueInMs > 0) {
        try {
          await incomingPlayer.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
          await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        } catch (_) {}
      }

      final fadingBpm = _extractBpm(state.currentTrackPath);
      final incomingBpm = _extractBpm(nextTrack);
      double incomingRate = 1.0;

      if (fadingBpm > 60 && incomingBpm > 60) {
        final ratio = fadingBpm / incomingBpm;
        if (ratio >= 0.88 && ratio <= 1.12) incomingRate = ratio;
      }
      await incomingPlayer.setRate(incomingRate);
    }

    await incomingPlayer.play();

    _usePlayerA = !_usePlayerA;
    _isStandbyArmed = false;
    _attachListeners(_activePlayer);

    final actualPosMs =
        (await incomingPlayer.stream.position.first).inMilliseconds;

    state = state.copyWith(
      currentIndex: nextIndex,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: actualPosMs),
    );

    Future.wait([
      _loadLyrics(nextTrack),
      if (state.automixMode == AutomixMode.semantic)
        _loadTrackMetadata(nextTrack),
      _saveSnapshot(),
    ]);

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: mixDurationMs,
      mixProfile: mixProfile,
      incomingRate: (await incomingPlayer.stream.rate.first),
    );

    _isCrossfading = false;
  }

  Future<void> loadContextAndPlay(List<String> playlist, int startIndex) async {
    _isPrepModeBypass = false;
    state = state.copyWith(
      playlist: playlist,
      currentIndex: startIndex,
      currentTrackPath: playlist[startIndex],
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    _saveSnapshot();

    final path = playlist[startIndex];
    await _loadLyrics(path);
    if (state.automixMode == AutomixMode.semantic) {
      await _loadTrackMetadata(path);
    }

    int cueInMs = 0;
    if (state.automixMode == AutomixMode.semantic) {
      final meta = await ref.read(dbServiceProvider).getTrackMetadata(path);
      if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;
    }

    await _activePlayer.setVolume(100.0);
    await _activePlayer.open(Media(path), play: false);

    if (cueInMs > 0) {
      try {
        await _activePlayer.stream.duration
            .firstWhere((d) => d.inMilliseconds > 0)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      await _activePlayer.seek(Duration(milliseconds: cueInMs));
    }
    await _activePlayer.play();
  }

  Future<void> _executeQuickFadeOut(Player player) async {
    double vol = 100.0;
    for (int i = 0; i < 15; i++) {
      vol -= 6.6;
      await player.setVolume(vol.clamp(0.0, 100.0));
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await player.stop();
    await player.setVolume(100.0);
  }

  int _calculateNextIndex() {
    if (state.playlist.isEmpty) return -1;
    if (state.mixStrategy == MixStrategy.random) {
      return Random().nextInt(state.playlist.length);
    }
    return (state.currentIndex + 1) < state.playlist.length
        ? state.currentIndex + 1
        : (state.currentIndex == -1 ? 0 : -1);
  }

  // 🛠️ FIX MÓVIL: Veto a llamadas CLI de ffprobe
  Future<int> _getLocalDurationSec(String filePath) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final meta = await ref.read(dbServiceProvider).getTrackMetadata(filePath);
      if (meta != null && meta.mixDurationMs > 0) {
        return meta.mixDurationMs ~/ 1000;
      }
      return 0;
    }

    try {
      String ffprobePath = 'ffprobe';
      if (Platform.isMacOS) {
        if (File('/opt/homebrew/bin/ffprobe').existsSync())
          ffprobePath = '/opt/homebrew/bin/ffprobe';
        else if (File('/usr/local/bin/ffprobe').existsSync())
          ffprobePath = '/usr/local/bin/ffprobe';
      }
      final result = await Process.run(ffprobePath, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      if (result.exitCode == 0) {
        return (double.tryParse(result.stdout.toString().trim()) ?? 0.0)
            .toInt();
      }
    } catch (_) {}
    return 0;
  }

  Future<void> _loadLyrics(String audioPath) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final lines = await lrcFile.readAsLines();
        final List<LyricLine> parsedLyrics = [];
        final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

        for (var line in lines) {
          final match = regex.firstMatch(line);
          if (match != null) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            int ms = int.parse(match.group(3)!);
            if (match.group(3)!.length == 2) ms *= 10;
            final duration = Duration(
              minutes: min,
              seconds: sec,
              milliseconds: ms,
            );
            final text = match.group(4)!.trim();
            if (text.isNotEmpty) {
              parsedLyrics.add(LyricLine(timestamp: duration, text: text));
            }
          }
        }
        state = state.copyWith(lyrics: parsedLyrics, activeLyricIndex: -1);
      } catch (_) {
        state = state.copyWith(lyrics: [], activeLyricIndex: -1);
      }
    } else {
      state = state.copyWith(lyrics: [], activeLyricIndex: -1);
      _fetchLyricsAsync(audioPath, lrcPath);
    }
  }

  Future<void> _fetchLyricsAsync(String audioPath, String lrcPath) async {
    try {
      String rawFilename = audioPath
          .replaceAll('\\', '/')
          .split('/')
          .last
          .replaceAll(
            RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
            '',
          );
      String cleanQuery = rawFilename
          .replaceAll(RegExp(r'\[.*?\]|\(.*?\)', caseSensitive: false), '')
          .replaceAll(
            RegExp(
              r'\b(official|video|audio|lyric|lyrics|remix|live|kbps|hd|hq)\b',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleanQuery.isEmpty) cleanQuery = rawFilename;

      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(cleanQuery)}',
      );
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        if (data.isNotEmpty) {
          data.sort((a, b) {
            final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
            final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;
            if (aSync && !bSync) return -1;
            if (!aSync && bSync) return 1;
            return 0;
          });

          if (data[0]['syncedLyrics'] != null &&
              data[0]['syncedLyrics'].toString().isNotEmpty) {
            await File(lrcPath).writeAsString(data[0]['syncedLyrics']);
            if (state.currentTrackPath == audioPath) {
              await _loadLyrics(audioPath);
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (state.currentTrackPath == null) return;
    _isPrepModeBypass = false;

    if (!state.isPlaying && state.customCueInMs > 0) {
      if (state.position.inMilliseconds < state.customCueInMs) {
        await _activePlayer.seek(Duration(milliseconds: state.customCueInMs));
      }
    }
    await _activePlayer.playOrPause();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> pause() async {
    if (state.isPlaying) {
      await _activePlayer.pause();
      _saveSnapshot();
    }
  }

  Future<void> updateCurrentTrackAndPlay(String newPath) async {
    if (state.currentIndex < 0) return;
    _isPrepModeBypass = false;

    final currentList = List<String>.from(state.playlist);
    currentList[state.currentIndex] = newPath;

    state = state.copyWith(
      playlist: currentList,
      currentTrackPath: newPath,
      nextTrackPath: null,
      customCueInMs: -1,
      customMixOutMs: -1,
      autoMixArmed: true,
    );
    _saveSnapshot();
    await _loadLyrics(newPath);
    if (state.automixMode == AutomixMode.semantic) {
      await _loadTrackMetadata(newPath);
    }

    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    await incomingPlayer.setVolume(100.0);
    await incomingPlayer.open(Media(newPath), play: true);

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);
    _executeQuickFadeOut(fadingPlayer);
  }

  Future<void> stopAndRelease() async {
    try {
      await _playerA.stop();
    } catch (_) {}
    try {
      await _playerB.stop();
    } catch (_) {}
    _isCrossfading = false;
    await Future.delayed(const Duration(milliseconds: 600));
  }

  Future<void> clearMixPoints() async {
    if (state.currentTrackPath == null) return;
    final path = state.currentTrackPath!;

    state = state.copyWith(customCueInMs: 0, customMixOutMs: 0);

    final lrcPath = path.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);
    if (lrcFile.existsSync()) {
      lrcFile.deleteSync();
    }

    await ref
        .read(dbServiceProvider)
        .saveTrackMetadata(
          path: path,
          mixProfile: state.mixStrategy == MixStrategy.sequential
              ? 'constant_power'
              : 'eq_kill',
          durationMs: 6000,
          genre: 'desconocido',
          cueInMs: 0,
          mixOutMs: 0,
          isManualCue: false,
        );

    try {
      await ref.read(nlpWorkerProvider).processSingleFile(path);
    } catch (_) {}

    state = state.copyWith(lyrics: [], activeLyricIndex: -1);
  }

  Future<void> autoSyncFirstLyric() async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;

    final posMs = state.position.inMilliseconds;
    final targetLine = state.lyrics.first;

    final deltaMs = posMs - targetLine.timestamp.inMilliseconds;

    final List<LyricLine> newLyrics = [];

    for (var line in state.lyrics) {
      int newMs = line.timestamp.inMilliseconds + deltaMs;
      if (newMs < 0) newMs = 0;

      newLyrics.add(
        LyricLine(
          timestamp: Duration(milliseconds: newMs),
          text: line.text,
        ),
      );
    }

    await _saveLyricsToFile(state.currentTrackPath!, newLyrics);
    state = state.copyWith(lyrics: newLyrics);
  }

  Future<void> autoSyncFromCurrentLyric() async {
    if (state.currentTrackPath == null ||
        state.lyrics.isEmpty ||
        state.activeLyricIndex < 0) {
      return;
    }

    final posMs = state.position.inMilliseconds;
    final targetLine = state.lyrics[state.activeLyricIndex];

    final deltaMs = posMs - targetLine.timestamp.inMilliseconds;

    final List<LyricLine> newLyrics = [];

    for (var line in state.lyrics) {
      int newMs = line.timestamp.inMilliseconds + deltaMs;
      if (newMs < 0) newMs = 0;

      newLyrics.add(
        LyricLine(
          timestamp: Duration(milliseconds: newMs),
          text: line.text,
        ),
      );
    }

    await _saveLyricsToFile(state.currentTrackPath!, newLyrics);
    state = state.copyWith(lyrics: newLyrics);
  }

  Future<void> _saveLyricsToFile(
    String audioPath,
    List<dynamic> currentLyrics,
  ) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    final buffer = StringBuffer();

    for (dynamic line in currentLyrics) {
      final totalMs = line.timestamp.inMilliseconds as int;
      final min = (totalMs ~/ 60000).toString().padLeft(2, '0');
      final sec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
      final ms = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
      buffer.writeln('[$min:$sec.$ms]${line.text}');
    }

    await file.writeAsString(buffer.toString());
  }

  Future<void> shiftLyrics(int offsetMs) async {
    if (state.currentTrackPath == null) return;
    final lrcPath = state.currentTrackPath!.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    if (!file.existsSync()) return;

    try {
      final lines = await file.readAsLines();
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      final newLines = <String>[];

      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          int ms = int.parse(match.group(3)!);
          if (match.group(3)!.length == 2) ms *= 10;

          int totalMs = (min * 60000) + (sec * 1000) + ms + offsetMs;
          if (totalMs < 0) totalMs = 0;

          final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
          final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
          final text = match.group(4)!;
          newLines.add('[$newMin:$newSec.$newMs]$text');
        } else {
          newLines.add(line);
        }
      }
      await file.writeAsString(newLines.join('\n'));
      await _loadLyrics(state.currentTrackPath!);
    } catch (_) {}
  }

  Future<void> shiftLyricsPartial(int offsetMs, int thresholdMs) async {
    if (state.currentTrackPath == null) return;
    final lrcPath = state.currentTrackPath!.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);
    if (!file.existsSync()) return;

    try {
      final lines = await file.readAsLines();
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      final newLines = <String>[];

      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          int ms = int.parse(match.group(3)!);
          if (match.group(3)!.length == 2) ms *= 10;

          int originalMs = (min * 60000) + (sec * 1000) + ms;
          int totalMs = originalMs;

          if (originalMs >= thresholdMs - 100) {
            totalMs += offsetMs;
            if (totalMs < 0) totalMs = 0;
          }

          final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
          final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
          final text = match.group(4)!;
          newLines.add('[$newMin:$newSec.$newMs]$text');
        } else {
          newLines.add(line);
        }
      }
      await file.writeAsString(newLines.join('\n'));
      await _loadLyrics(state.currentTrackPath!);
    } catch (_) {}
  }
}

final playerProvider = NotifierProvider<PlayerNotifier, PlayerState>(
  PlayerNotifier.new,
);
