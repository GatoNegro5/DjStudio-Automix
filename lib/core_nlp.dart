import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class NlpEngine {
  // 🛠️ INYECCIÓN: Extracción Nativa de Duración Local
  Future<int> _getLocalDurationSec(String filePath) async {
    try {
      final result = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      if (result.exitCode == 0) {
        return (double.tryParse(result.stdout.toString().trim()) ?? 0.0)
            .toInt();
      }
    } catch (_) {}
    return 0;
  }

  Future<void> fetchLyrics(String filePath) async {
    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);

    if (file.existsSync()) {
      final content = await file.readAsString();
      if (content.contains('Letra no encontrada') ||
          content.contains('Error de conexión')) {
        await file.delete();
        debugPrint(
          "🗑️ [NLP Cache] Caché negativo purgado. Forzando re-escaneo HTTP.",
        );
      } else if (file.lengthSync() > 20) {
        debugPrint(
          "⏭️ [BYPASS NLP] Archivo LRC válido ya existe. I/O evadido.",
        );
        return;
      }
    }

    final audioFile = File(filePath);
    final filename = audioFile.uri.pathSegments.last.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '',
    );

    debugPrint("🔵 [NLP Tracker] Buscando letra para: $filename");
    bool success = await _fetchAndSaveLrc(filePath, filename, lrcPath);

    if (!success) {
      await file.writeAsString(
        '[00:00.00] 🎵 Letra no encontrada en la base de datos API\n[00:05.00] \n',
      );
      debugPrint(
        "🟡 [NLP Tracker] Sin coincidencias. Caché negativo inyectado en LRC.",
      );
    }
  }

  Future<bool> _fetchAndSaveLrc(
    String filePath,
    String cleanFilename,
    String lrcPath,
  ) async {
    try {
      final parts = cleanFilename.split(' - ');
      final localSec = await _getLocalDurationSec(filePath);

      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final originalTrack = parts[1].trim();
        List<String> trackWords = originalTrack.split(' ');

        while (trackWords.isNotEmpty) {
          final currentTrackAttempt = trackWords.join(' ');
          final uri = Uri.parse(
            'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(currentTrackAttempt)}',
          );

          final response = await http
              .get(uri)
              .timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            final List<dynamic> data = jsonDecode(response.body);
            if (data.isNotEmpty) {
              data.sort((a, b) {
                final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
                final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;
                if (aSync && !bSync) return -1;
                if (!aSync && bSync) return 1;
                if (localSec > 0) {
                  final aDur = (a['duration'] as num?)?.toInt() ?? 0;
                  final bDur = (b['duration'] as num?)?.toInt() ?? 0;
                  return (aDur - localSec).abs().compareTo(
                    (bDur - localSec).abs(),
                  );
                }
                return 0;
              });

              for (var item in data) {
                final syncedLyrics = item['syncedLyrics'];
                if (syncedLyrics != null &&
                    syncedLyrics.toString().trim().isNotEmpty) {
                  await File(lrcPath).writeAsString(syncedLyrics);
                  debugPrint(
                    "🟢 [NLP Tracker] LRC consolidado con: $currentTrackAttempt",
                  );
                  return true;
                }
              }
            }
          }
          trackWords.removeLast();
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      final fallbackUri = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(cleanFilename)}',
      );
      final fallbackResponse = await http
          .get(fallbackUri)
          .timeout(const Duration(seconds: 10));

      if (fallbackResponse.statusCode == 200) {
        final List<dynamic> data = jsonDecode(fallbackResponse.body);
        if (data.isNotEmpty) {
          data.sort((a, b) {
            final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
            final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;
            if (aSync && !bSync) return -1;
            if (!aSync && bSync) return 1;
            if (localSec > 0) {
              final aDur = (a['duration'] as num?)?.toInt() ?? 0;
              final bDur = (b['duration'] as num?)?.toInt() ?? 0;
              return (aDur - localSec).abs().compareTo((bDur - localSec).abs());
            }
            return 0;
          });

          for (var item in data) {
            final syncedLyrics = item['syncedLyrics'];
            if (syncedLyrics != null &&
                syncedLyrics.toString().trim().isNotEmpty) {
              await File(lrcPath).writeAsString(syncedLyrics);
              debugPrint("🟢 [NLP Tracker] LRC salvado vía Failsafe genérico.");
              return true;
            }
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint("🔴 [NLP Tracker] Excepción de red: $e");
      return false;
    }
  }
}
