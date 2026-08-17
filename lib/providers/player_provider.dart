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

enum MixStrategy { sequential, random }

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
  final int _triggerRemainingMs = 4000;
  bool _isPrepModeBypass = false;
  int _lastSavedPositionMs = 0;

  @override
  PlayerState build() {
    _playerA = Player();
    _playerB = Player();

    // 🛠️ FIX FIDELIDAD:
    // 1. aresample=resampler=soxr:precision=28 -> Remuestreo de grado audiófilo.
    // 2. crystalizer=i=2.0 -> Genera armónicos perdidos por la compresión MP3.
    // 3. bass=g=3:f=60 -> Realce controlado de sub-graves.
    // 4. extrastereo=m=1.15 -> Ensanchador espacial.
    final hifiFilter =
        'aresample=resampler=soxr:precision=28,crystalizer=i=2.0,bass=g=3:f=60,extrastereo=m=1.15';

    (_playerA.platform as dynamic)?.setProperty('af', hifiFilter);
    (_playerB.platform as dynamic)?.setProperty('af', hifiFilter);

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
        isManualCue: true, // 🛠️ ACTIVA BLINDAJE EN DB
      );
      state = state.copyWith(customCueInMs: currentPosMs);
    } else {
      await db.saveTrackMetadata(
        path: state.currentTrackPath!,
        mixOutMs: currentPosMs,
        isManualCue: true, // 🛠️ ACTIVA BLINDAJE EN DB
      );
      state = state.copyWith(customMixOutMs: currentPosMs, autoMixArmed: true);
      _recalculateMixWindow();
      if (!state.isPlaying) _isPrepModeBypass = true;
    }
  }

  String _getSessionFilePath() {
    String baseDir = Platform.isWindows
        ? '${Platform.environment['USERPROFILE']}\\Music\\DjPlaylists'
        : '/storage/emulated/0/Music/DjPlaylists';
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
          autoMixArmed: autoMixArmed,
        );

        await _loadLyrics(playlist[index]);
        await _loadTrackMetadata(playlist[index]);
        await _activePlayer.open(Media(playlist[index]), play: false);

        // 🛠️ FIX: Esperar resolución del decodificador antes de saltar
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

  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((pos) {
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
        position: pos,
        activeLyricIndex: newLyricIndex,
        triggerRemainingMs: _triggerRemainingMs,
      );

      if ((pos.inMilliseconds - _lastSavedPositionMs).abs() > 5000) {
        _lastSavedPositionMs = pos.inMilliseconds;
        _saveSnapshot();
      }

      if (state.autoMixArmed &&
          !_isCrossfading &&
          state.duration.inMilliseconds > 0 &&
          state.nextTrackPath != null) {
        int timeRemaining = state.duration.inMilliseconds - pos.inMilliseconds;
        if (timeRemaining > _triggerRemainingMs) _isPrepModeBypass = false;
        if (timeRemaining <= _triggerRemainingMs) {
          if (!_isPrepModeBypass) _triggerCrossfade();
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
      _recalculateMixWindow(); // Recalibra conociendo la duración real
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });

    _completedSub = player.stream.completed.listen((completed) {
      if (completed &&
          state.autoMixArmed &&
          !_isCrossfading &&
          state.nextTrackPath != null) {
        debugPrint("🔴 [VBR/EOF DETECTADO]: Forzando rescate Automix...");
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

  Future<void> forceTransition(int index) async {
    if (index < 0 || index >= state.playlist.length || _isCrossfading) return;
    _isCrossfading = true;
    _isPrepModeBypass = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 5000;
    String mixProfile = 'constant_power';

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);
    if (meta != null) {
      if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = meta.mixDurationMs;
      mixProfile = meta.mixProfile;
    }
    if (mixDurationMs < 5000) mixDurationMs = 5000;

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

    // 🛠️ MOTOR V4: BEATMATCHING DINÁMICO (TIME-STRETCH)
    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      // Blindaje de deformación acústica (Max 12% Delta)
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

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    _saveSnapshot();

    int steps = mixDurationMs ~/ 100;
    if (steps < 10) steps = 10;
    final int stepTimeMs = mixDurationMs ~/ steps;

    for (int i = 0; i < steps; i++) {
      double progress = i / steps;
      double volOut = 100.0, volIn = 100.0;
      if (mixProfile == 'linear') {
        volOut = (1.0 - progress) * 100.0;
        volIn = progress * 100.0;
      } else if (mixProfile == 'sharp') {
        volOut = progress < 0.9
            ? 100.0
            : (1.0 - (progress - 0.9) * 10.0) * 100.0;
        volIn = progress > 0.1 ? 100.0 : (progress * 10.0) * 100.0;
      } else if (mixProfile == 'eq_kill') {
        volOut = pow(1.0 - progress, 2.5) * 100.0;
        volIn = 70.0 + (progress * 30.0);
      } else {
        volOut = cos(progress * (pi / 2)) * 100.0;
        volIn = sin(progress * (pi / 2)) * 100.0;
      }
      await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
      await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
      await Future.delayed(Duration(milliseconds: stepTimeMs));
    }

    await fadingPlayer.stop();
    await fadingPlayer.setVolume(100.0);
    await fadingPlayer.setRate(1.0); // Reseteo de seguridad

    // 🛠️ MOTOR V4: PITCH RELEASE (Liberación gradual de 3 segundos)
    if (incomingRate != 1.0) {
      int pitchSteps = 30;
      int pitchStepTimeMs = 100;
      double rateDiff = 1.0 - incomingRate;
      double rateStep = rateDiff / pitchSteps;

      for (int i = 1; i <= pitchSteps; i++) {
        // Asegurar que el usuario no forzó otra mezcla mientras liberábamos el pitch
        if ((_usePlayerA && incomingPlayer == _playerA) ||
            (!_usePlayerA && incomingPlayer == _playerB)) {
          await incomingPlayer.setRate(
            (incomingRate + (rateStep * i)).clamp(0.5, 2.0),
          );
          await Future.delayed(Duration(milliseconds: pitchStepTimeMs));
        } else {
          break;
        }
      }
      await incomingPlayer.setRate(1.0);
    }

    _isCrossfading = false;
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= state.playlist.length || _isCrossfading) return;
    if (state.currentIndex == index && state.isPlaying) return;

    _isCrossfading = true;
    _isPrepModeBypass = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activePlayer;
    final Player incomingPlayer = _standbyPlayer;

    int cueInMs = 0;
    int mixDurationMs = 6000;
    String mixProfile = 'constant_power';

    final meta = await ref.read(dbServiceProvider).getTrackMetadata(nextTrack);
    if (meta != null) {
      if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = meta.mixDurationMs;
      mixProfile = meta.mixProfile;
    }
    if (cueInMs < 0) cueInMs = 0;

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

    // 🛠️ MOTOR V4: BEATMATCHING DINÁMICO (TIME-STRETCH)
    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      // Blindaje de deformación acústica (Max 12% Delta)
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

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    _saveSnapshot();

    int steps = mixDurationMs ~/ 100;
    if (steps < 10) steps = 10;
    final int stepTimeMs = mixDurationMs ~/ steps;

    for (int i = 0; i < steps; i++) {
      double progress = i / steps;
      double volOut = 100.0, volIn = 100.0;
      if (mixProfile == 'linear') {
        volOut = (1.0 - progress) * 100.0;
        volIn = progress * 100.0;
      } else if (mixProfile == 'sharp') {
        volOut = progress < 0.9
            ? 100.0
            : (1.0 - (progress - 0.9) * 10.0) * 100.0;
        volIn = progress > 0.1 ? 100.0 : (progress * 10.0) * 100.0;
      } else if (mixProfile == 'eq_kill') {
        volOut = pow(1.0 - progress, 2.5) * 100.0;
        volIn = 70.0 + (progress * 30.0);
      } else {
        volOut = cos(progress * (pi / 2)) * 100.0;
        volIn = sin(progress * (pi / 2)) * 100.0;
      }
      await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
      await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
      await Future.delayed(Duration(milliseconds: stepTimeMs));
    }

    await fadingPlayer.stop();
    await fadingPlayer.setVolume(100.0);
    await fadingPlayer.setRate(1.0); // Reseteo de seguridad

    // 🛠️ MOTOR V4: PITCH RELEASE (Liberación gradual de 3 segundos)
    if (incomingRate != 1.0) {
      int pitchSteps = 30;
      int pitchStepTimeMs = 100;
      double rateDiff = 1.0 - incomingRate;
      double rateStep = rateDiff / pitchSteps;

      for (int i = 1; i <= pitchSteps; i++) {
        if ((_usePlayerA && incomingPlayer == _playerA) ||
            (!_usePlayerA && incomingPlayer == _playerB)) {
          await incomingPlayer.setRate(
            (incomingRate + (rateStep * i)).clamp(0.5, 2.0),
          );
          await Future.delayed(Duration(milliseconds: pitchStepTimeMs));
        } else {
          break;
        }
      }
      await incomingPlayer.setRate(1.0);
    }

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
    if (meta != null) {
      if (meta.cueInMs != null) cueInMs = meta.cueInMs!;
      mixDurationMs = meta.mixDurationMs;
      mixProfile = meta.mixProfile;
    }
    if (cueInMs < 0) cueInMs = 0;

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

    // 🛠️ MOTOR V4: BEATMATCHING DINÁMICO (TIME-STRETCH)
    final fadingBpm = _extractBpm(state.currentTrackPath);
    final incomingBpm = _extractBpm(nextTrack);
    double incomingRate = 1.0;

    if (fadingBpm > 60 && incomingBpm > 60) {
      final ratio = fadingBpm / incomingBpm;
      // Blindaje de deformación acústica (Max 12% Delta)
      if (ratio >= 0.88 && ratio <= 1.12) {
        incomingRate = ratio;
      }
    }
    await incomingPlayer.setRate(incomingRate);

    await incomingPlayer.play();
    _usePlayerA = !_usePlayerA;
    _attachListeners(_activePlayer);

    state = state.copyWith(
      currentIndex: nextIndex,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    _saveSnapshot();

    int steps = mixDurationMs ~/ 100;
    if (steps < 10) steps = 10;
    final int stepTimeMs = mixDurationMs ~/ steps;

    for (int i = 0; i < steps; i++) {
      double progress = i / steps;
      double volOut = 100.0, volIn = 100.0;
      if (mixProfile == 'linear') {
        volOut = (1.0 - progress) * 100.0;
        volIn = progress * 100.0;
      } else if (mixProfile == 'sharp') {
        volOut = progress < 0.9
            ? 100.0
            : (1.0 - (progress - 0.9) * 10.0) * 100.0;
        volIn = progress > 0.1 ? 100.0 : (progress * 10.0) * 100.0;
      } else if (mixProfile == 'eq_kill') {
        volOut = pow(1.0 - progress, 2.5) * 100.0;
        volIn = 70.0 + (progress * 30.0);
      } else {
        volOut = cos(progress * (pi / 2)) * 100.0;
        volIn = sin(progress * (pi / 2)) * 100.0;
      }
      await fadingPlayer.setVolume(volOut.clamp(0.0, 100.0));
      await incomingPlayer.setVolume(volIn.clamp(0.0, 100.0));
      await Future.delayed(Duration(milliseconds: stepTimeMs));
    }

    await fadingPlayer.stop();
    await fadingPlayer.setVolume(100.0);
    await fadingPlayer.setRate(1.0); // Reseteo de seguridad

    // 🛠️ MOTOR V4: PITCH RELEASE (Liberación gradual de 3 segundos)
    if (incomingRate != 1.0) {
      int pitchSteps = 30;
      int pitchStepTimeMs = 100;
      double rateDiff = 1.0 - incomingRate;
      double rateStep = rateDiff / pitchSteps;

      for (int i = 1; i <= pitchSteps; i++) {
        if ((_usePlayerA && incomingPlayer == _playerA) ||
            (!_usePlayerA && incomingPlayer == _playerB)) {
          await incomingPlayer.setRate(
            (incomingRate + (rateStep * i)).clamp(0.5, 2.0),
          );
          await Future.delayed(Duration(milliseconds: pitchStepTimeMs));
        } else {
          break; // Abortar si hubo otro salto manual a mitad del release
        }
      }
      await incomingPlayer.setRate(1.0);
    }

    _isCrossfading = false;
  }

  Future<void> _recalculateMixWindow() async {
    if (state.duration.inMilliseconds == 0) return;
    final nextIdx = _calculateNextIndex();
    final nextPath = nextIdx != -1 ? state.playlist[nextIdx] : null;

    int dynamicMixDurationMs = 6000;
    if (nextPath != null) {
      final nextMeta = await ref
          .read(dbServiceProvider)
          .getTrackMetadata(nextPath);
      if (nextMeta != null) dynamicMixDurationMs = nextMeta.mixDurationMs;
    }

    int safeMixOutMs = state.customMixOutMs;
    int safeCueInMs = state.customCueInMs;

    // 🛠️ LIMITADOR GEOMÉTRICO (Out-of-Bounds Failsafe)
    // Previene que la basura NLP coloque el punto de salida más allá de la duración de la pista.
    if (safeMixOutMs > 0 &&
        safeMixOutMs >= state.duration.inMilliseconds - dynamicMixDurationMs) {
      safeMixOutMs =
          state.duration.inMilliseconds - dynamicMixDurationMs - 1000;
    }
    if (safeCueInMs > 0 && safeCueInMs > state.duration.inMilliseconds ~/ 2) {
      safeCueInMs =
          0; // Invalida el Cue si está más allá de la mitad de la canción.
    }

    int triggerMs = 0;
    if (safeMixOutMs > 0) {
      triggerMs = state.duration.inMilliseconds - safeMixOutMs;
      if (triggerMs < dynamicMixDurationMs) {
        triggerMs = dynamicMixDurationMs;
      }
    } else {
      triggerMs = dynamicMixDurationMs + 2000;
    }

    state = state.copyWith(
      nextTrackPath: nextPath,
      triggerRemainingMs: triggerMs,
      customMixOutMs: safeMixOutMs,
      customCueInMs: safeCueInMs,
    );
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
    await _loadTrackMetadata(path);

    int cueInMs = 0;
    final meta = await ref.read(dbServiceProvider).getTrackMetadata(path);
    if (meta != null && meta.cueInMs != null) cueInMs = meta.cueInMs!;

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
    await _loadTrackMetadata(newPath);

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

    // 1. Reset visual en RAM
    state = state.copyWith(customCueInMs: 0, customMixOutMs: 0);

    // 2. Destrucción Física del archivo .lrc corrupto en el disco duro
    final lrcPath = path.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);
    if (lrcFile.existsSync()) {
      lrcFile.deleteSync();
    }

    // 3. Reset en Base de Datos ISAR (Sobreescribimos forzando ceros y liberamos candado manual)
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

    // 4. Invocamos al Scraper NLP para redescargar un archivo completamente virgen y limpio
    try {
      await ref.read(nlpWorkerProvider).processSingleFile(path);
    } catch (_) {}

    // 5. Limpiamos la matriz de letras en pantalla
    state = state.copyWith(lyrics: [], activeLyricIndex: -1);
    debugPrint(
      "🗑️ [PAPELERA] Cues y archivo NLP destruidos y reseteados para: $path",
    );
  }

  Future<void> autoSyncFirstLyric() async {
    if (state.currentTrackPath == null || state.lyrics.isEmpty) return;

    final posMs = state.position.inMilliseconds;
    final targetLine = state.lyrics.first;

    final deltaMs = posMs - targetLine.timestamp.inMilliseconds;

    // 🛠️ FIX: Reconstrucción inmutable de la matriz para evitar choque con variables 'final'
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
    debugPrint("✅ [SYNC GLOBAL] Matriz reconstruida por Delta: ${deltaMs}ms");
  }

  Future<void> autoSyncFromCurrentLyric() async {
    if (state.currentTrackPath == null ||
        state.lyrics.isEmpty ||
        state.activeLyricIndex < 0)
      return;

    final posMs = state.position.inMilliseconds;
    final targetLine = state.lyrics[state.activeLyricIndex];

    final deltaMs = posMs - targetLine.timestamp.inMilliseconds;

    // 🛠️ FIX: Reconstrucción inmutable de la matriz para evitar choque con variables 'final'
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
    debugPrint("✅ [SYNC MED] Matriz reconstruida por Delta: ${deltaMs}ms");
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
      // 🛠️ FIX: Acceso correcto y extracción para guardado físico
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
