/// Turno de núcleo y pausa de enfriamiento de Masterizar.
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

  /// Núcleo de esta canción. Rota 0, 1, …, n-1 y vuelve a empezar.
  static int coreForSong(int songIndex, int processors) {
    final int n = processors < 1 ? 1 : processors;
    final int i = songIndex < 0 ? 0 : songIndex;
    return i % n;
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
