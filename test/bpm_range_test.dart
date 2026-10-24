import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/bpm_range.dart';

void main() {
  test('11499 y 14109 son BPM ×100', () {
    expect(fixBpmRange(11499), 114.99);
    expect(fixBpmRange(14109), 141.09);
  });

  test('el doble y la mitad vuelven a 60–200', () {
    expect(fixBpmRange(358), 179);
    expect(fixBpmRange(45), 90);
  });

  test('fuera de rango se descarta', () {
    expect(fixBpmRange(0), isNull);
    expect(fixBpmRange(0.01), isNull);
    expect(fixBpmRange(30000), isNull);
    expect(fixBpmRange(double.nan), isNull);
  });

  test('un BPM ya válido se queda', () {
    expect(fixBpmRange(128), 128);
    expect(fixBpmRange(60), 60);
    expect(fixBpmRange(200), 200);
  });
}
