import 'package:isar/isar.dart';

part 'track_metadata.g.dart';

@collection
class TrackMetadata {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String filePath;

  late String mixProfile;
  late int mixDurationMs;
  late String genreAssigned;

  // Nuevos campos para los puntos de mezcla manuales (Nullables)
  int? cueInMs;
  int? mixOutMs;

  // 🛠️ INYECCIÓN: Banderas de Estado (Máquina de Estados) para el Laboratorio
  bool hasLyrics = false;
  bool hasBpm = false;
  bool hasCurve = false;

  static int fastHash(String string) {
    var hash = 0xcbf29ce484222325;
    var i = 0;
    while (i < string.length) {
      final codeUnit = string.codeUnitAt(i++);
      hash ^= codeUnit;
      hash *= 0x100000001b3;
    }
    return hash;
  }
}
