import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/hal/platform_strategy.dart';

/// Rejilla rítmica de una canción: tempo refinado y primer tiempo fuerte
/// (inicio de compás), medidos sobre el audio real.
class FiestaBeatInfo {
  final double bpm;
  final double downbeatMs;
  final double confidence;
  const FiestaBeatInfo(this.bpm, this.downbeatMs, this.confidence);

  Map<String, dynamic> toJson() => {
    'bpm': bpm,
    'down': downbeatMs,
    'conf': confidence,
  };

  static FiestaBeatInfo? fromJson(dynamic j) {
    if (j is! Map) return null;
    final b = j['bpm'];
    final d = j['down'];
    final c = j['conf'];
    if (b is! num || d is! num) return null;
    return FiestaBeatInfo(b.toDouble(), d.toDouble(), (c is num) ? c.toDouble() : 0);
  }
}

const int _aSr = 11025;

/// Analiza el pulso de una canción: decodifica ~60 s a 11 kHz mono y busca el
/// tempo y la fase que mejor encajan con los golpes (peine de pulsos), y el
/// tiempo fuerte por la energía de graves. Todo en un isolate.
class FiestaBeatAnalyzer {
  FiestaBeatAnalyzer._();

  static Map<String, dynamic>? _disk;
  static final Map<String, FiestaBeatInfo?> _mem = {};

  static File _cacheFile() {
    final base = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
    return File('${base.path}${Platform.pathSeparator}_fiesta_beats.json');
  }

  static String _key(String path) {
    try {
      final f = File(path);
      return '$path|${f.lengthSync()}|${f.lastModifiedSync().millisecondsSinceEpoch}';
    } catch (_) {
      return path;
    }
  }

  static void _loadDisk() {
    if (_disk != null) return;
    try {
      final f = _cacheFile();
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map<String, dynamic>) {
          _disk = d;
          return;
        }
      }
    } catch (_) {}
    _disk = <String, dynamic>{};
  }

  static void _saveDisk() {
    try {
      _cacheFile().writeAsStringSync(jsonEncode(_disk));
    } catch (_) {}
  }

  /// Resultado en caché (sin analizar) o null.
  static FiestaBeatInfo? cached(String path) {
    final k = _key(path);
    if (_mem.containsKey(k)) return _mem[k];
    _loadDisk();
    final info = FiestaBeatInfo.fromJson(_disk![k]);
    if (info != null) _mem[k] = info;
    return info;
  }

  /// Analiza la canción. [hintBpm] (etiqueta ID3, nombre o caché del DSP)
  /// acota la búsqueda a ±1.5 % y la hace mucho más fiable.
  static Future<FiestaBeatInfo?> analyze(
    String path, {
    double hintBpm = 0,
  }) async {
    final hit = cached(path);
    if (hit != null) return hit;
    final k = _key(path);
    String? wav;
    try {
      wav = await _decodeToWav(path);
      if (wav == null) return null;
      final Uint8List bytes = await File(wav).readAsBytes();
      final double hint = hintBpm;
      final FiestaBeatInfo? info = await Isolate.run(
        () => _analyzeWav(bytes, hint),
      );
      _mem[k] = info;
      if (info != null) {
        _loadDisk();
        _disk![k] = info.toJson();
        _saveDisk();
      }
      return info;
    } catch (e) {
      debugPrint('🔴 [FIESTA BEAT] $path: $e');
      return null;
    } finally {
      if (wav != null) {
        try {
          File(wav).deleteSync();
        } catch (_) {}
      }
    }
  }

  static String _ffmpeg() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final local = Platform.isWindows ? '$exeDir\\ffmpeg.exe' : '$exeDir/ffmpeg';
    return File(local).existsSync() ? local : 'ffmpeg';
  }

  static int _tmpCounter = 0;

  static Future<String?> _decodeToWav(String path) async {
    final tmp =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'fiesta_${pid}_${_tmpCounter++}.wav';
    // 1) Escritorio: FFmpeg (rápido y exacto).
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final r = await Process.run(_ffmpeg(), [
          '-v', 'error', '-t', '60', '-i', path,
          '-ac', '1', '-ar', '$_aSr', '-c:a', 'pcm_s16le', '-f', 'wav', '-y',
          tmp,
        ]).timeout(const Duration(seconds: 45));
        if (r.exitCode == 0 && File(tmp).existsSync() && File(tmp).lengthSync() > 1000) {
          return tmp;
        }
      } catch (_) {}
    }
    // 2) Celular (o sin FFmpeg): libmpv vuelca el PCM con su salida "pcm".
    Player? p;
    try {
      p = Player();
      final dynamic pl = p.platform;
      await pl?.setProperty('vid', 'no');
      await pl?.setProperty('ao', 'pcm');
      await pl?.setProperty('ao-pcm-file', tmp);
      await pl?.setProperty('ao-pcm-waveheader', 'yes');
      await pl?.setProperty('audio-samplerate', '$_aSr');
      await pl?.setProperty('audio-channels', 'mono');
      await pl?.setProperty('audio-format', 's16');
      await pl?.setProperty('length', '60');
      await pl?.setProperty('untimed', 'yes');
      await pl?.setProperty('af', '');
      await p.open(Media(path), play: true);
      await p.stream.completed
          .firstWhere((c) => c)
          .timeout(const Duration(seconds: 60));
    } catch (_) {
    } finally {
      try {
        await p?.dispose();
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 150));
    if (File(tmp).existsSync() && File(tmp).lengthSync() > 1000) return tmp;
    return null;
  }
}

// --------------------------------------------------------------------------
// Análisis (corre en un isolate)
// --------------------------------------------------------------------------
Float64List? _readWavMono(Uint8List b) {
  if (b.length < 44) return null;
  final bd = ByteData.sublistView(b);
  int ch = 1;
  int bits = 16;
  int pos = 12;
  int dataOff = -1;
  int dataLen = 0;
  while (pos + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(pos, pos + 4));
    final size = bd.getUint32(pos + 4, Endian.little);
    if (id == 'fmt ') {
      ch = bd.getUint16(pos + 10, Endian.little);
      bits = bd.getUint16(pos + 22, Endian.little);
    } else if (id == 'data') {
      dataOff = pos + 8;
      dataLen = min(size, b.length - dataOff);
      if (size == 0 || size == 0xFFFFFFFF) dataLen = b.length - dataOff;
      break;
    }
    pos += 8 + size + (size & 1);
  }
  if (dataOff < 0 || bits != 16 || ch < 1) return null;
  final frames = dataLen ~/ (2 * ch);
  final out = Float64List(frames);
  for (int i = 0; i < frames; i++) {
    double s = 0;
    for (int c = 0; c < ch; c++) {
      s += bd.getInt16(dataOff + (i * ch + c) * 2, Endian.little);
    }
    out[i] = s / ch / 32768.0;
  }
  return out;
}

FiestaBeatInfo? _analyzeWav(Uint8List bytes, double hint) {
  final x = _readWavMono(bytes);
  if (x == null || x.length < _aSr * 12) return null;

  const int hop = 110; // ~10 ms
  final double hopMs = hop * 1000.0 / _aSr;
  final int frames = x.length ~/ hop - 2;
  if (frames < 600) return null;

  // Energía por frame de la señal con preénfasis (golpes) y de graves (bombo).
  final fullE = Float64List(frames);
  final lowE = Float64List(frames);
  double prev = 0;
  double lp = 0;
  final pre = Float64List(x.length);
  final low = Float64List(x.length);
  for (int i = 0; i < x.length; i++) {
    pre[i] = x[i] - 0.95 * prev;
    prev = x[i];
    lp += 0.0767 * (x[i] - lp);
    low[i] = lp;
  }
  for (int t = 0; t < frames; t++) {
    double sf = 0;
    double sl = 0;
    for (int i = t * hop; i < t * hop + 2 * hop; i++) {
      sf += pre[i] * pre[i];
      sl += low[i] * low[i];
    }
    fullE[t] = log(1 + 100 * sqrt(sf / (2 * hop)));
    lowE[t] = log(1 + 100 * sqrt(sl / (2 * hop)));
  }
  Float64List flux(Float64List e) {
    final f = Float64List(frames);
    for (int t = 1; t < frames; t++) {
      final d = e[t] - e[t - 1];
      f[t] = d > 0 ? d : 0;
    }
    // Suavizado mínimo para tolerar ±1 frame de jitter.
    final s = Float64List(frames);
    for (int t = 1; t < frames - 1; t++) {
      s[t] = f[t] + 0.5 * (f[t - 1] + f[t + 1]);
    }
    return s;
  }

  final fx = flux(fullE);
  final lx = flux(lowE);

  double combScore(Float64List f, double period, double phase) {
    double sum = 0;
    int n = 0;
    for (double t = phase; t < frames - 2; t += period) {
      sum += f[t.round()];
      n++;
    }
    return n == 0 ? 0 : sum / n;
  }

  double bestBpm = 0;
  double bestPhase = 0;
  double bestScore = -1;
  double bpmLo;
  double bpmHi;
  double step;
  if (hint >= 60 && hint <= 200) {
    bpmLo = hint * 0.985;
    bpmHi = hint * 1.015;
    step = 0.05;
  } else {
    bpmLo = 75;
    bpmHi = 170;
    step = 0.25;
  }
  for (double bpm = bpmLo; bpm <= bpmHi; bpm += step) {
    final double period = 60000.0 / bpm / hopMs;
    for (int ph = 0; ph < period.ceil(); ph++) {
      final s = combScore(fx, period, ph.toDouble());
      if (s > bestScore) {
        bestScore = s;
        bestBpm = bpm;
        bestPhase = ph.toDouble();
      }
    }
  }
  if (bestBpm <= 0) return null;

  final double period = 60000.0 / bestBpm / hopMs;
  // Confianza: cuánto destaca la mejor fase frente al promedio de las fases.
  double avg = 0;
  final int phases = period.ceil();
  for (int ph = 0; ph < phases; ph++) {
    avg += combScore(fx, period, ph.toDouble());
  }
  avg /= phases;
  final double conf = avg <= 0 ? 0 : (bestScore / avg).clamp(0.0, 10.0);

  // Tiempo fuerte: de los 4 tiempos del compás, el de más graves.
  final sums = List<double>.filled(4, 0);
  int k = 0;
  for (double t = bestPhase; t < frames - 2; t += period) {
    sums[k % 4] += lx[t.round()];
    k++;
  }
  int bestR = 0;
  for (int r = 1; r < 4; r++) {
    if (sums[r] > sums[bestR]) bestR = r;
  }

  // El golpe aparece ~1.5 frames después del inicio del salto de energía.
  double downMs = (bestPhase + 1.5 + bestR * period) * hopMs;
  final double barMs = 4 * 60000.0 / bestBpm;
  while (downMs >= barMs) {
    downMs -= barMs;
  }
  return FiestaBeatInfo(bestBpm, downMs, conf);
}
