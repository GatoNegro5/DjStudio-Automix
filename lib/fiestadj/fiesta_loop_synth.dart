import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../core/hal/platform_strategy.dart';

/// Estilos de la pista base de FiestaDj. Cada uno es un patrón rítmico
/// sintetizado desde cero (sin samples ni licencias) y generado EXACTAMENTE
/// al BPM maestro de la fiesta, así nunca hay que estirar el audio.
enum FiestaStyle { auto, pulso, dembow, cumbia, vallenato, salsa, merengue }

extension FiestaStyleInfo on FiestaStyle {
  String get label {
    switch (this) {
      case FiestaStyle.auto:
        return 'AUTO';
      case FiestaStyle.pulso:
        return 'PULSO CLUB';
      case FiestaStyle.dembow:
        return 'DEMBOW';
      case FiestaStyle.cumbia:
        return 'CUMBIA';
      case FiestaStyle.vallenato:
        return 'VALLENATO';
      case FiestaStyle.salsa:
        return 'SALSA';
      case FiestaStyle.merengue:
        return 'MERENGUE';
    }
  }

  /// Palabras de la ruta/nombre que delatan el estilo de la lista.
  List<String> get keywords {
    switch (this) {
      case FiestaStyle.pulso:
        return const ['house', 'electro', 'edm', 'remix', 'techno', 'dance'];
      case FiestaStyle.dembow:
        return const ['reggaeton', 'regueton', 'dembow', 'urbano', 'trap'];
      case FiestaStyle.cumbia:
        return const ['cumbia', 'chicha', 'sonidera'];
      case FiestaStyle.vallenato:
        return const ['vallenato', 'vallena', 'acordeon', 'acordeón', 'diomedes'];
      case FiestaStyle.salsa:
        return const ['salsa', 'timba', 'son cubano', 'guaguanco'];
      case FiestaStyle.merengue:
        return const ['merengue', 'bachata', 'tipico', 'típico'];
      case FiestaStyle.auto:
        return const [];
    }
  }
}

/// Elige el estilo de la fiesta: primero por palabras en las rutas de la
/// lista; si no hay pistas, por el BPM maestro.
FiestaStyle resolveFiestaStyle(List<String> paths, double masterBpm) {
  final votes = <FiestaStyle, int>{};
  for (final p in paths) {
    final low = p.toLowerCase();
    for (final s in FiestaStyle.values) {
      if (s.keywords.any(low.contains)) {
        votes[s] = (votes[s] ?? 0) + 1;
      }
    }
  }
  if (votes.isNotEmpty) {
    FiestaStyle best = votes.keys.first;
    votes.forEach((k, v) {
      if (v > votes[best]!) best = k;
    });
    return best;
  }
  if (masterBpm < 100) return FiestaStyle.cumbia;
  if (masterBpm < 118) return FiestaStyle.dembow;
  if (masterBpm < 135) return FiestaStyle.pulso;
  return FiestaStyle.merengue;
}

const int _sr = 44100;
const int _bars = 4;

/// Duración exacta del loop en milisegundos (4 compases a [bpm]).
double fiestaLoopMs(double bpm) => _bars * 4 * 60000.0 / bpm;

/// Devuelve la ruta del loop WAV del estilo/BPM (lo genera si no existe).
Future<String> ensureFiestaLoop(FiestaStyle style, double bpm) async {
  final base = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
  final dir = Directory(
    '${base.path}${Platform.pathSeparator}_fiesta_loops',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File(
    '${dir.path}${Platform.pathSeparator}'
    'loop_${style.name}_${(bpm * 100).round()}.wav',
  );
  if (file.existsSync() && file.lengthSync() > 44) return file.path;
  final int styleIndex = style.index;
  final double b = bpm;
  final Uint8List bytes = await Isolate.run(
    () => _renderLoopWav(styleIndex, b),
  );
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

// --------------------------------------------------------------------------
// Patrones (rejilla de 16 pasos por compás 4/4).
// --------------------------------------------------------------------------
const Map<FiestaStyle, Map<String, List<int>>> _patterns = {
  // Club: bombo en los 4 tiempos, palmas en 2 y 4, hi-hat abierto a contratiempo.
  FiestaStyle.pulso: {
    'kick': [0, 4, 8, 12],
    'clap': [4, 12],
    'hatO': [2, 6, 10, 14],
    'hatC': [1, 3, 5, 7, 9, 11, 13, 15],
  },
  // Reggaeton: dembow 3+3+2 con bombo en los 4 tiempos.
  FiestaStyle.dembow: {
    'kick': [0, 4, 8, 12],
    'snare': [3, 6, 11, 14],
    'hatC': [0, 2, 4, 6, 8, 10, 12, 14],
  },
  // Cumbia colombiana: guacharaca continua, tambor alegre y llamador.
  FiestaStyle.cumbia: {
    'kick': [0, 8],
    'congaLo': [4, 12],
    'congaHi': [6, 10, 14],
    'guira': [0, 2, 4, 6, 8, 10, 12, 14],
    'clave': [3, 11],
  },
  // Vallenato (aire de puya): caja sincopada y guacharaca en semicorcheas.
  FiestaStyle.vallenato: {
    'caja': [0, 4, 6, 8, 12, 14],
    'guira': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    'kick': [0, 8],
  },
  // Salsa: clave son 3-2, cencerro en negras, tumbao de conga.
  FiestaStyle.salsa: {
    'clave': [0, 3, 6, 10, 12],
    'cowbell': [0, 4, 8, 12],
    'congaLo': [8],
    'congaHi': [2, 12, 14],
    'kick': [0, 8],
  },
  // Merengue: tambora a dos tiempos y güira acelerada.
  FiestaStyle.merengue: {
    'tamboraLo': [0, 8],
    'tamboraHi': [3, 4, 6, 11, 12, 14],
    'guira': [0, 2, 4, 6, 8, 10, 12, 14],
    'kick': [0, 8],
  },
};

const Map<String, double> _gain = {
  'kick': 0.95,
  'clap': 0.55,
  'snare': 0.6,
  'caja': 0.55,
  'hatC': 0.28,
  'hatO': 0.3,
  'guira': 0.3,
  'congaLo': 0.6,
  'congaHi': 0.5,
  'clave': 0.5,
  'cowbell': 0.4,
  'tamboraLo': 0.8,
  'tamboraHi': 0.55,
};

const Map<String, double> _pan = {
  'hatC': 0.25,
  'hatO': -0.25,
  'guira': 0.35,
  'congaLo': -0.2,
  'congaHi': 0.2,
  'clave': 0.3,
  'cowbell': -0.3,
  'tamboraHi': 0.2,
};

class _Noise {
  int _s = 987654321;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x3fffffff - 1.0;
  }
}

Float64List _voice(String name, _Noise n) {
  double dur;
  switch (name) {
    case 'kick':
      dur = 0.30;
    case 'hatC':
      dur = 0.08;
    case 'hatO':
      dur = 0.30;
    case 'guira':
      dur = 0.12;
    case 'clave':
      dur = 0.10;
    default:
      dur = 0.30;
  }
  final int len = (dur * _sr).round();
  final out = Float64List(len);
  double ph = 0;
  double prevN = 0;
  for (int i = 0; i < len; i++) {
    final double t = i / _sr;
    final double w = n.next();
    final double hp = w - prevN * 0.95; // ruido con realce de agudos
    prevN = w;
    double v = 0;
    switch (name) {
      case 'kick':
        final double fk = 48 + 120 * exp(-t * 38);
        ph += 2 * pi * fk / _sr;
        v = sin(ph) * exp(-t * 13) + w * exp(-t * 320) * 0.18;
      case 'snare':
        v = hp * exp(-t * 26) * 0.7 + sin(2 * pi * 185 * t) * exp(-t * 30) * 0.5;
      case 'caja':
        v = hp * exp(-t * 38) * 0.6 + sin(2 * pi * 270 * t) * exp(-t * 34) * 0.55;
      case 'clap':
        final double gate = t < 0.036 ? ((t % 0.012) < 0.006 ? 1.0 : 0.35) : 1.0;
        v = hp * exp(-t * 20) * gate * 0.8;
      case 'hatC':
        v = hp * exp(-t * 95);
      case 'hatO':
        v = hp * exp(-t * 20);
      case 'guira':
        v = hp * exp(-t * 48) * (0.55 + 0.45 * exp(-t * 90));
      case 'congaLo':
        v = sin(2 * pi * 175 * (1 + 0.22 * exp(-t * 60)) * t) * exp(-t * 17) +
            w * exp(-t * 250) * 0.15;
      case 'congaHi':
        v = sin(2 * pi * 290 * (1 + 0.22 * exp(-t * 60)) * t) * exp(-t * 19) +
            w * exp(-t * 250) * 0.15;
      case 'clave':
        v = (sin(2 * pi * 2450 * t) + 0.4 * sin(2 * pi * 3100 * t)) * exp(-t * 62);
      case 'cowbell':
        v = (sin(2 * pi * 540 * t) + sin(2 * pi * 811 * t)) * 0.5 * exp(-t * 15);
      case 'tamboraLo':
        final double ft = 82 + 42 * exp(-t * 36);
        ph += 2 * pi * ft / _sr;
        v = sin(ph) * exp(-t * 11) + w * exp(-t * 90) * 0.25;
      case 'tamboraHi':
        v = sin(2 * pi * 210 * (1 + 0.2 * exp(-t * 50)) * t) * exp(-t * 22) +
            hp * exp(-t * 70) * 0.35;
    }
    out[i] = v;
  }
  return out;
}

Uint8List _renderLoopWav(int styleIndex, double bpm) {
  final style = FiestaStyle.values[styleIndex];
  final pattern = _patterns[style] ?? _patterns[FiestaStyle.pulso]!;
  final double spb = _sr * 60.0 / bpm; // muestras por tiempo
  final int total = (spb * 4 * _bars).round();
  final l = Float64List(total);
  final r = Float64List(total);
  final noise = _Noise();
  final voices = <String, Float64List>{
    for (final name in pattern.keys) name: _voice(name, noise),
  };
  for (int bar = 0; bar < _bars; bar++) {
    pattern.forEach((name, steps) {
      final Float64List v = voices[name]!;
      final double g = _gain[name] ?? 0.5;
      final double pan = _pan[name] ?? 0.0;
      final double gl = g * (1 - max(0.0, pan));
      final double gr = g * (1 + min(0.0, pan));
      for (final step in steps) {
        // Variación ligera: el último compás abre un poco más el hi-hat.
        final double vel = (bar == _bars - 1 && name.startsWith('hat')) ? 1.2 : 1.0;
        final int start = ((bar * 16 + step) * spb / 4).round();
        for (int i = 0; i < v.length; i++) {
          final int idx = (start + i) % total; // la cola da la vuelta: loop sin corte
          l[idx] += v[i] * gl * vel;
          r[idx] += v[i] * gr * vel;
        }
      }
    });
  }
  double peak = 0.0001;
  for (int i = 0; i < total; i++) {
    peak = max(peak, max(l[i].abs(), r[i].abs()));
  }
  final double norm = 0.85 / peak;
  final data = ByteData(44 + total * 4);
  void txt(int off, String s) {
    for (int i = 0; i < s.length; i++) {
      data.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  txt(0, 'RIFF');
  data.setUint32(4, 36 + total * 4, Endian.little);
  txt(8, 'WAVE');
  txt(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, _sr, Endian.little);
  data.setUint32(28, _sr * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  txt(36, 'data');
  data.setUint32(40, total * 4, Endian.little);
  for (int i = 0; i < total; i++) {
    data.setInt16(44 + i * 4, (l[i] * norm * 32767).round().clamp(-32767, 32767), Endian.little);
    data.setInt16(46 + i * 4, (r[i] * norm * 32767).round().clamp(-32767, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}
