import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/master_affinity.dart';
import 'package:gatomix/core/master_cool.dart';

void main() {
  test('la pausa queda entre 10 y 15 s, con 12 de fábrica', () {
    expect(MasterCool.pauseDefaultMs, 12000);
    expect(MasterCool.clampPauseMs(12000), 12000);
    expect(MasterCool.clampPauseMs(2000), 10000);
    expect(MasterCool.clampPauseMs(30000), 15000);
    expect(MasterCool.clampPauseMs(10000), 10000);
    expect(MasterCool.clampPauseMs(15000), 15000);
  });

  test('el par rota en 4 turnos y no se repite seguido', () {
    expect(MasterCool.pairTurns(8), 4);
    expect(MasterCool.pairTurns(16), 4);
    expect(MasterCool.pairTurns(4), 2);
    expect(MasterCool.pairTurns(6), 3);
    expect(MasterCool.pairTurns(2), 1);
    expect(MasterCool.pairForSong(0, 8), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(1, 8), const MasterPair(2, 3));
    expect(MasterCool.pairForSong(2, 8), const MasterPair(4, 5));
    expect(MasterCool.pairForSong(3, 8), const MasterPair(6, 7));
    expect(MasterCool.pairForSong(4, 8), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(0, 4), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(1, 4), const MasterPair(2, 3));
    expect(MasterCool.pairForSong(2, 4), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(0, 6), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(2, 6), const MasterPair(4, 5));
    expect(MasterCool.pairForSong(0, 16), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(4, 16), const MasterPair(0, 1));
    expect(MasterCool.pairForSong(0, 1), const MasterPair(0, 0));
    expect(MasterCool.pairForSong(-1, 8), const MasterPair(0, 1));
    for (final int n in [4, 6, 8, 12, 16]) {
      for (var i = 0; i < 10; i++) {
        expect(
          MasterCool.pairForSong(i, n) == MasterCool.pairForSong(i + 1, n),
          isFalse,
          reason: 'n=$n canción $i',
        );
      }
    }
  });

  test('la barra dice Enfriando… Ns', () {
    expect(MasterCool.label(12000), 'Enfriando… 12s');
    expect(MasterCool.label(11000), 'Enfriando… 11s');
    expect(MasterCool.label(1001), 'Enfriando… 2s');
    expect(MasterCool.label(1), 'Enfriando… 1s');
    expect(MasterCool.label(0), 'Enfriando… 0s');
  });

  test('la X corta la pausa y el térmico alto la alarga', () {
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      12000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (int t) => t >= 500,
      ),
      500,
    );
    expect(
      MasterCool.simulate(
        baseMs: 2000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      10000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 30000,
        tickMs: 100,
        hotAt: (_) => false,
        cancelledAt: (_) => false,
      ),
      15000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (int t) => t < 15000,
        cancelledAt: (_) => false,
      ),
      15000,
    );
    expect(
      MasterCool.simulate(
        baseMs: 12000,
        tickMs: 100,
        hotAt: (_) => true,
        cancelledAt: (int t) => t >= 20000,
      ),
      20000,
    );
  });

  test('térmico alto: Android desde SEVERE, iOS desde serious', () {
    expect(MasterCool.thermalIsHigh(platform: 'android', status: 2), isFalse);
    expect(MasterCool.thermalIsHigh(platform: 'android', status: 3), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'ios', status: 1), isFalse);
    expect(MasterCool.thermalIsHigh(platform: 'ios', status: 2), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'macos', status: 2), isTrue);
    expect(MasterCool.thermalIsHigh(platform: 'windows', status: 5), isFalse);
    expect(MasterCool.thermalIsHigh(platform: 'android', status: null), isFalse);
  });

  test('el par publicado se lee y se limpia', () {
    MasterAffinity.publish(2, 3);
    expect(MasterAffinity.current(), '2-3');
    MasterAffinity.clear();
    expect(MasterAffinity.current(), isNull);
  });
}
