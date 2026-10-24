import 'dart:async';
import 'dart:io';

/// Copia el `.lrc` actual a `.lrc.bak` y escribe [text].
Future<void> writeLrcKeepingBak(String lrcPath, String text) async {
  final File f = File(lrcPath);
  if (f.existsSync()) {
    await f.copy('$lrcPath.bak');
  }
  await f.writeAsString(text);
}

/// Restaura `.lrc.bak` sobre el `.lrc`. False si no hay copia.
Future<bool> restoreLrcBak(String lrcPath) async {
  final File bak = File('$lrcPath.bak');
  if (!bak.existsSync()) return false;
  await bak.copy(lrcPath);
  return true;
}

/// Deshace un Aplicar. Si había `.lrc`, vuelve el `.bak`. Si no había, borra el nuevo.
Future<bool> undoAppliedLrc(String lrcPath) async {
  final File bak = File('$lrcPath.bak');
  final File f = File(lrcPath);
  if (bak.existsSync()) {
    await bak.copy(lrcPath);
    return true;
  }
  if (f.existsSync()) {
    await f.delete();
    return true;
  }
  return false;
}

bool lrcBakExists(String lrcPath) => File('$lrcPath.bak').existsSync();

final StreamController<String> _lrcChanges = StreamController<String>.broadcast();

/// Audios cuyo `.lrc` cambió (Buscar letra, Deshacer, Restaurar). Automix y
/// Karaoke lo escuchan para releer la letra si es el tema que tienen abierto.
Stream<String> get lrcChanges => _lrcChanges.stream;

void notifyLrcChanged(String audioPath) {
  if (audioPath.isNotEmpty) _lrcChanges.add(audioPath);
}

/// Misma ruta de audio con `\` o `/`; sin distinguir mayúsculas en Windows.
bool sameAudioPath(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  String n(String p) {
    final String x = p.replaceAll('\\', '/');
    return Platform.isWindows ? x.toLowerCase() : x;
  }
  return n(a) == n(b);
}

enum LabLrcRestore { none, moved, keptOrigin }

/// Restaurar al Origen: mueve el `.lrc` del LAB junto al audio y borra solo
/// `<lrc del LAB>.bak`. Si en origen ya hay `.lrc`, no se sobrescribe: la
/// letra del LAB y su `.bak` se quedan en el LAB.
Future<LabLrcRestore> moveLabLrcToOrigin({
  required String labLrcPath,
  required String originLrcPath,
}) async {
  final File lab = File(labLrcPath);
  final File bak = File('$labLrcPath.bak');
  if (!lab.existsSync()) {
    if (bak.existsSync()) await bak.delete();
    return LabLrcRestore.none;
  }
  final File dest = File(originLrcPath);
  if (dest.existsSync()) return LabLrcRestore.keptOrigin;
  try {
    await lab.rename(originLrcPath);
  } on FileSystemException {
    await lab.copy(originLrcPath);
    await lab.delete();
  }
  if (bak.existsSync()) await bak.delete();
  return LabLrcRestore.moved;
}
