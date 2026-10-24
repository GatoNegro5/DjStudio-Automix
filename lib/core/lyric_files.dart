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

bool lrcBakExists(String lrcPath) => File('$lrcPath.bak').existsSync();
