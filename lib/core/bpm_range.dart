/// BPM musical válido para mezclar: 60–200.
///
/// Un ID3 guardado ×100 (11499 → 114.99, 14109 → 141.09) se divide primero.
/// Lo que sigue fuera de rango se dobla o se parte por la mitad hasta caer
/// dentro, o se descarta.
double? fixBpmRange(double bpm) {
  if (bpm.isNaN || bpm.isInfinite || bpm <= 0) return null;
  var b = bpm;
  if (b > 300) {
    final double scaled = b / 100.0;
    if (scaled >= 60 && scaled <= 200) b = scaled;
  }
  for (var i = 0; i < 6; i++) {
    if (b > 200 && b / 2 >= 60) {
      b /= 2;
    } else if (b < 60 && b * 2 <= 200) {
      b *= 2;
    } else {
      break;
    }
  }
  if (b < 60 || b > 200) return null;
  return (b * 100).round() / 100.0;
}
