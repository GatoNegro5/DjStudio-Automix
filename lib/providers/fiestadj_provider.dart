import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../core/audio/dj_audio_handler.dart';
import '../core/hal/platform_strategy.dart';
import '../fiestadj/fiesta_beat_analyzer.dart';
import '../fiestadj/fiesta_loop_synth.dart';
import '../fiestadj/fiesta_planner.dart';
import '../services/adaptive_eq.dart';
import 'directory_provider.dart';

/// Explorador propio de FiestaDj (carpeta y árbol independientes).
final fiestaDjDirectoryProvider =
    NotifierProvider<DirectoryNotifier, DirectoryState>(
      () => DirectoryNotifier(sessionFileName: '_fiestadj_explorer_session.json'),
    );

enum FiestaPhase { idle, preparing, playing, paused }

/// Cuándo suena la pista base (el loop de ritmo).
enum FiestaBaseMode { transitions, always, off }

class FiestaState {
  final FiestaPhase phase;
  final String status;
  final String? currentPath;
  final String? nextPath;
  final double currentBpm;
  final double nextBpm;
  final double masterBpm;
  final Duration position;
  final Duration duration;
  final FiestaStyle styleChoice;
  final FiestaStyle style;
  final FiestaBaseMode baseMode;
  final double baseVolume;
  final int latencyMs;
  final bool autoRecord;
  final bool mixing;
  final bool currentOnGrid;
  final int played;

  const FiestaState({
    this.phase = FiestaPhase.idle,
    this.status = 'Elige una carpeta y pulsa INICIAR FIESTA',
    this.currentPath,
    this.nextPath,
    this.currentBpm = 0,
    this.nextBpm = 0,
    this.masterBpm = 0,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.styleChoice = FiestaStyle.auto,
    this.style = FiestaStyle.pulso,
    this.baseMode = FiestaBaseMode.transitions,
    this.baseVolume = 0.55,
    this.latencyMs = 60,
    this.autoRecord = false,
    this.mixing = false,
    this.currentOnGrid = false,
    this.played = 0,
  });

  bool get isPlaying => phase == FiestaPhase.playing;
  bool get isActive => phase == FiestaPhase.playing || phase == FiestaPhase.paused;

  FiestaState copyWith({
    FiestaPhase? phase,
    String? status,
    String? currentPath,
    bool clearCurrent = false,
    String? nextPath,
    bool clearNext = false,
    double? currentBpm,
    double? nextBpm,
    double? masterBpm,
    Duration? position,
    Duration? duration,
    FiestaStyle? styleChoice,
    FiestaStyle? style,
    FiestaBaseMode? baseMode,
    double? baseVolume,
    int? latencyMs,
    bool? autoRecord,
    bool? mixing,
    bool? currentOnGrid,
    int? played,
  }) {
    return FiestaState(
      phase: phase ?? this.phase,
      status: status ?? this.status,
      currentPath: clearCurrent ? null : (currentPath ?? this.currentPath),
      nextPath: clearNext ? null : (nextPath ?? this.nextPath),
      currentBpm: currentBpm ?? this.currentBpm,
      nextBpm: nextBpm ?? this.nextBpm,
      masterBpm: masterBpm ?? this.masterBpm,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      styleChoice: styleChoice ?? this.styleChoice,
      style: style ?? this.style,
      baseMode: baseMode ?? this.baseMode,
      baseVolume: baseVolume ?? this.baseVolume,
      latencyMs: latencyMs ?? this.latencyMs,
      autoRecord: autoRecord ?? this.autoRecord,
      mixing: mixing ?? this.mixing,
      currentOnGrid: currentOnGrid ?? this.currentOnGrid,
      played: played ?? this.played,
    );
  }
}

class _Deck {
  _Deck(this.player);
  final Player player;
  String? path;
  FiestaBeatInfo? beat;
  double bpm = 0;
  double rate = 1.0;
  double startMs = 0;
  bool grid = false;

  void clear() {
    path = null;
    beat = null;
    bpm = 0;
    rate = 1.0;
    startMs = 0;
    grid = false;
  }
}

class _MixPlan {
  _MixPlan({
    required this.forPath,
    required this.mixStartMs,
    required this.fadeRealMs,
    required this.grid,
    required this.barMediaMs,
    required this.inStartMs,
  });
  final String forPath;
  double mixStartMs; // posición de la saliente (ms de medio) donde empieza
  final double fadeRealMs;
  final bool grid;
  final double barMediaMs;
  final double inStartMs;
}

/// FiestaDj: mezcla automática con pista base. Tres decks (loop de ritmo +
/// dos canciones). Todas las canciones se llevan al tempo maestro (±8 %),
/// el loop se genera a ese mismo BPM y arranca clavado en el tiempo fuerte de
/// la entrante; la entrante se alinea a la saliente midiendo `time-pos`.
/// No comparte estado, decks ni ecualizador con Automix ni Live DJ.
class FiestaDjNotifier extends Notifier<FiestaState> {
  late final Player _base;
  late final _Deck _da;
  late final _Deck _db;
  bool _useA = true;
  _Deck get _act => _useA ? _da : _db;
  _Deck get _stb => _useA ? _db : _da;

  List<Player> get deckPlayers => [_base, _da.player, _db.player];

  Timer? _tick;
  Timer? _mixTimer;
  Timer? _fadeTimer;
  final Stopwatch _fadeSw = Stopwatch();
  bool _mixing = false;
  bool _scheduled = false;
  bool _preparing = false;
  bool _stopping = false;
  bool _tickBusy = false;
  int _session = 0;
  int _lastOsSecond = -1;
  final Random _rnd = Random();

  List<String> _library = [];
  final Set<String> _played = {};
  final Map<String, double> _bpm = {};
  final Set<String> _exclude = {};
  List<String> _history = [];
  double _master = 100;
  FiestaStyle _autoStyle = FiestaStyle.pulso;
  String? _loadedLoopKey;
  _MixPlan? _plan;

  @override
  FiestaState build() {
    final strategy = MixStrategyFactory.getStrategy();
    _base = Player();
    _da = _Deck(Player());
    _db = _Deck(Player());
    for (final p in deckPlayers) {
      final dynamic pl = p.platform;
      pl?.setProperty('vid', 'no');
    }
    for (final d in [_da, _db]) {
      final dynamic pl = d.player.platform;
      pl?.setProperty('af', strategy.hifiFilter);
      pl?.setProperty('audio-pitch-correction', 'yes');
    }
    final dynamic bpl = _base.platform;
    bpl?.setProperty('af', kHifiLimiter);
    bpl?.setProperty('loop-file', 'inf');

    ref.onDispose(() {
      _tick?.cancel();
      _mixTimer?.cancel();
      _fadeTimer?.cancel();
      for (final p in deckPlayers) {
        p.dispose();
      }
    });
    return _loadSettings();
  }

  // ---------------------------------------------------------------- ajustes
  File _settingsFile() {
    final base = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
    return File('${base.path}${Platform.pathSeparator}_fiestadj_session.json');
  }

  FiestaState _loadSettings() {
    var s = const FiestaState();
    try {
      final f = _settingsFile();
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map) {
          final si = d['style'];
          final bm = d['baseMode'];
          s = s.copyWith(
            styleChoice: (si is int && si >= 0 && si < FiestaStyle.values.length)
                ? FiestaStyle.values[si]
                : null,
            baseMode: (bm is int && bm >= 0 && bm < FiestaBaseMode.values.length)
                ? FiestaBaseMode.values[bm]
                : null,
            baseVolume: (d['baseVolume'] is num)
                ? (d['baseVolume'] as num).toDouble().clamp(0.0, 1.0)
                : null,
            latencyMs: (d['latencyMs'] is num)
                ? (d['latencyMs'] as num).toInt().clamp(-200, 300)
                : null,
            autoRecord: d['autoRecord'] == true,
          );
          final h = d['history'];
          if (h is List) _history = h.map((e) => e.toString()).toList();
        }
      }
    } catch (_) {}
    return s;
  }

  void _saveSettings() {
    try {
      _settingsFile().writeAsStringSync(
        jsonEncode({
          'style': state.styleChoice.index,
          'baseMode': state.baseMode.index,
          'baseVolume': state.baseVolume,
          'latencyMs': state.latencyMs,
          'autoRecord': state.autoRecord,
          'history': _history,
        }),
      );
    } catch (_) {}
  }

  void setStyle(FiestaStyle s) {
    state = state.copyWith(styleChoice: s);
    _saveSettings();
  }

  void setBaseMode(FiestaBaseMode m) {
    state = state.copyWith(baseMode: m);
    _saveSettings();
    if (!_mixing) _applyIdleBaseVolume();
  }

  void setBaseVolume(double v) {
    state = state.copyWith(baseVolume: v.clamp(0.0, 1.0));
    _saveSettings();
    if (!_mixing) _applyIdleBaseVolume();
  }

  void setLatency(int ms) {
    state = state.copyWith(latencyMs: ms.clamp(-200, 300));
    _saveSettings();
  }

  void setAutoRecord(bool v) {
    state = state.copyWith(autoRecord: v);
    _saveSettings();
  }

  void _applyIdleBaseVolume() {
    if (state.baseMode == FiestaBaseMode.always && state.isActive) {
      _base.setVolume(state.baseVolume * 100);
    } else if (!_mixing) {
      _base.setVolume(0);
    }
  }

  // ----------------------------------------------------------------- inicio
  Map<String, int> _ageMap() {
    final m = <String, int>{};
    for (int i = 0; i < _history.length; i++) {
      m[_history[_history.length - 1 - i]] = i;
    }
    return m;
  }

  Future<void> startParty(List<File> files) async {
    if (state.phase == FiestaPhase.preparing) return;
    await stopParty(silent: true);
    final int token = ++_session;
    _library = files.map((f) => f.path).toSet().toList();
    if (_library.length < 2) {
      state = state.copyWith(status: 'Se necesitan al menos 2 canciones.');
      return;
    }
    state = state.copyWith(
      phase: FiestaPhase.preparing,
      status: 'Leyendo ritmos de la lista…',
      played: 0,
    );
    _played.clear();
    _bpm.clear();
    _exclude.clear();
    for (final p in _library) {
      final cached = FiestaBeatAnalyzer.cached(p);
      final b = cached?.bpm ?? FiestaPlanner.hintBpm(p);
      if (b > 0) _bpm[p] = b;
    }
    // Tempo maestro: con al menos ~8 canciones medidas.
    final unknown = _library.where((p) => !_bpm.containsKey(p)).toList()
      ..shuffle(_rnd);
    final int need = min(8, _library.length) - _bpm.length;
    for (int i = 0; i < need && i < unknown.length; i++) {
      if (token != _session) return;
      state = state.copyWith(
        status: 'Analizando ritmo ${i + 1}/${min(need, unknown.length)}…',
      );
      final info = await FiestaBeatAnalyzer.analyze(unknown[i]);
      if (info != null) _bpm[unknown[i]] = info.bpm;
    }
    if (token != _session) return;
    _master = FiestaPlanner.masterTempo(_bpm.values);
    _autoStyle = resolveFiestaStyle(_library, _master);
    final style = state.styleChoice == FiestaStyle.auto
        ? _autoStyle
        : state.styleChoice;
    state = state.copyWith(
      masterBpm: _master,
      style: style,
      status: 'Creando la pista base ${style.label} a ${_master.toStringAsFixed(1)} BPM…',
    );
    await _ensureLoopLoaded(style);
    if (token != _session) return;

    final first = _library[FiestaPlanner.pickNext(
      candidates: _library,
      bpmOf: _bpm,
      currentEff: _master,
      master: _master,
      recentAge: _ageMap(),
      rnd: _rnd,
    )];
    state = state.copyWith(status: 'Preparando la primera canción…');
    await _loadInto(_act, first);
    if (token != _session) return;
    await _act.player.seek(Duration.zero);
    await _act.player.setVolume(100);
    await _act.player.play();
    _played.add(first);
    _remember(first);
    _claimOs();
    state = state.copyWith(
      phase: FiestaPhase.playing,
      currentPath: first,
      currentBpm: _act.bpm,
      currentOnGrid: _act.grid,
      status: 'FIESTA EN MARCHA',
      played: 1,
    );
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _onTick());
    unawaited(_prepareNext());
  }

  Future<void> _ensureLoopLoaded(FiestaStyle style) async {
    final key = '${style.name}|${(_master * 100).round()}';
    if (_loadedLoopKey == key) return;
    final path = await ensureFiestaLoop(style, _master);
    await _base.setVolume(0);
    await _base.open(Media(path), play: false);
    final dynamic pl = _base.platform;
    pl?.setProperty('loop-file', 'inf');
    _loadedLoopKey = key;
  }

  Future<void> _loadInto(_Deck d, String path) async {
    d.clear();
    d.path = path;
    final double hint = _bpm[path] ?? FiestaPlanner.hintBpm(path);
    final info =
        FiestaBeatAnalyzer.cached(path) ??
        await FiestaBeatAnalyzer.analyze(path, hintBpm: hint);
    d.beat = info;
    final double bpm = info?.bpm ?? hint;
    if (bpm > 0) _bpm[path] = bpm;
    d.bpm = bpm;
    final double? rate = bpm > 0 ? FiestaPlanner.rateFor(bpm, _master) : null;
    d.grid = info != null && rate != null && info.confidence >= 1.8;
    d.rate = rate ?? 1.0;
    d.startMs = d.grid ? info!.downbeatMs : 0;
    await d.player.setVolume(0);
    await d.player.open(Media(path), play: false);
    AdaptiveEq.attach(
      d.player,
      path,
      onReady: (s) {
        try {
          (d.player.platform as dynamic)?.setProperty(
            'af',
            '$s,${MixStrategyFactory.getStrategy().hifiFilter}',
          );
        } catch (_) {}
      },
    );
    try {
      await d.player.stream.duration
          .firstWhere((x) => x.inMilliseconds > 0)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    await d.player.setRate(d.rate);
    if (d.startMs > 0) {
      await d.player.seek(Duration(milliseconds: d.startMs.round()));
    }
  }

  /// Elige y precarga la siguiente canción en el deck libre (en pausa, en su
  /// primer tiempo fuerte).
  Future<void> _prepareNext() async {
    if (_preparing || _stopping || !state.isActive) return;
    _preparing = true;
    final int token = _session;
    try {
      var remaining = _library
          .where(
            (p) => !_played.contains(p) && p != _act.path && !_exclude.contains(p),
          )
          .toList();
      if (remaining.isEmpty) {
        // Se escucharon todas: la fiesta sigue con la lista completa.
        _played
          ..clear()
          ..add(_act.path ?? '');
        remaining = _library
            .where((p) => p != _act.path && !_exclude.contains(p))
            .toList();
        if (remaining.isEmpty) remaining = _library.where((p) => p != _act.path).toList();
      }
      if (remaining.isEmpty) return;
      final double curEff = FiestaPlanner.fold(
        _act.bpm > 0 ? _act.bpm : _master,
        _master,
      );
      final int idx = FiestaPlanner.pickNext(
        candidates: remaining,
        bpmOf: _bpm,
        currentEff: curEff,
        master: _master,
        recentAge: _ageMap(),
        rnd: _rnd,
      );
      final String path = remaining[idx];
      _exclude.clear();
      _plan = null;
      await _loadInto(_stb, path);
      if (token != _session || _stopping) return;
      state = state.copyWith(nextPath: path, nextBpm: _stb.bpm);
    } catch (e) {
      debugPrint('🔴 [FIESTA PREP] $e');
    } finally {
      _preparing = false;
    }
  }

  /// Cambia la canción que viene (otra del mismo vecindario de BPM).
  Future<void> reroll() async {
    if (!state.isActive || _mixing || _scheduled || _preparing) return;
    final cur = state.nextPath;
    if (cur != null) _exclude.add(cur);
    state = state.copyWith(clearNext: true);
    await _prepareNext();
  }

  // ---------------------------------------------------------------- plan
  _MixPlan? _computePlan({bool quick = false, double fromMs = 0}) {
    final out = _act;
    final inc = _stb;
    final double durMs = out.player.state.duration.inMilliseconds.toDouble();
    if (inc.path == null || durMs <= 0) return null;
    final bool grid = out.grid && inc.grid && out.beat != null;
    if (!grid) {
      // Sin rejilla fiable: cruce suave normal, sin pista base.
      final double fade = 10000;
      double start = quick ? fromMs + 1500 : durMs * 0.72;
      start = min(start, durMs - fade * out.rate - 500).clamp(0.0, durMs);
      return _MixPlan(
        forPath: inc.path!,
        mixStartMs: start,
        fadeRealMs: fade,
        grid: false,
        barMediaMs: 0,
        inStartMs: inc.startMs,
      );
    }
    final double barMedia = 4 * 60000.0 / out.beat!.bpm;
    final double barReal = barMedia / out.rate;
    int bars = quick ? 2 : max(2, (16000 / barReal).round());
    if (bars > 16) bars = 16;
    double fadeMedia = bars * barMedia;
    while (bars > 1 && fadeMedia + 600 > durMs * 0.5) {
      bars--;
      fadeMedia = bars * barMedia;
    }
    final double d0 = out.beat!.downbeatMs;
    double target = quick ? fromMs + 2500 * out.rate : durMs * 0.72;
    target = min(target, durMs - fadeMedia - 500);
    int k = ((target - d0) / barMedia).floor();
    if (quick) k = ((target - d0) / barMedia).ceil();
    double start = d0 + k * barMedia;
    while (start < 0) {
      start += barMedia;
    }
    return _MixPlan(
      forPath: inc.path!,
      mixStartMs: start,
      fadeRealMs: bars * barReal,
      grid: true,
      barMediaMs: barMedia,
      inStartMs: inc.startMs,
    );
  }

  // ----------------------------------------------------------------- tick
  Future<void> _onTick() async {
    if (_tickBusy || state.phase != FiestaPhase.playing) return;
    _tickBusy = true;
    try {
      final p = _act.player;
      final pos = p.state.position;
      final dur = p.state.duration;
      state = state.copyWith(position: pos, duration: dur);

      final int sec = pos.inSeconds;
      if (sec != _lastOsSecond && _act.path != null) {
        _lastOsSecond = sec;
        globalAudioHandler.syncOs(
          owner: 'fiestadj',
          path: _act.path,
          duration: dur,
          playing: true,
          position: pos,
        );
      }
      if (_mixing || _scheduled) return;
      final durMs = dur.inMilliseconds.toDouble();
      if (durMs <= 0) return;

      if (_stb.path == null || state.nextPath == null) {
        if (!_preparing) unawaited(_prepareNext());
        return;
      }
      if (p.state.completed || pos.inMilliseconds >= durMs - 250) {
        await _hardSwitch();
        return;
      }
      var plan = _plan;
      if (plan == null || plan.forPath != _stb.path) {
        plan = _plan = _computePlan();
      }
      if (plan == null) return;
      final double remainingReal =
          (plan.mixStartMs - pos.inMilliseconds) / _act.rate;
      if (remainingReal <= 3500) {
        await _scheduleMix(plan);
      }
    } catch (e) {
      debugPrint('🔴 [FIESTA TICK] $e');
    } finally {
      _tickBusy = false;
    }
  }

  Future<double> _timePosMs(Player p) async {
    try {
      final s = await (p.platform as dynamic).getProperty('time-pos');
      final v = double.tryParse(s.toString());
      if (v != null) return v * 1000.0;
    } catch (_) {}
    return p.state.position.inMilliseconds.toDouble();
  }

  Future<void> _scheduleMix(_MixPlan plan) async {
    _scheduled = true;
    final out = _act;
    try {
      if (plan.grid && state.baseMode != FiestaBaseMode.off) {
        final style = state.styleChoice == FiestaStyle.auto
            ? _autoStyle
            : state.styleChoice;
        if (style != state.style) state = state.copyWith(style: style);
        await _ensureLoopLoaded(style);
      }
      if (plan.grid) {
        await _base.pause();
        await _base.setVolume(0);
        await _base.seek(Duration.zero);
      }
      final sw = Stopwatch()..start();
      final double q = await _timePosMs(out.player);
      final double queryMs = sw.elapsedMicroseconds / 1000.0;
      // Tiempo que falta, medido en el instante en que se leyó `time-pos`.
      double remaining = (plan.mixStartMs - q) / out.rate;
      if (remaining < -150 && plan.grid) {
        plan.mixStartMs += plan.barMediaMs; // se pasó el tiempo fuerte: el siguiente
        remaining += plan.barMediaMs / out.rate;
      }
      // Descontar lo transcurrido desde esa lectura (la mitad de la consulta
      // más lo que haya tardado después).
      remaining -= sw.elapsedMicroseconds / 1000.0 - queryMs / 2;
      if (remaining < 0) remaining = 0;
      final int fireIn = (remaining - state.latencyMs).round();
      _mixTimer?.cancel();
      _mixTimer = Timer(
        Duration(milliseconds: max(0, fireIn)),
        () => unawaited(_beginMix(plan)),
      );
    } catch (e) {
      debugPrint('🔴 [FIESTA SCHEDULE] $e');
      _scheduled = false;
    }
  }

  Future<void> _beginMix(_MixPlan plan) async {
    if (_stopping || !state.isActive || _mixing) {
      _scheduled = false;
      return;
    }
    if (state.phase == FiestaPhase.paused) {
      _scheduled = false; // se reprograma al reanudar
      return;
    }
    _mixing = true;
    _scheduled = false;
    final out = _act;
    final inc = _stb;
    final bool useBase = plan.grid && state.baseMode != FiestaBaseMode.off;
    try {
      await inc.player.setVolume(0);
      await Future.wait([
        inc.player.play(),
        if (useBase) _base.play(),
      ]);
    } catch (e) {
      debugPrint('🔴 [FIESTA MIX] $e');
    }
    _fadeSw
      ..reset()
      ..start();
    state = state.copyWith(
      mixing: true,
      status: plan.grid ? 'MEZCLANDO · pista base alineada' : 'MEZCLANDO · cruce suave',
    );
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _fadeStep(plan, out, inc, useBase),
    );
    if (plan.grid) {
      Timer(const Duration(milliseconds: 250), () => unawaited(_alignCheck(plan, out, inc, useBase)));
      Timer(const Duration(milliseconds: 1100), () => unawaited(_alignCheck(plan, out, inc, useBase)));
    }
  }

  void _fadeStep(_MixPlan plan, _Deck out, _Deck inc, bool useBase) {
    if (!_mixing) return;
    final double p = (_fadeSw.elapsedMilliseconds / plan.fadeRealMs).clamp(0.0, 1.0);
    out.player.setVolume(cos(p * pi / 2) * 100);
    inc.player.setVolume(sin(p * pi / 2) * 100);
    if (useBase) {
      double g;
      if (p < 0.2) {
        g = p / 0.2;
      } else if (p > 0.8 && state.baseMode == FiestaBaseMode.transitions) {
        g = (1 - p) / 0.2;
      } else {
        g = 1.0;
      }
      _base.setVolume(state.baseVolume * 100 * g.clamp(0.0, 1.0));
    }
    state = state.copyWith(position: out.player.state.position);
    if (p >= 1.0) {
      _fadeTimer?.cancel();
      unawaited(_finishMix(out, inc));
    }
  }

  /// Corrige la fase de la entrante (y del loop) midiendo `time-pos` real de
  /// cada deck mientras la entrante aún casi no se oye.
  Future<void> _alignCheck(_MixPlan plan, _Deck out, _Deck inc, bool useBase) async {
    if (!_mixing || state.phase != FiestaPhase.playing) return;
    try {
      final sw = Stopwatch()..start();
      final double qo = await _timePosMs(out.player);
      final double s0 = sw.elapsedMicroseconds / 1000.0;
      final double qi = await _timePosMs(inc.player);
      final double s1 = sw.elapsedMicroseconds / 1000.0;
      final double tOut = (qo - plan.mixStartMs) / out.rate;
      final double tIn = (qi - plan.inStartMs) / inc.rate;
      // Se lleva todo al mismo instante: la saliente avanzó (s1 - s0) más.
      final double err = tIn - (tOut + (s1 - s0));
      if (err.abs() > 12 && err.abs() < 700) {
        await inc.player.seek(
          Duration(milliseconds: max(0, (qi - err * inc.rate).round())),
        );
      }
      if (useBase) {
        final double qb = await _timePosMs(_base);
        final double s2 = sw.elapsedMicroseconds / 1000.0;
        final double eb = qb - (tOut + (s2 - s0));
        if (eb.abs() > 12 && eb.abs() < 700) {
          await _base.seek(Duration(milliseconds: max(0, (qb - eb).round())));
        }
      }
    } catch (e) {
      debugPrint('🔴 [FIESTA ALIGN] $e');
    }
  }

  Future<void> _finishMix(_Deck out, _Deck inc) async {
    try {
      await out.player.pause();
      await out.player.setVolume(0);
      await inc.player.setVolume(100);
      if (state.baseMode == FiestaBaseMode.always) {
        await _base.setVolume(state.baseVolume * 100);
      } else {
        await _base.pause();
        await _base.setVolume(0);
      }
    } catch (_) {}
    _useA = !_useA;
    out.clear();
    _mixing = false;
    _plan = null;
    final String? path = _act.path;
    if (path != null) {
      _played.add(path);
      _remember(path);
    }
    state = state.copyWith(
      mixing: false,
      currentPath: path,
      currentBpm: _act.bpm,
      currentOnGrid: _act.grid,
      clearNext: true,
      status: 'FIESTA EN MARCHA',
      played: state.played + 1,
    );
    unawaited(_prepareNext());
  }

  /// La canción terminó sin cruce (no había siguiente lista a tiempo).
  Future<void> _hardSwitch() async {
    if (_mixing || _stb.path == null) return;
    _mixing = true;
    final out = _act;
    final inc = _stb;
    try {
      await inc.player.setVolume(100);
      await inc.player.play();
    } catch (_) {}
    await _finishMix(out, inc);
  }

  // ------------------------------------------------------------- controles
  Future<void> skipNext() async {
    if (!state.isPlaying || _mixing || _stb.path == null) return;
    _mixTimer?.cancel();
    _scheduled = false;
    final pos = _act.player.state.position.inMilliseconds.toDouble();
    final plan = _computePlan(quick: true, fromMs: pos);
    if (plan == null) return;
    _plan = plan;
    await _scheduleMix(plan);
  }

  Future<void> restartCurrent() async {
    if (!state.isActive || _mixing) return;
    await _act.player.seek(Duration.zero);
  }

  Future<void> togglePause() async {
    if (state.phase == FiestaPhase.playing) {
      await _pauseAll();
      state = state.copyWith(phase: FiestaPhase.paused, status: 'EN PAUSA');
    } else if (state.phase == FiestaPhase.paused) {
      await _resumeAll();
      state = state.copyWith(phase: FiestaPhase.playing, status: 'FIESTA EN MARCHA');
      _claimOs();
    }
  }

  Future<void> _pauseAll() async {
    _mixTimer?.cancel();
    _scheduled = false;
    _fadeSw.stop();
    try {
      await _act.player.pause();
      if (_mixing) {
        await _stb.player.pause();
        await _base.pause();
      }
    } catch (_) {}
  }

  Future<void> _resumeAll() async {
    try {
      await _act.player.play();
      if (_mixing) {
        await _stb.player.play();
        if (state.baseMode != FiestaBaseMode.off && _plan?.grid == true) {
          await _base.play();
        }
        _fadeSw.start();
      }
    } catch (_) {}
  }

  bool _pausedByInterruption = false;

  Future<bool> pauseForInterruption() async {
    if (!state.isPlaying) return false;
    _pausedByInterruption = true;
    await _pauseAll();
    state = state.copyWith(phase: FiestaPhase.paused, status: 'EN PAUSA');
    return true;
  }

  Future<void> resumeAfterInterruption() async {
    if (!_pausedByInterruption) return;
    _pausedByInterruption = false;
    if (state.phase != FiestaPhase.paused) return;
    await _resumeAll();
    state = state.copyWith(phase: FiestaPhase.playing, status: 'FIESTA EN MARCHA');
  }

  Future<void> stopParty({bool silent = false}) async {
    _stopping = true;
    _session++;
    _tick?.cancel();
    _mixTimer?.cancel();
    _fadeTimer?.cancel();
    _fadeSw
      ..stop()
      ..reset();
    for (final p in deckPlayers) {
      try {
        await p.pause();
        await p.stop();
        await p.setVolume(0);
      } catch (_) {}
    }
    _loadedLoopKey = null; // el stop vació el deck de la pista base
    _da.clear();
    _db.clear();
    _useA = true;
    _mixing = false;
    _scheduled = false;
    _preparing = false;
    _plan = null;
    _pausedByInterruption = false;
    _stopping = false;
    if (!silent) {
      globalAudioHandler.updateOsPlaybackState(false, Duration.zero);
    }
    state = state.copyWith(
      phase: FiestaPhase.idle,
      clearCurrent: true,
      clearNext: true,
      mixing: false,
      position: Duration.zero,
      duration: Duration.zero,
      status: silent ? state.status : 'Fiesta detenida',
    );
  }

  /// La app se cierra desde el sistema: se silencia todo.
  Future<void> parkAll() async {
    if (!state.isActive && state.phase != FiestaPhase.preparing) return;
    await stopParty(silent: true);
  }

  void _remember(String path) {
    _history.remove(path);
    _history.add(path);
    if (_history.length > 80) {
      _history = _history.sublist(_history.length - 80);
    }
    _saveSettings();
  }

  void _claimOs() {
    globalAudioHandler.claim(
      'fiestadj',
      onPlayPause: () => unawaited(togglePause()),
      onPause: () async {
        if (state.isPlaying) await togglePause();
      },
      onNext: () => unawaited(skipNext()),
      onPrevious: () => unawaited(restartCurrent()),
      onSeek: (_) {},
      isPlaying: () => state.isPlaying,
    );
  }
}

final fiestaDjProvider = NotifierProvider<FiestaDjNotifier, FiestaState>(
  FiestaDjNotifier.new,
);
