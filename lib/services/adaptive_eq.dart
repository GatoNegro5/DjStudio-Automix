import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../core/hal/platform_strategy.dart';

/// EQ adaptativa por canción: mide el espectro real de cada tema (10 bandas
/// octava, ~30 s de audio) y calcula una corrección suave hacia una curva
/// objetivo de música comercial. Nunca pasa de ±3 dB, no realza lo que el
/// archivo no tiene (cortes de mp3 en agudos) y reserva headroom propio.
/// Es compartida por Automix, Live DJ y FiestaDJ; cada módulo la aplica solo
/// a sus propios decks.
class AdaptiveEq {
  AdaptiveEq._();

  /// Interruptor global (por defecto activo).
  static bool enabled = true;

  static const List<int> _bands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  static const int _sr = 44100;

  static final Expando<String> _snippet = Expando<String>('adaptiveSnippet');
  static final Expando<String> _token = Expando<String>('adaptiveToken');

  static Map<String, dynamic>? _disk;
  static final Map<String, List<double>?> _mem = {};
  static final Map<String, Future<List<double>?>> _pending = {};

  /// Trozo de cadena `af` (volumen + equalizer) de la canción que sostiene el
  /// [player], o '' si no hay perfil (aún no medido, desactivado o sin FFmpeg).
  static String snippetFor(Player player) =>
      enabled ? (_snippet[player] ?? '') : '';

  /// Limpia el perfil del [player] y mide [path]. Al terminar llama a
  /// [onReady] con el trozo de filtro (solo si el deck sigue con esa canción).
  static void attach(
    Player player,
    String path, {
    required void Function(String snippet) onReady,
  }) {
    _snippet[player] = '';
    _token[player] = path;
    if (!enabled) return;
    () async {
      final gains = await profile(path);
      if (gains == null) return;
      if (_token[player] != path) return; // el deck ya cambió de canción
      final s = _build(gains);
      _snippet[player] = s;
      if (s.isNotEmpty) onReady(s);
    }();
  }

  static String _build(List<double> g) {
    double maxBoost = 0;
    for (final v in g) {
      if (v > maxBoost) maxBoost = v;
    }
    final parts = <String>[];
    if (maxBoost > 0.05) {
      parts.add('volume=volume=${(-maxBoost).toStringAsFixed(1)}dB');
    }
    for (int i = 0; i < _bands.length; i++) {
      if (g[i].abs() >= 0.2) {
        parts.add(
          'equalizer=f=${_bands[i]}:width_type=o:w=1:g=${g[i].toStringAsFixed(1)}',
        );
      }
    }
    return parts.join(',');
  }

  // ------------------------------------------------------------------ caché
  static File _cacheFile() {
    final base = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
    return File('${base.path}${Platform.pathSeparator}_adaptive_eq.json');
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

  /// Ganancias (10 bandas) de la canción, desde caché o midiéndola.
  static Future<List<double>?> profile(String path) {
    final k = _key(path);
    if (_mem.containsKey(k)) return Future.value(_mem[k]);
    _loadDisk();
    final c = _disk![k];
    if (c is List && c.length == 10) {
      final g = c.map((e) => (e as num).toDouble()).toList();
      _mem[k] = g;
      return Future.value(g);
    }
    return _pending[k] ??= _measure(path, k).whenComplete(() => _pending.remove(k));
  }

  static Future<List<double>?> _measure(String path, String k) async {
    String? raw;
    try {
      raw = await _decode(path);
      if (raw == null) return null;
      final Uint8List bytes = await File(raw).readAsBytes();
      final List<double>? g = await Isolate.run(() => _analyze(bytes));
      _mem[k] = g;
      if (g != null) {
        _loadDisk();
        _disk![k] = g;
        _saveDisk();
      }
      return g;
    } catch (e) {
      debugPrint('🔴 [ADAPTIVE EQ] $path: $e');
      return null;
    } finally {
      if (raw != null) {
        try {
          File(raw).deleteSync();
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------- decode
  static String _ffmpeg() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final local = Platform.isWindows ? '$exeDir\\ffmpeg.exe' : '$exeDir/ffmpeg';
    return File(local).existsSync() ? local : 'ffmpeg';
  }

  static int _n = 0;

  static Future<String?> _decode(String path) async {
    final tmp =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'aeq_${pid}_${_n++}.pcm';
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      for (final seek in const ['30', '0']) {
        try {
          final r = await Process.run(_ffmpeg(), [
            '-v', 'error', '-ss', seek, '-t', '30', '-i', path,
            '-ac', '1', '-ar', '$_sr', '-f', 's16le', '-y', tmp,
          ]).timeout(const Duration(seconds: 40));
          if (r.exitCode == 0 &&
              File(tmp).existsSync() &&
              File(tmp).lengthSync() > _sr * 2 * 5) {
            return tmp;
          }
        } catch (_) {}
      }
      return null;
    }
    // Celular: libmpv vuelca el PCM (mejor esfuerzo).
    Player? p;
    try {
      p = Player();
      final dynamic pl = p.platform;
      await pl?.setProperty('vid', 'no');
      await pl?.setProperty('ao', 'pcm');
      await pl?.setProperty('ao-pcm-file', tmp);
      await pl?.setProperty('ao-pcm-waveheader', 'no');
      await pl?.setProperty('audio-samplerate', '$_sr');
      await pl?.setProperty('audio-channels', 'mono');
      await pl?.setProperty('audio-format', 's16');
      await pl?.setProperty('start', '30');
      await pl?.setProperty('length', '30');
      await pl?.setProperty('untimed', 'yes');
      await pl?.setProperty('af', '');
      await p.open(Media(path), play: true);
      await p.stream.completed
          .firstWhere((c) => c)
          .timeout(const Duration(seconds: 45));
    } catch (_) {
    } finally {
      try {
        await p?.dispose();
      } catch (_) {}
    }
    await Future.delayed(const Duration(milliseconds: 150));
    if (File(tmp).existsSync() && File(tmp).lengthSync() > _sr * 2 * 5) {
      return tmp;
    }
    return null;
  }

  // -------------------------------------------------------------- análisis
  // Nivel típico de música comercial por banda octava (dB, relativo a 1 kHz).
  static const List<double> _target = [
    -1, 4, 6, 3, 1, 0, -3, -6, -11, -18,
  ];

  static List<double>? _analyze(Uint8List b) {
    final n = b.length ~/ 2;
    const int fft = 4096;
    if (n < fft * 8) return null;
    final bd = ByteData.sublistView(b);
    final win = List<double>.generate(
      fft,
      (i) => 0.5 - 0.5 * cos(2 * pi * i / (fft - 1)),
    );
    final acc = Float64List(fft ~/ 2);
    int frames = 0;
    final re = Float64List(fft);
    final im = Float64List(fft);
    for (int s = 0; s + fft <= n; s += 22050) {
      for (int i = 0; i < fft; i++) {
        re[i] = bd.getInt16((s + i) * 2, Endian.little) / 32768.0 * win[i];
        im[i] = 0;
      }
      _fft(re, im);
      for (int i = 1; i < fft ~/ 2; i++) {
        acc[i] += re[i] * re[i] + im[i] * im[i];
      }
      frames++;
    }
    if (frames == 0) return null;
    final binHz = _sr / fft;
    final lv = List<double>.filled(10, -120);
    double total = 0;
    for (int bI = 0; bI < 10; bI++) {
      final int lo = (_bands[bI] / sqrt2 / binHz).floor().clamp(1, fft ~/ 2 - 1).toInt();
      final int hi = (_bands[bI] * sqrt2 / binHz).ceil().clamp(lo + 1, fft ~/ 2).toInt();
      double e = 0;
      for (int i = lo; i < hi; i++) {
        e += acc[i];
      }
      e /= frames;
      total += e;
      lv[bI] = 10 * log(e + 1e-12) / ln10;
    }
    if (total < 1e-6) return List<double>.filled(10, 0); // casi silencio

    // Desviación frente al objetivo, anclada en la zona media (125 Hz–4 kHz).
    double m = 0;
    for (int i = 2; i <= 7; i++) {
      m += lv[i] - _target[i];
    }
    m /= 6;
    final out = List<double>.filled(10, 0);
    for (int i = 0; i < 10; i++) {
      final d = lv[i] - _target[i] - m;
      double c = -0.5 * d;
      // Banda prácticamente vacía (corte del archivo): no se realza.
      if ((i >= 8 || i == 0) && d < -12) c = 0;
      double hiLim = 3.0;
      if (i == 0) hiLim = 1.0;
      if (i == 8) hiLim = 2.0;
      if (i == 9) hiLim = 0.0;
      c = c.clamp(-3.0, hiLim).toDouble();
      out[i] = (c * 10).round() / 10;
    }
    return out;
  }

  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2 * pi / len;
      final wr = cos(ang);
      final wi = sin(ang);
      for (int i = 0; i < n; i += len) {
        double cr = 1, ci = 0;
        for (int k = 0; k < len ~/ 2; k++) {
          final ur = re[i + k];
          final ui = im[i + k];
          final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
          final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
          re[i + k] = ur + vr;
          im[i + k] = ui + vi;
          re[i + k + len ~/ 2] = ur - vr;
          im[i + k + len ~/ 2] = ui - vi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
  }
}
