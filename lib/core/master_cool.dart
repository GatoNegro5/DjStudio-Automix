/// Par de núcleos de una canción. `low` es decode/análisis, `high` es
/// encoder/limitador. Con un solo núcleo los dos coinciden.
class MasterPair {
  final int low;
  final int high;

  const MasterPair(this.low, this.high);

  String get label => low == high ? '$low' : '$low-$high';

  @override
  bool operator ==(Object other) =>
      other is MasterPair && other.low == low && other.high == high;

  @override
  int get hashCode => Object.hash(low, high);
}

/// Turno de núcleos y pausa de enfriamiento de Masterizar.
/// Puro: sin Flutter, para poder probarlo.
class MasterCool {
  static const int pauseMinMs = 10000;
  static const int pauseMaxMs = 15000;
  static const int pauseDefaultMs = 12000;

  /// La pausa configurada entra en 10–15 s. 12 s es el valor de fábrica.
  static int clampPauseMs(int ms) {
    if (ms < pauseMinMs) return pauseMinMs;
    if (ms > pauseMaxMs) return pauseMaxMs;
    return ms;
  }

  /// Turnos de pares. 8 o más núcleos: 4 (0-1, 2-3, 4-5, 6-7).
  /// Con menos, los pares que caben (4 núcleos → 2 turnos).
  static int pairTurns(int processors) {
    final int n = processors < 1 ? 1 : processors;
    final int pairs = n ~/ 2;
    if (pairs < 1) return 1;
    if (pairs > 4) return 4;
    return pairs;
  }

  /// Par de esta canción. Canción 0 → 0-1, 1 → 2-3, y así. Con 2 turnos
  /// o más, dos canciones seguidas no comparten par.
  static MasterPair pairForSong(int songIndex, int processors) {
    final int n = processors < 1 ? 1 : processors;
    final int i = songIndex < 0 ? 0 : songIndex;
    final int slot = i % pairTurns(n);
    if (n < 2) return const MasterPair(0, 0);
    final int low = slot * 2;
    final int high = low + 1;
    return MasterPair(low, high < n ? high : n - 1);
  }

  /// Texto exacto de la barra: `Enfriando… Ns`.
  static String label(int remainingMs) {
    final int s = remainingMs <= 0 ? 0 : (remainingMs / 1000).ceil();
    return 'Enfriando… ${s}s';
  }

  /// Ms que quedan por mostrar. Pasada la pausa base, cuenta otra
  /// rodaja (térmico alto) para que el número siga bajando.
  static int displayRemainingMs(
    int elapsedMs,
    int baseMs, {
    int sliceMs = 5000,
  }) {
    if (elapsedMs >= baseMs) {
      final int slice = sliceMs < 1 ? 1 : sliceMs;
      final int into = (elapsedMs - baseMs) % slice;
      final int left = slice - into;
      return left == 0 ? slice : left;
    }
    final int left = baseMs - elapsedMs;
    return left < 0 ? 0 : left;
  }

  /// Sigue en pausa mientras no se cancele, falte la base, o el equipo
  /// siga caliente después de la base.
  static bool keepWaiting({
    required int elapsedMs,
    required int baseMs,
    required bool thermalHigh,
    required bool cancelled,
  }) {
    if (cancelled) return false;
    if (elapsedMs < baseMs) return true;
    return thermalHigh;
  }

  /// Android PowerManager: SEVERE = 3. iOS/macOS thermalState: serious = 2.
  /// Sin lectura (escritorio u error) no se alarga.
  static bool thermalIsHigh({required String platform, required int? status}) {
    if (status == null || status < 0) return false;
    switch (platform) {
      case 'android':
        return status >= 3;
      case 'ios':
      case 'macos':
        return status >= 2;
      default:
        return false;
    }
  }

  /// Reloj de la pausa en ticks, sin dormir. Sirve para el test.
  static int simulate({
    required int baseMs,
    required int tickMs,
    required bool Function(int elapsedMs) hotAt,
    required bool Function(int elapsedMs) cancelledAt,
    int guardMs = 180000,
  }) {
    final int gap = clampPauseMs(baseMs);
    final int step = tickMs < 1 ? 1 : tickMs;
    var elapsed = 0;
    while (elapsed <= guardMs) {
      if (cancelledAt(elapsed)) break;
      final bool hot = elapsed >= gap && hotAt(elapsed);
      if (!keepWaiting(
        elapsedMs: elapsed,
        baseMs: gap,
        thermalHigh: hot,
        cancelled: false,
      )) {
        break;
      }
      elapsed += step;
    }
    return elapsed;
  }
}
