import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// 🛠️ FIX: Requerido para leer el sello de agua y saltar I/O
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

final metadataWorkerProvider = Provider((ref) => MetadataWorker());

class MetadataWorker {
  // Regex nivel 4 (Portado del Core Python original)
  final RegExp _garbageRegex = RegExp(
    r'\s*[\(\[\{][^\)\]\}]*(official|music video|video|audio|lyric|lyrics|letra|letras|hq|hd|4k|remastered|remaster)[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );
  final _spacesRegex = RegExp(r"\s{2,}");
  final _dashRegex = RegExp(r"\s*-\s*-+\s*");
  final _invalidCharsRegex = RegExp(r'[<>:"/\\|?*]');

  Future<void> processDirectory(
    String directoryPath,
    Function(int, int, String) onProgress, {
    Function(String)? onCorrupt,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp3'))
        .toList();
    int total = files.length;

    for (int i = 0; i < total; i++) {
      // FRENO DE EMERGENCIA ATÓMICO
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [Metadata Worker] Proceso abortado por el usuario.");
        break;
      }
      final file = files[i];
      final filename = file.uri.pathSegments.last;

      onProgress(i + 1, total, filename);

      // 🛠️ FIX: BYPASS SI YA ESTÁ MASTERIZADO
      try {
        if (await rust_dsp.checkWatermark(inputPath: file.path)) {
          continue;
        }
      } catch (_) {}

      // ---------------------------------------------------------
      // AUTO-HEALING: Failsafe de Corrupción I/O
      // ---------------------------------------------------------
      try {
        // Heurística de daño estructural: Si pesa menos de 2KB, no tiene payload de audio real
        if (file.lengthSync() < 2048) {
          throw Exception("Corrupción estructural (Falta payload).");
        }
        // Prueba atómica de lectura de header para validar el I/O Lock
        final randomAccessFile = file.openSync(mode: FileMode.read);
        randomAccessFile.readByteSync();
        randomAccessFile.closeSync();
      } catch (e) {
        debugPrint(
          "🔴 [Auto-Healing] Pista corrupta interceptada: $filename - $e",
        );

        try {
          file.deleteSync(); // Purga física inmediata
        } catch (_) {}

        if (onCorrupt != null) {
          // Limpiamos el nombre para entregarle al Scraper de YouTube un query puro
          final cleanQuery = _cleanFilename(
            filename,
          ).replaceAll(RegExp(r'\.mp3$', caseSensitive: false), '');
          onCorrupt(cleanQuery);
        }
        continue; // Bypass atómico: El bucle jamás se detiene
      }

      final cleanName = _cleanFilename(filename);
      if (cleanName != filename) {
        final newPath =
            '${file.parent.path}${Platform.pathSeparator}$cleanName';
        if (!File(newPath).existsSync()) {
          try {
            await file.rename(newPath);
          } catch (e) {
            debugPrint("🔴 [I/O Lock]: No se pudo renombrar $filename - $e");
          }
        }
      }

      // Prevención de UI Stuttering
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  String _cleanFilename(String filename) {
    String name = filename.substring(0, filename.length - 4);
    String ext = filename.substring(filename.length - 4);

    if (name.endsWith("_R") || name.endsWith(" R")) {
      name = name.substring(0, name.length - 2);
    }

    String cleanName = name.replaceAll(_garbageRegex, " ").trim();
    cleanName = cleanName.replaceAll(_dashRegex, " - ");
    cleanName = cleanName.replaceAll("_", " ");
    cleanName = cleanName.replaceAll(_spacesRegex, " ");

    List<String> parts = cleanName.split(" - ");
    String finalName = "";

    if (parts.length >= 2) {
      String artist = _toTitleCase(parts[0].trim());
      String title = _toTitleCase(parts[1].trim());
      // Reensamblaje estricto: Artista - Título
      finalName = "$artist - $title$ext";
    } else {
      String title = _toTitleCase(cleanName.trim());
      finalName = "$title$ext";
    }

    // Amputación final de caracteres ilegales en Windows
    finalName = finalName.replaceAll(_invalidCharsRegex, "");
    return finalName;
  }

  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  Future<String> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return filePath;

    final filename = file.uri.pathSegments.last;
    final cleanName = _cleanFilename(filename);

    if (cleanName != filename) {
      final targetPath =
          '${file.parent.path}${Platform.pathSeparator}$cleanName';

      try {
        if (targetPath.toLowerCase() == filePath.toLowerCase()) {
          final tempPath =
              '${file.parent.path}${Platform.pathSeparator}TEMP_$cleanName';
          // Usamos Copy/Delete atómico. Evade el Spinlock de MoveFileW
          await file.copy(tempPath);
          await file.delete();
          await File(tempPath).copy(targetPath);
          await File(tempPath).delete();
        } else {
          if (!File(targetPath).existsSync()) {
            await file.copy(targetPath);
            await file.delete();
          }
        }

        // ¡Magia inyectada! Sincronizamos la letra antigua si existía
        await _syncAssociatedFile(filePath, targetPath, '.lrc');

        return targetPath;
      } catch (e) {
        debugPrint("🔴 [I/O Lock Evadido]: $e");
        return filePath;
      }
    }

    return filePath;
  }

  // Motor para evitar dejar archivos .lrc o .txt huérfanos al renombrar el MP3
  Future<void> _syncAssociatedFile(
    String oldMp3,
    String newMp3,
    String ext,
  ) async {
    final oldFile = File(
      oldMp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), ext),
    );
    if (!oldFile.existsSync()) return;

    final newFile = File(
      newMp3.replaceAll(RegExp(r'\.mp3$', caseSensitive: false), ext),
    );
    try {
      if (oldFile.path.toLowerCase() == newFile.path.toLowerCase()) {
        final temp = File(
          '${oldFile.parent.path}${Platform.pathSeparator}TEMP_${oldFile.uri.pathSegments.last}',
        );
        await oldFile.copy(temp.path);
        await oldFile.delete();
        await temp.copy(newFile.path);
        await temp.delete();
      } else if (!newFile.existsSync()) {
        await oldFile.copy(newFile.path);
        await oldFile.delete();
      }
    } catch (_) {}
  }
}
