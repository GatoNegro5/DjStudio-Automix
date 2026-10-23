/// Pausa de enfriamiento y prioridad de Masterizar.
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

  /// 1 hilo en el móvil, 2 en escritorio. Sin más.
  static int workerThreads(String platform) {
    switch (platform) {
      case 'android':
      case 'ios':
        return 1;
      default:
        return 2;
    }
  }

  /// Nombre de la prioridad que pide cada plataforma.
  static String priorityLabel(String platform) {
    switch (platform) {
      case 'windows':
        return 'ecoqos+background';
      case 'macos':
      case 'ios':
        return 'qos-utility';
      default:
        return 'nice10';
    }
  }

  /// Android: headroom de 10 s por encima de 0,7.
  static bool headroomIsHigh(double? headroom) {
    if (headroom == null || headroom.isNaN || !headroom.isFinite) return false;
    return headroom > 0.7;
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

  /// Android PowerManager: SEVERE = 3, o headroom > 0,7.
  /// iOS/macOS thermalState: serious = 2, critical = 3.
  /// Windows no tiene API: no se alarga.
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

  /// La pausa extra. Windows ignora lecturas: solo cuenta la base de 12 s.
  static bool shouldExtendPause({
    required String platform,
    required int? status,
    required double? headroom,
  }) {
    if (platform != 'android' && platform != 'ios' && platform != 'macos') {
      return false;
    }
    if (platform == 'android' && headroomIsHigh(headroom)) return true;
    return thermalIsHigh(platform: platform, status: status);
  }

  /// Texto del log: estado térmico de esta canción.
  static String thermalLabel({
    required String platform,
    int? status,
    double? headroom,
  }) {
    if (platform == 'android') {
      final String st = switch (status) {
        0 => 'none',
        1 => 'light',
        2 => 'moderate',
        3 => 'severe',
        4 => 'critical',
        5 => 'emergency',
        6 => 'shutdown',
        _ => 'n/a',
      };
      final String h = headroom != null && headroom.isFinite
          ? headroom.toStringAsFixed(2)
          : 'n/a';
      return 'status=$st headroom=$h';
    }
    if (platform == 'ios' || platform == 'macos') {
      return switch (status) {
        0 => 'nominal',
        1 => 'fair',
        2 => 'serious',
        3 => 'critical',
        _ => 'n/a',
      };
    }
    return 'n/a';
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
