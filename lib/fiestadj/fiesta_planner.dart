import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Lógica pura de FiestaDj: BPM por canción, tempo maestro, ajuste de
/// velocidad y elección de la siguiente canción (shuffle cercano al BPM).
class FiestaPlanner {
  FiestaPlanner._();

  /// Los ajustes de tempo se limitan a ±8 % para no deformar la música.
  static const double maxStretch = 0.08;

  static final RegExp _nameBpm = RegExp(
    r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
    caseSensitive: false,
  );

  static final Map<String, Map<String, double>> _dirCache = {};

  /// BPM conocido sin analizar audio: nombre del archivo o caché `_dj_metadata.json`
  /// que genera el DSP (en la carpeta de la canción o en sus carpetas padre).
  static double hintBpm(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final m = _nameBpm.firstMatch(name);
    if (m != null) return double.parse(m.group(1)!);
    Directory dir = File(path).parent;
    for (int depth = 0; depth < 5; depth++) {
      final map = _metadata(dir.path);
      final v = map[path] ?? map[path.replaceAll('/', '\\')];
      if (v != null && v >= 60 && v <= 200) return v;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return 0.0;
  }

  static Map<String, double> _metadata(String dirPath) {
    final cached = _dirCache[dirPath];
    if (cached != null) return cached;
    final out = <String, double>{};
    try {
      final f = File('$dirPath${Platform.pathSeparator}_dj_metadata.json');
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map) {
          d.forEach((k, v) {
            if (v is num) {
              out[k.toString()] = v.toDouble();
            } else if (v is Map && v['bpm'] is num) {
              out[k.toString()] = (v['bpm'] as num).toDouble();
            }
          });
        }
      }
    } catch (_) {}
    _dirCache[dirPath] = out;
    return out;
  }

  /// Versión del BPM (mitad, tal cual o doble) más cercana al tempo maestro.
  static double fold(double bpm, double master) {
    if (bpm <= 0 || master <= 0) return bpm;
    double best = bpm;
    double bestErr = (log(bpm / master)).abs();
    for (final c in [bpm / 2, bpm * 2]) {
      final e = (log(c / master)).abs();
      if (e < bestErr) {
        bestErr = e;
        best = c;
      }
    }
    return best;
  }

  /// Velocidad de reproducción para que [bpm] suene al tempo [master].
  /// Devuelve null si exigiría deformar más del límite.
  static double? rateFor(double bpm, double master) {
    if (bpm <= 0 || master <= 0) return null;
    final eff = fold(bpm, master);
    final r = master / eff;
    if ((r - 1).abs() > maxStretch) return null;
    return r;
  }

  /// Tempo maestro: mediana de los BPM conocidos plegados a 80–160.
  static double masterTempo(Iterable<double> bpms) {
    final list = <double>[];
    for (var b in bpms) {
      if (b <= 0) continue;
      while (b < 80) {
        b *= 2;
      }
      while (b >= 160) {
        b /= 2;
      }
      list.add(b);
    }
    if (list.isEmpty) return 100.0;
    list.sort();
    final m = list.length ~/ 2;
    return list.length.isOdd ? list[m] : (list[m - 1] + list[m]) / 2;
  }

  /// Elige la siguiente canción: shuffle ponderado. Favorece BPM cercano a la
  /// actual y al maestro, castiga lo escuchado hace poco (memoria entre
  /// fiestas) y deja siempre una probabilidad real a cualquier pista.
  static int pickNext({
    required List<String> candidates,
    required Map<String, double> bpmOf,
    required double currentEff,
    required double master,
    required Map<String, int> recentAge,
    required Random rnd,
  }) {
    if (candidates.isEmpty) return -1;
    final weights = List<double>.filled(candidates.length, 0);
    double total = 0;
    for (int i = 0; i < candidates.length; i++) {
      final p = candidates[i];
      final bpm = bpmOf[p] ?? 0;
      double w;
      if (bpm <= 0) {
        w = 0.05; // BPM desconocido: exploración con poca probabilidad
      } else {
        final eff = fold(bpm, master);
        final dev = (eff - currentEff).abs() / max(1.0, currentEff) * 100;
        w = exp(-pow(dev / 4.0, 2).toDouble());
        final fitDev = (eff - master).abs() / master;
        if (fitDev > maxStretch) w *= 0.12;
      }
      final age = recentAge[p];
      if (age != null) {
        // age 0 = la más reciente: 0.25 ... la más antigua: casi 1.
        w *= 0.25 + 0.75 * (age / 80.0).clamp(0.0, 1.0);
      }
      w *= 0.6 + 0.8 * rnd.nextDouble();
      w += 0.002;
      weights[i] = w;
      total += w;
    }
    double r = rnd.nextDouble() * total;
    for (int i = 0; i < weights.length; i++) {
      r -= weights[i];
      if (r <= 0) return i;
    }
    return weights.length - 1;
  }
}
