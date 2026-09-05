import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
// 🛡️ FIX: Se cambió foundation.dart por material.dart para dar acceso al BuildContext
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../core/hal/platform_strategy.dart';
import '../core/audio/dj_audio_handler.dart';

import 'db_provider.dart';
import 'nlp_provider.dart';
import 'equalizer_provider.dart';
import 'dsp_provider.dart'; // 🛡️ FIX: Dependencia para dspWorkerProvider

enum MixStrategy { sequential, random }

/// Perfil acústico de la transición. Define si la mezcla permuta los graves
/// entre decks o se limita al crossfade DAWN puro.
enum AutomixMixProfile { smoothBassSwap, manualOverride }

// 🎚️ Corte de graves de la permuta de bajos: Butterworth de 2 polos a 140 Hz.
// Se inyecta en libmpv vía la propiedad 'af'; cero DSP por muestras en Dart.
const String _bassKillFilter = 'highpass=f=140:poles=2';

class LyricLine {
  final Duration timestamp;
  final String text;
  LyricLine({required this.timestamp, required this.text});
}

class AutomixState {
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

  AutomixState({
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

  AutomixState copyWith({
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
    return AutomixState(
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

class AutomixNotifier extends Notifier<AutomixState> {
  late final Player _playerA;
  late final Player _playerB;
  bool _usePlayerA = true;

  Player get _activeAutomix => _usePlayerA ? _playerA : _playerB;
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

  late final PlatformMixStrategy _mixStrategy;

  @override
  AutomixState build() {
    _playerA = Player();
    _playerB = Player();

    _mixStrategy = MixStrategyFactory.getStrategy();

    (_playerA.platform as dynamic)?.setProperty('af', _mixStrategy.hifiFilter);
    (_playerB.platform as dynamic)?.setProperty('af', _mixStrategy.hifiFilter);

    _attachListeners(_playerA);
    _initPersistence();

    globalAudioHandler.onPlayPause = () => togglePlayPause();
    globalAudioHandler.onNext = () => forceTransition(state.currentIndex + 1);
    globalAudioHandler.onPrevious = () =>
        forceTransition(state.currentIndex - 1);
    globalAudioHandler.onSeek = (pos) => seek(pos);

    ref.onDispose(() {
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
      _completedSub?.cancel();
      _playerA.dispose();
      _playerB.dispose();
    });

    return AutomixState();
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
    return _mixStrategy.getSessionPath();
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
        await _activeAutomix.open(Media(playlist[index]), play: false);

        try {
          await _activeAutomix.stream.duration
              .firstWhere((d) => d.inMilliseconds > 0)
              .timeout(const Duration(seconds: 2));
        } catch (_) {}

        if (positionMs != null && positionMs > 0) {
          await _activeAutomix.seek(Duration(milliseconds: positionMs));
        } else if (state.customCueInMs > 0) {
          await _activeAutomix.seek(
            Duration(milliseconds: state.customCueInMs),
          );
        }
      }
    } catch (_) {}
  }

  void setMixStrategy(MixStrategy strategy) {
    state = state.copyWith(mixStrategy: strategy);
    _saveSnapshot();
    _recalculateMixWindow();
  }

  void shufflePlaylist() {
    if (state.playlist.length <= 2) {
      state = state.copyWith(mixStrategy: MixStrategy.random);
      _saveSnapshot();
      return;
    }

    final currentTrack = state.playlist.first;
    List<String> remainingTracks = state.playlist.sublist(1);

    remainingTracks.shuffle(Random(DateTime.now().millisecondsSinceEpoch));

    List<String> newPlaylist = [currentTrack, ...remainingTracks];

    state = state.copyWith(
      playlist: newPlaylist,
      currentIndex: 0,
      mixStrategy: MixStrategy.random,
    );

    _saveSnapshot();
    _recalculateMixWindow();

    debugPrint(
      "🔀 [DSP] True Shuffle aplicado. ${remainingTracks.length} pistas reordenadas.",
    );
  }

  void toggleMixStrategy() {
    if (state.mixStrategy == MixStrategy.sequential) {
      shufflePlaylist();
    } else {
      state = state.copyWith(mixStrategy: MixStrategy.sequential);
      _saveSnapshot();
      debugPrint("➡️ [DSP] Modo SECUENCIAL activado.");
    }
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

  Future<void> seek(Duration position) async {
    if (state.currentTrackPath == null || _isCrossfading) return;
    _isPrepModeBypass = false;
    await _activeAutomix.seek(position);
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
    final meta = await ref.read(dbServiceProvider).getTrackMetadata(path);

    if (meta != null &&
        meta.isManualCue &&
        meta.cueInMs != null &&
        meta.cueInMs! > 0) {
      return meta.cueInMs!;
    }

    final int durMs = player.state.duration.inMilliseconds;
    if (durMs > 30000) return 10000;
    return 0;
  }

  Future<void> _recalculateMixWindow() async {
    if (state.duration.inMilliseconds == 0) return;
    final nextIdx = _calculateNextIndex();
    final nextPath = nextIdx != -1 ? state.playlist[nextIdx] : null;

    int safeMixOutMs = state.customMixOutMs;
    int safeCueInMs = state.customCueInMs;

    final trackPathLower = state.currentTrackPath?.toLowerCase() ?? '';
    final isRemix = trackPathLower.contains('remix');
    final isEdm =
        trackPathLower.contains('electronica') ||
        trackPathLower.contains('house');
    final isTropical =
        trackPathLower.contains('salsa') ||
        trackPathLower.contains('cumbia') ||
        trackPathLower.contains('merengue');

    if (safeMixOutMs <= 0) {
      if (state.lyrics.isNotEmpty) {
        final lastLyricMs = state.lyrics.last.timestamp.inMilliseconds;
        safeMixOutMs = lastLyricMs + 1500;
      } else {
        if (isRemix || isEdm) {
          safeMixOutMs = (state.duration.inMilliseconds * 0.65).toInt();
        } else if (isTropical) {
          safeMixOutMs = (state.duration.inMilliseconds * 0.80).toInt();
        } else {
          safeMixOutMs = (state.duration.inMilliseconds * 0.75).toInt();
        }
      }
    }

    if (safeMixOutMs > 0 &&
        safeMixOutMs >= state.duration.inMilliseconds - 4000) {
      safeMixOutMs = state.duration.inMilliseconds - 4000;
    }
    if (safeCueInMs > 0 && safeCueInMs > state.duration.inMilliseconds ~/ 2) {
      safeCueInMs = 0;
    }

    int triggerMs = 0;
    if (safeMixOutMs > 0) {
      triggerMs = state.duration.inMilliseconds - safeMixOutMs;
    } else {
      triggerMs = 8000;
    }

    state = state.copyWith(
      nextTrackPath: nextPath,
      triggerRemainingMs: triggerMs,
      customMixOutMs: safeMixOutMs,
      customCueInMs: safeCueInMs,
    );
  }

  Future<void> forceTransition(int index) async {
    await jumpToTrack(index);
  }

  int _calculateNextIndex() {
    if (state.playlist.length <= 1) return -1;
    if (state.currentIndex + 1 < state.playlist.length) {
      return state.currentIndex + 1;
    }
    return 0;
  }

  Future<void> loadContextAndPlay(
    List<String> newPlaylist,
    int startIndex,
  ) async {
    if (startIndex < 0 || startIndex >= newPlaylist.length) return;

    final String nextTrack = newPlaylist[startIndex];

    if (!state.isPlaying || state.currentTrackPath == null) {
      state = state.copyWith(
        playlist: newPlaylist,
        currentIndex: startIndex,
        currentTrackPath: nextTrack,
        position: Duration.zero,
        lyrics: [],
        activeLyricIndex: -1,
      );

      await _activeAutomix.setVolume(100.0);
      await _activeAutomix.open(Media(nextTrack), play: true);
      _attachListeners(_activeAutomix);

      await _loadLyrics(nextTrack);
      await _loadTrackMetadata(nextTrack);
      try {
        _recalculateMixWindow();
      } catch (_) {}
      _saveSnapshot();
      return;
    }

    if (!_isCrossfading) {
      _isCrossfading = true;
      _isPrepModeBypass = false;

      final Player fadingPlayer = _activeAutomix;
      final Player incomingPlayer = _standbyPlayer;

      try {
        await incomingPlayer.setVolume(0.0);
        await incomingPlayer.open(Media(nextTrack), play: false);
      } catch (e) {
        _isCrossfading = false;
        return;
      }

      try {
        await incomingPlayer.setRate(1.0);
        await incomingPlayer.play();
      } catch (e) {
        _isCrossfading = false;
        return;
      }

      _usePlayerA = !_usePlayerA;
      _attachListeners(_activeAutomix);

      List<String> updatedPlaylist = List.from(newPlaylist);
      updatedPlaylist.remove(nextTrack);
      updatedPlaylist.insert(0, nextTrack);

      state = state.copyWith(
        playlist: updatedPlaylist,
        currentIndex: 0,
        currentTrackPath: nextTrack,
        position: Duration.zero,
        duration: incomingPlayer.state.duration,
        lyrics: [],
        activeLyricIndex: -1,
      );

      await _loadLyrics(nextTrack);
      await _loadTrackMetadata(nextTrack);
      try {
        _recalculateMixWindow();
      } catch (_) {}
      _saveSnapshot();

      await _executeMixEngine(
        fadingPlayer: fadingPlayer,
        incomingPlayer: incomingPlayer,
        mixDurationMs: 4500,
        mixProfile: AutomixMixProfile.manualOverride,
        incomingRate: 1.0,
        isManualSkip: true,
      );
    }
  }

  Future<void> jumpToTrack(int index) async {
    if (index < 0 || index >= state.playlist.length || _isCrossfading) return;
    if (state.currentIndex == index && state.isPlaying) return;

    _isCrossfading = true;
    _isPrepModeBypass = false;

    final String nextTrack = state.playlist[index];
    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    int cueInMs = 0;
    try {
      cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {}

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
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);

    List<String> newPlaylist = List.from(state.playlist);
    if (state.currentTrackPath != null) {
      newPlaylist.remove(state.currentTrackPath);
    }
    newPlaylist.remove(nextTrack);
    newPlaylist.insert(0, nextTrack);

    state = state.copyWith(
      playlist: newPlaylist,
      currentIndex: 0,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: incomingPlayer.state.duration,
      lyrics: [],
      activeLyricIndex: -1,
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    try {
      _recalculateMixWindow();
    } catch (_) {}
    _saveSnapshot();

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: 4500,
      mixProfile: AutomixMixProfile.manualOverride,
      incomingRate: incomingRate,
      isManualSkip: true,
    );
  }

  Future<void> _triggerCrossfade() async {
    if (_isCrossfading || state.nextTrackPath == null) return;
    _isCrossfading = true;

    final String nextTrack = state.nextTrackPath!;
    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    try {
      await incomingPlayer.setVolume(0.0);
      await incomingPlayer.open(Media(nextTrack), play: false);
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    int cueInMs = 0;
    try {
      cueInMs = await _calculateSmartCueIn(nextTrack, incomingPlayer);
      if (cueInMs > 0) {
        await incomingPlayer.seek(Duration(milliseconds: cueInMs));
        await Future.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {}

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
      await incomingPlayer.setRate(incomingRate);
      await incomingPlayer.play();
    } catch (e) {
      _isCrossfading = false;
      return;
    }

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);

    List<String> newPlaylist = List.from(state.playlist);
    if (state.currentTrackPath != null) {
      newPlaylist.remove(state.currentTrackPath);
    }
    newPlaylist.remove(nextTrack);
    newPlaylist.insert(0, nextTrack);

    state = state.copyWith(
      playlist: newPlaylist,
      currentIndex: 0,
      currentTrackPath: nextTrack,
      position: Duration(milliseconds: cueInMs),
      duration: incomingPlayer.state.duration,
      lyrics: [],
      activeLyricIndex: -1,
    );

    await _loadLyrics(nextTrack);
    await _loadTrackMetadata(nextTrack);
    try {
      _recalculateMixWindow();
    } catch (_) {}
    _saveSnapshot();

    final bool isAutomix = state.lyrics.isNotEmpty;
    final int mixDuration = isAutomix ? 14000 : 18000;

    await _executeMixEngine(
      fadingPlayer: fadingPlayer,
      incomingPlayer: incomingPlayer,
      mixDurationMs: mixDuration,
      mixProfile: AutomixMixProfile.smoothBassSwap,
      incomingRate: incomingRate,
      isManualSkip: false,
    );
  }

  // 🛡️ FIX: INYECCIÓN DE LA SUPER MEZCLA DAWN Y PARÁMETROS CORREGIDOS
  Future<void> _executeMixEngine({
    required Player fadingPlayer,
    required Player incomingPlayer,
    required int mixDurationMs,
    required AutomixMixProfile mixProfile,
    double incomingRate = 1.0,
    bool isManualSkip = false,
  }) async {
    final String currentBaseFilter = ref
        .read(equalizerProvider.notifier)
        .currentBaseFilter;
    final platformOut = fadingPlayer.platform as dynamic;
    final platformIn = incomingPlayer.platform as dynamic;

    // Un skip manual de 4,5 s no da margen musical para permutar graves.
    final bool useBassSwap = mixProfile == AutomixMixProfile.smoothBassSwap;
    final String lowCutFilter = '$currentBaseFilter,$_bassKillFilter';
    bool bassSwapped = false;

    try {
      platformIn?.setProperty('audio-pitch-correction', 'yes');
      platformOut?.setProperty('audio-pitch-correction', 'yes');
      // La entrante nace sin graves para que nunca convivan dos líneas de bajo
      // sumando energía en el cruce. Inaudible: su volumen todavía es 0.
      platformIn?.setProperty(
        'af',
        useBassSwap ? lowCutFilter : currentBaseFilter,
      );
      platformOut?.setProperty('af', currentBaseFilter);

      await incomingPlayer.setVolume(0.0);

      final fadeStopwatch = Stopwatch()..start();
      final actualDuration = isManualSkip ? 4500 : mixDurationMs;

      while (fadeStopwatch.elapsedMilliseconds < actualDuration) {
        final progress = (fadeStopwatch.elapsedMilliseconds / actualDuration)
            .clamp(0.0, 1.0);

        // 🎛️ SUPER MEZCLA DAWN (Alta Energía / Cero Huecos Acústicos)
        final rateIn = (progress * 1.8).clamp(0.0, 1.0);
        final rateOut = ((1.0 - progress) * 1.8).clamp(0.0, 1.0);

        final smoothRateIn = pow(rateIn, 1.2).toDouble();
        final smoothRateOut = pow(rateOut, 1.2).toDouble();

        // 🔀 PERMUTA DE GRAVES en el cruce, donde ambas rondan el 0.9: la
        // saliente cede el bajo y la entrante lo recupera. Una única
        // reconstrucción de la cadena af por deck, enmascarada por el nivel
        // máximo de la mezcla.
        if (useBassSwap && !bassSwapped && progress >= 0.5) {
          bassSwapped = true;
          platformOut?.setProperty('af', lowCutFilter);
          platformIn?.setProperty('af', currentBaseFilter);
        }

        await incomingPlayer.setVolume(
          (smoothRateIn * 100.0).clamp(0.0, 100.0),
        );
        await fadingPlayer.setVolume((smoothRateOut * 100.0).clamp(0.0, 100.0));

        await Future.delayed(const Duration(milliseconds: 32));
      }
    } catch (e) {
      debugPrint("🔴 [ERROR DSP AUTOMIX]: $e");
    } finally {
      // 🛡️ FIX: el glide de tempo arranca en incomingRate. Fijar aquí el rate a
      // 1.0 provocaba un salto de velocidad hacia atrás al iniciar la rampa.
      final bool willGlideRate = incomingRate != 1.0 && !isManualSkip;

      try {
        await incomingPlayer.setVolume(100.0);
        if (!willGlideRate) await incomingPlayer.setRate(1.0);
        platformIn?.setProperty('af', currentBaseFilter);
        platformOut?.setProperty('af', currentBaseFilter);
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

  void _attachListeners(Player player) {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();

    _positionSub = player.stream.position.listen((Duration pos) {
      final posMs = pos.inMilliseconds;

      if (state.customCueInMs > 0 &&
          posMs < state.customCueInMs &&
          posMs < 1000) {
        player.seek(Duration(milliseconds: state.customCueInMs));
        return;
      }

      if (state.autoMixArmed &&
          state.customMixOutMs > 0 &&
          state.nextTrackPath != null) {
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

      state = state.copyWith(position: pos, activeLyricIndex: newLyricIndex);

      if ((pos.inMilliseconds - _lastSavedPositionMs).abs() > 5000) {
        _lastSavedPositionMs = pos.inMilliseconds;
        _saveSnapshot();
      }

      globalAudioHandler.updateOsPlaybackState(state.isPlaying, pos);

      if (state.autoMixArmed &&
          state.customMixOutMs <= 0 &&
          state.duration.inMilliseconds > 0 &&
          state.nextTrackPath != null) {
        int timeRemaining = state.duration.inMilliseconds - pos.inMilliseconds;

        if (timeRemaining > state.triggerRemainingMs) _isPrepModeBypass = false;
        if (timeRemaining <= state.triggerRemainingMs && !_isCrossfading) {
          if (!_isPrepModeBypass) _triggerCrossfade();
        }
      }
    });

    _durationSub = player.stream.duration.listen((dur) {
      state = state.copyWith(duration: dur);
      _recalculateMixWindow();

      if (state.currentTrackPath != null) {
        final fileName = state.currentTrackPath!
            .replaceAll('\\', '/')
            .split('/')
            .last;
        globalAudioHandler.updateOsMetadata(title: fileName, duration: dur);
      }
    });

    _playingSub = player.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
      globalAudioHandler.updateOsPlaybackState(playing, state.position);
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
        await _activeAutomix.seek(Duration(milliseconds: state.customCueInMs));
      }
    }
    await _activeAutomix.playOrPause();
    if (!state.isPlaying) _saveSnapshot();
  }

  Future<void> pause() async {
    if (state.isPlaying) {
      await _activeAutomix.pause();
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

    final Player fadingPlayer = _activeAutomix;
    final Player incomingPlayer = _standbyPlayer;

    await incomingPlayer.setVolume(100.0);
    await incomingPlayer.open(Media(newPath), play: true);

    _usePlayerA = !_usePlayerA;
    _attachListeners(_activeAutomix);
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
    debugPrint(
      "🗑️ [PAPELERA] Cues y archivo NLP destruidos y reseteados para: $path",
    );
  }

  void removeTrack(String path) {
    final newPlaylist = List<String>.from(state.playlist)..remove(path);
    int newIndex = state.currentIndex;
    if (state.currentTrackPath != null && state.currentTrackPath != path) {
      newIndex = newPlaylist.indexOf(state.currentTrackPath!);
    }
    state = state.copyWith(playlist: newPlaylist, currentIndex: newIndex);
    _saveSnapshot();
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
    debugPrint("✅ [SYNC GLOBAL] Matriz reconstruida por Delta: ${deltaMs}ms");
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

class PlayedTracksNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    _loadSession();
    return {};
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
    return '${dir.path}${Platform.pathSeparator}_played_tracks_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as List<dynamic>;
        state = data.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
  }

  Future<void> _saveSession(Set<String> currentPlayed) async {
    try {
      final file = File(_getSessionFilePath());
      await file.writeAsString(jsonEncode(currentPlayed.toList()));
    } catch (_) {}
  }

  void addTrack(String track) {
    if (!state.contains(track)) {
      final newState = {...state, track};
      state = newState;
      _saveSession(newState);
    }
  }

  void removeTrack(String track) {
    if (state.contains(track)) {
      final newState = Set<String>.from(state);
      newState.remove(track);
      state = newState;
      _saveSession(newState);
    }
  }
}

class AutomixQueueNotifier extends Notifier<List<File>> {
  @override
  List<File> build() {
    _loadSession();
    return [];
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
    return '${dir.path}${Platform.pathSeparator}_automix_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as List<dynamic>;
        List<File> files = [];
        for (String p in data) {
          if (File(p).existsSync()) files.add(File(p));
        }
        state = files;
      }
    } catch (_) {}
  }

  Future<void> _saveSession(List<File> currentQueue) async {
    try {
      final file = File(_getSessionFilePath());
      final paths = currentQueue.map((f) => f.path).toList();
      await file.writeAsString(jsonEncode(paths));
    } catch (_) {}
  }

  void addTrack(File file) {
    final newState = state.where((f) => f.path != file.path).toList();
    newState.add(file);
    state = newState;
    _saveSession(newState);
  }

  void addAll(List<File> files) {
    var newState = List<File>.from(state);
    for (var f in files) {
      newState.removeWhere((existing) => existing.path == f.path);
      newState.add(f);
    }
    state = newState;
    _saveSession(newState);
  }

  void removeTrack(String path) {
    final newState = state.where((f) => f.path != path).toList();
    state = newState;
    _saveSession(newState);
  }

  void clearQueue() {
    state = [];
    _saveSession([]);
  }

  void restoreQueue(List<String> paths) {
    List<File> files = [];
    for (String p in paths) {
      if (File(p).existsSync()) files.add(File(p));
    }
    state = files;
    _saveSession(files);
  }
}

enum TrackSortMode { alphabetical, bpmDesc, bpmAsc }

class TrackSortNotifier extends Notifier<TrackSortMode> {
  @override
  TrackSortMode build() => TrackSortMode.alphabetical;
  void updateMode(TrackSortMode mode) => state = mode;
}

class BpmCacheNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => {};

  Future<void> loadCache(String directoryPath) async {
    if (directoryPath.isEmpty) {
      state = {};
      return;
    }
    try {
      await ref.read(dspWorkerProvider).generateStaticBpmCache(directoryPath);
    } catch (_) {}

    final file = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.json',
    );
    if (file.existsSync()) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final Map<String, double> newCache = {};

        decoded.forEach((key, value) {
          if (value is num) {
            newCache[key] = value.toDouble();
          } else if (value is Map && value['bpm'] != null) {
            newCache[key] = (value['bpm'] as num).toDouble();
          }
        });
        state = newCache;
      } catch (e) {
        state = {};
      }
    } else {
      state = {};
    }
  }
}

class WasapiRecordNotifier extends Notifier<bool> {
  Process? _recordingProcess;
  String? _currentOutputPath;
  String _lastErrorLog = "";

  @override
  bool build() => false;

  Future<void> toggleRecording(BuildContext context) async {
    if (state) {
      await stopRecording(context);
    } else {
      await startRecording(context);
    }
  }

  String _getFFmpegPath() {
    if (Platform.isAndroid || Platform.isIOS) return 'ffmpeg';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final localFFmpeg = Platform.isWindows
        ? '$exeDir\\ffmpeg.exe'
        : '$exeDir/ffmpeg';
    if (File(localFFmpeg).existsSync()) return localFFmpeg;
    return 'ffmpeg';
  }

  Future<String> _getLoopbackDevice() async {
    if (Platform.isWindows) {
      try {
        final process = await Process.run(_getFFmpegPath(), [
          '-list_devices',
          'true',
          '-f',
          'dshow',
          '-i',
          'dummy',
        ]);
        final logs = process.stderr.toString();
        final lines = logs.split('\n');

        for (int i = 0; i < lines.length; i++) {
          final lowerLine = lines[i].toLowerCase();
          if (lowerLine.contains('(audio)') &&
              (lowerLine.contains('mezcla') ||
                  lowerLine.contains('estéreo') ||
                  lowerLine.contains('stereo'))) {
            if (i + 1 < lines.length &&
                lines[i + 1].toLowerCase().contains('alternative name')) {
              final match = RegExp(r'"([^"]+)"').firstMatch(lines[i + 1]);
              if (match != null) return 'audio=${match.group(1)!}';
            }
          }
        }
      } catch (_) {}
      return r'audio=@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{E2847FF6-6193-463E-848F-0E16C78BD2EA}';
    } else if (Platform.isMacOS) {
      return ':0';
    } else {
      throw UnsupportedError(
        'Driver de loopback no soportado en esta plataforma.',
      );
    }
  }

  Future<void> startRecording(BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (context.mounted) {
        _showErrorDialog(
          context,
          "VETO TÉCNICO: Sandbox Restringido",
          "La captura del Master Out en Android/iOS está bloqueada a nivel de Kernel por políticas de privacidad. Se requiere migrar a APIs nativas (MediaProjection/ReplayKit).",
        );
      }
      return;
    }

    final userProfile =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final baseDir = Platform.isWindows
        ? '$userProfile\\Music\\GrabacionesDj'
        : '$userProfile/Music/GrabacionesDj';

    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final dateStr = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    _currentOutputPath =
        '${dir.path}${Platform.pathSeparator}LiveMix_$dateStr.mp3';
    _lastErrorLog = "";

    try {
      final deviceName = await _getLoopbackDevice();
      final format = Platform.isWindows ? 'dshow' : 'avfoundation';

      debugPrint(
        "🟢 [Hardware Tracker] Ruteando bus maestro a: $deviceName ($format)",
      );

      final args = [
        '-y',
        '-f',
        format,
        '-i',
        deviceName,
        '-c:a',
        'libmp3lame',
        '-b:a',
        '320k',
        _currentOutputPath!,
      ];

      _recordingProcess = await Process.start(_getFFmpegPath(), args);
      state = true;

      _recordingProcess!.stderr.transform(utf8.decoder).listen((log) {
        _lastErrorLog += log;
      });

      _recordingProcess!.exitCode.then((code) {
        if (code != 0 && code != 255 && state) {
          state = false;
          if (context.mounted) {
            _showErrorDialog(
              context,
              "🔴 VETO TÉCNICO: FFmpeg Colapsó",
              _lastErrorLog,
            );
          }
        }
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 GRABANDO MASTER OUT: LiveMix_$dateStr.mp3',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 [RECORD FATAL]: $e");
    }
  }

  Future<void> stopRecording(BuildContext context) async {
    if (_recordingProcess != null) {
      _recordingProcess!.stdin.writeln('q');
      await Future.delayed(const Duration(milliseconds: 500));
      _recordingProcess!.kill();
      _recordingProcess = null;
    }

    state = false;

    final file = File(_currentOutputPath ?? '');
    final fileExists = file.existsSync() && file.lengthSync() > 0;

    if (context.mounted) {
      if (fileExists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Mezcla renderizada en: $_currentOutputPath',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: const Color(0xFF39FF14),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '❌ ERROR: Archivo vacío o I/O bloqueado.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showErrorDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.redAccent,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'Consolas',
                fontSize: 11,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "Cerrar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

// 🛡️ DECLARACIÓN DE LOS PROVIDERS SEPARADOS:
final automixProvider = NotifierProvider<AutomixNotifier, AutomixState>(
  AutomixNotifier.new,
);

final automixQueueProvider = NotifierProvider<AutomixQueueNotifier, List<File>>(
  AutomixQueueNotifier.new,
);

final playedTracksProvider =
    NotifierProvider<PlayedTracksNotifier, Set<String>>(
      PlayedTracksNotifier.new,
    );

final trackSortProvider = NotifierProvider<TrackSortNotifier, TrackSortMode>(
  TrackSortNotifier.new,
);

final bpmCacheProvider =
    NotifierProvider<BpmCacheNotifier, Map<String, double>>(
      BpmCacheNotifier.new,
    );

final wasapiRecordProvider = NotifierProvider<WasapiRecordNotifier, bool>(
  WasapiRecordNotifier.new,
);
