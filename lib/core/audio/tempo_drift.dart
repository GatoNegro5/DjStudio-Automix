import 'dart:math';

import 'package:media_kit/media_kit.dart';

/// Regulación sutil del tempo de la pista que suena (Live DJ y Automix).
///
/// - Una pista entrante que se aceleró/frenó MUCHO para igualar a la anterior
///   (≥ 3 %) NO vuelve a su BPM de golpe: se queda con ese tempo y se acerca a
///   su BPM real de 1 a 2 BPM en la mitad (50 %) y otra vez al 75 %.
/// - Al final (antes de la mezcla) toda pista se acerca 1 a 2 BPM al BPM de la
///   siguiente, para que el cruce sea más corto en tempo.
/// - Los cambios se hacen con rampas lentas: no se nota el salto.
/// Las pistas con poca corrección conservan el comportamiento de siempre.
class TempoDrift {
  static const double bigChange = 0.03;
  static const double minRate = 0.88;
  static const double maxRate = 1.12;

  double natural = 0.0;
  bool active = false;
  bool _d50 = false;
  bool _d75 = false;
  bool _dEnd = false;
  int _gen = 0;

  static bool isBig(double rate) => (rate - 1.0).abs() >= bigChange;

  /// Nueva pista sonando: `natural` = su BPM real, `rate` = tempo con el que entró.
  void begin(double naturalBpm, double rate) {
    _gen++;
    natural = naturalBpm;
    active = naturalBpm > 60 && isBig(rate);
    _d50 = false;
    _d75 = false;
    _dEnd = false;
  }

  void stop() {
    _gen++;
    active = false;
    natural = 0.0;
    _d50 = true;
    _d75 = true;
    _dEnd = true;
  }

  /// 1 BPM (2 si falta mucho) hacia el objetivo, nunca pasándose.
  static double _step(double deltaBpm) {
    final double a = deltaBpm.abs();
    if (a <= 1.0) return deltaBpm;
    final double s = a >= 6.0 ? 2.0 : 1.0;
    return deltaBpm.sign * min(s, a);
  }

  double _clamp(double r) => r.clamp(minRate, maxRate).toDouble();

  /// Devuelve el nuevo rate objetivo, o null si no toca ajustar.
  double? tick({
    required int posMs,
    required int durMs,
    required int mixOutMs,
    required double rate,
    required double nextBpm,
  }) {
    if (natural <= 60 || durMs <= 0) return null;
    final double eff = natural * rate;
    final bool roomBeforeMix = mixOutMs <= 0 || posMs < mixOutMs - 15000;
    final double f = posMs / durMs;

    if (active && !_d50 && f >= 0.5 && roomBeforeMix) {
      _d50 = true;
      return _clamp((eff + _step(natural - eff)) / natural);
    }
    if (active && !_d75 && f >= 0.75 && roomBeforeMix) {
      _d75 = true;
      return _clamp((eff + _step(natural - eff)) / natural);
    }
    if (!_dEnd && mixOutMs > 0 && posMs >= mixOutMs - 10000 && nextBpm > 60) {
      _dEnd = true;
      _d50 = true;
      _d75 = true;
      final double d = nextBpm - eff;
      if (d.abs() < 0.3) return null;
      return _clamp((eff + _step(d)) / natural);
    }
    return null;
  }

  /// Rampa lenta (senoidal) del rate; se cancela si empieza otra pista.
  Future<void> ramp(Player p, double from, double to, {int ms = 5000}) async {
    final int g = _gen;
    final Stopwatch sw = Stopwatch()..start();
    try {
      while (sw.elapsedMilliseconds < ms) {
        if (g != _gen) return;
        final double t = (sw.elapsedMilliseconds / ms).clamp(0.0, 1.0);
        await p.setRate(from + (to - from) * sin(t * pi / 2));
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (g == _gen) await p.setRate(to);
    } catch (_) {}
  }
}
