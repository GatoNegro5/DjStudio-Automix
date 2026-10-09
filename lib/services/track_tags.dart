import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

/// Lo que dejó el MASTERIZADO en las etiquetas de la pista (Rust/id3):
/// silencios de inicio/fin, BPM y ganancia ReplayGain. Se lee sin decodificar.
/// Caché en memoria con lectura síncrona (`peek`) para los motores de mezcla.
class TrackTags {
  final bool analyzed;
  final int leadMs;
  final int tailMs;
  final double bpm;
  final double gainDb;
  const TrackTags({
    this.analyzed = false,
    this.leadMs = 0,
    this.tailMs = 0,
    this.bpm = 0.0,
    this.gainDb = 0.0,
  });

  static const TrackTags empty = TrackTags();
  static final Map<String, TrackTags> _cache = {};

  /// Lectura inmediata (null si aún no se cargó con [load]).
  static TrackTags? peek(String? path) => path == null ? null : _cache[path];

  /// Carga (una sola vez por ruta) y devuelve las etiquetas.
  static Future<TrackTags> load(String path) async {
    final hit = _cache[path];
    if (hit != null) return hit;
    TrackTags t = empty;
    try {
      final m = await rust_dsp.readMasterTags(inputPath: path);
      t = TrackTags(
        analyzed: m.analyzed,
        leadMs: m.leadMs.toInt(),
        tailMs: m.tailMs.toInt(),
        bpm: m.bpm,
        gainDb: m.gainDb,
      );
    } catch (_) {}
    _cache[path] = t;
    return t;
  }

  /// Olvida una ruta (p. ej. tras volver a masterizar).
  static void forget(String path) => _cache.remove(path);
}
