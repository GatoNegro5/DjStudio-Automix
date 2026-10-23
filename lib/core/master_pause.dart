import 'master_cool.dart';
import 'thermal_status.dart';

/// Pausa entre canciones. Sale en el siguiente tick (~100 ms) si [cancelled]
/// pasa a true, también a mitad del enfriamiento. Si el térmico sigue alto
/// al cumplir la base y [allowThermal] es true, alarga hasta que baje.
class MasterPause {
  static Future<int> run({
    required int baseMs,
    required bool Function() cancelled,
    required void Function(String label) onTick,
    bool allowThermal = true,
  }) async {
    final int gap = MasterCool.clampPauseMs(baseMs);
    final Stopwatch sw = Stopwatch()..start();
    var lastProbe = -10000;
    var hot = false;
    while (true) {
      if (cancelled()) break;
      final int elapsed = sw.elapsedMilliseconds;
      if (allowThermal && elapsed >= gap && elapsed - lastProbe >= 1000) {
        lastProbe = elapsed;
        hot = await ThermalProbe.isHigh();
        if (cancelled()) break;
      }
      if (!MasterCool.keepWaiting(
        elapsedMs: elapsed,
        baseMs: gap,
        thermalHigh: allowThermal && elapsed >= gap && hot,
        cancelled: false,
      )) {
        break;
      }
      onTick(MasterCool.label(MasterCool.displayRemainingMs(elapsed, gap)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return sw.elapsedMilliseconds;
  }
}
