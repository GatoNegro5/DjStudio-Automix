import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pipeline_provider.dart';
import 'package:flutter/foundation.dart';
import 'db_provider.dart'; // 🛠️ Requerido para inyectar Cues a la BD

final nlpWorkerProvider = Provider((ref) => NlpWorker(ref));

class NlpWorker {
  final Ref ref;

  final Map<String, String> _headers = {
    'User-Agent': 'DJStudioPlayer/1.0.0 (Custom Build)',
  };

  NlpWorker(this.ref);

  Future<http.Response> _resilientGet(String targetUrl) async {
    final directUri = Uri.parse(targetUrl);
    int maxRetries = 3;
    int baseDelayMs = 1500;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final res = await http
            .get(directUri, headers: _headers)
            .timeout(const Duration(seconds: 4));

        if (res.statusCode == 200) return res;

        // 🛠️ EXPONENTIAL BACKOFF: Si es Rate Limit (429) o Server Error (5xx), esperamos y reintentamos.
        if (res.statusCode == 429 || res.statusCode >= 500) {
          if (attempt == maxRetries - 1)
            return res; // Último intento, devolvemos el error.

          final delay = baseDelayMs * (1 << attempt); // 1.5s -> 3s -> 6s
          debugPrint(
            "🟡 [NLP Rate Limit] HTTP ${res.statusCode}. Pausando hilo $delay ms (Intento ${attempt + 1})...",
          );
          await Future.delayed(Duration(milliseconds: delay));
          continue;
        }

        return res; // Para 404 (Not Found) u otros errores de cliente, devolvemos directo.
      } catch (e) {
        if (attempt == maxRetries - 1) {
          debugPrint(
            "🟡 [NLP Circuit Breaker] Conexión directa falló tras $maxRetries intentos. Saltando a Proxy...",
          );
          break;
        }
        await Future.delayed(
          Duration(milliseconds: baseDelayMs * (1 << attempt)),
        );
      }
    }

    // 🛠️ FALLBACK: Proxy de última instancia
    final proxyUri = Uri.parse(
      'https://api.allorigins.win/raw?url=${Uri.encodeComponent(targetUrl)}',
    );
    return await http.get(proxyUri).timeout(const Duration(seconds: 8));
  }

  // 🛠️ MÓDULO V4.1: CÁLCULO DE COLISIÓN VOCAL CON ESCUDO ANTI-BASURA
  // 🛠️ MÓDULO V4.2: CÁLCULO DE COLISIÓN VOCAL (BLINDADO CONTRA CUES MANUALES)
  Future<void> _processVocalBoundingBox(
    String audioPath,
    String syncedLyrics,
    int durationSec,
  ) async {
    try {
      final db = ref.read(dbServiceProvider);
      final existingMeta = await db.getTrackMetadata(audioPath);

      // 🛡️ REGLA MAESTRA: Si el usuario ya fijó puntos en el Laboratorio, el NLP retrocede.
      if (existingMeta != null && existingMeta.isManualCue) {
        debugPrint(
          "⏭️ [AUTO-MASTER] NLP Evadido. Cues manuales detectados para: $audioPath",
        );
        return;
      }

      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      int? firstMs;
      int? lastMs;

      final lines = syncedLyrics.split('\n');
      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final text = match.group(4)!.trim().toLowerCase();

          bool isGarbage =
              text.isEmpty ||
              text.startsWith('by:') ||
              text.startsWith('artist:') ||
              text.startsWith('title:') ||
              text.contains('synced') ||
              text.contains('lyric') ||
              text.contains('www.') ||
              text.length < 3;

          if (!isGarbage) {
            final min = int.parse(match.group(1)!);
            final sec = int.parse(match.group(2)!);
            int ms = int.parse(match.group(3)!);
            if (match.group(3)!.length == 2) ms *= 10;
            final totalMs = (min * 60000) + (sec * 1000) + ms;

            firstMs ??= totalMs;
            lastMs = totalMs;
          }
        }
      }

      if (firstMs != null && lastMs != null) {
        int cueIn = firstMs - 5000;
        if (cueIn < 0) cueIn = 0;

        // 🛠️ FIX: Dinámica de Coda para Outpoints.
        // En lugar de recortar a 6s estáticos, medimos si la canción tiene "Outro" instrumental.
        int mixOut = lastMs + 1000; // Solo damos 1s de respiro post-letra
        int totalMs = durationSec * 1000;

        if (totalMs > 0) {
          final timeRemaining = totalMs - mixOut;
          // Si el instrumental de salida es larguísimo (> 15s), anclamos el mixOut más atrás para no aburrir
          if (timeRemaining > 15000) {
            mixOut = lastMs + 4000;
          } else if (timeRemaining < 3000) {
            // Si la letra llega hasta el mismísimo final, el mixOut debe retroceder para dar espacio al crossfade de la sig canción
            mixOut = totalMs - 4000;
          }
        }
        if (mixOut < 0) mixOut = 0;

        try {
          await db.saveTrackMetadata(
            path: audioPath,
            cueInMs: cueIn,
            mixOutMs: mixOut,
            isManualCue: false,
          );
          debugPrint(
            "🎛️ [AUTO-MASTER] Cues IN: ${cueIn}ms | OUT: ${mixOut}ms -> $audioPath",
          );
        } catch (e) {
          debugPrint("🔴 Error guardando metadata en BD: $e");
        }
      }
    } catch (e) {
      debugPrint("🔴 [AUTO-MASTER] Error calculando Bounding Box: $e");
    }
  }

  Future<void> processDirectory(
    String directoryPath, {
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
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [NLP Worker] Scraping abortado por el usuario.");
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;

      final lrcPath = file.path.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      final lrcFile = File(lrcPath);

      if (lrcFile.existsSync()) {
        final content = await lrcFile.readAsString();
        if (!content.contains('Letra no encontrada') &&
            !content.contains('Error de conexión') &&
            !content.contains('Error Auto-Healing') &&
            lrcFile.lengthSync() > 20) {
          // 🛠️ DESTRUCCIÓN DEL BYPASS:
          // Si el CueIn está en cero (o no existe) y no es manual, FORZAMOS el recálculo
          // ignorando si el MixOut ya estaba lleno.
          final meta = await ref
              .read(dbServiceProvider)
              .getTrackMetadata(file.path);
          if (meta == null || (!meta.isManualCue && meta.cueInMs == 0)) {
            final localSec = await _getLocalDurationSec(file.path);
            await _processVocalBoundingBox(file.path, content, localSec);
          }
          continue;
        }
      }

      pipe.updateProgress(i + 1, total, filename, "Scraping LRC");

      await processSingleFile(file.path);

      await Future.delayed(const Duration(milliseconds: 150));
    }
    pipe.reset();
  }

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

  Future<List<dynamic>> searchLyricCandidates(
    String query, {
    String? badLyric,
  }) async {
    List<dynamic> allResults = [];
    bool isServerError = false;
    String errorMessage = "No se encontraron resultados.";

    Future<void> fetchTarget(String url) async {
      try {
        final response = await _resilientGet(url);
        if (response.statusCode == 200) {
          final parsed = jsonDecode(response.body);
          if (parsed is List) allResults.addAll(parsed);
        } else if (response.statusCode >= 500) {
          isServerError = true;
          errorMessage =
              "Error ${response.statusCode}: El servidor de letras reporta una caída crítica (Bad Gateway).";
        }
      } catch (e) {
        isServerError = true;
        errorMessage = "El servidor no responde (Tiempo de espera agotado).";
      }
    }

    final globalUrl =
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query.trim())}';
    await fetchTarget(globalUrl);

    if (query.contains('-')) {
      final parts = query.split('-');
      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final track = parts.sublist(1).join(' ').trim();
        final advancedUrl =
            'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(track)}';
        await fetchTarget(advancedUrl);
      }
    }

    if (allResults.isEmpty && isServerError) throw Exception(errorMessage);

    final uniqueResults = <int, dynamic>{};
    for (var item in allResults) {
      if (item['id'] != null) uniqueResults[item['id']] = item;
    }
    final combinedData = uniqueResults.values.toList();

    return combinedData.where((item) {
      final synced = item['syncedLyrics'];
      if (synced == null || synced.toString().trim().isEmpty) return false;

      if (badLyric != null && badLyric.isNotEmpty) {
        String apiText = synced
            .toString()
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        String badText = badLyric
            .replaceAll(RegExp(r'\[.*?\]'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        String apiSnippet = apiText.length > 40
            ? apiText.substring(0, 40)
            : apiText;
        String badSnippet = badText.length > 40
            ? badText.substring(0, 40)
            : badText;

        if (apiSnippet.isNotEmpty &&
            badSnippet.isNotEmpty &&
            apiSnippet == badSnippet) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> writeManualLyric(String audioPath, String syncedLyrics) async {
    final lrcPath = audioPath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    await File(lrcPath).writeAsString(syncedLyrics);

    // Inyectar el Bounding Box al forzar letra manual
    final localSec = await _getLocalDurationSec(audioPath);
    await _processVocalBoundingBox(audioPath, syncedLyrics, localSec);

    debugPrint(
      "🟢 [NLP Tracker] LRC manual sobreescrito con éxito y Cues calculados.",
    );
  }

  Future<void> _fetchAndSaveLrc(String audioPath, String lrcPath) async {
    try {
      final filename = audioPath
          .split(RegExp(r'[\\/]'))
          .last
          .replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '');
      final parts = filename.split(' - ');
      final localSec = await _getLocalDurationSec(audioPath);

      if (parts.length >= 2) {
        final artist = parts[0].trim();
        final originalTrack = parts[1].trim();
        List<String> trackWords = originalTrack.split(' ');

        while (trackWords.isNotEmpty) {
          final currentTrackAttempt = trackWords.join(' ');
          final url =
              'https://lrclib.net/api/search?artist_name=${Uri.encodeComponent(artist)}&track_name=${Uri.encodeComponent(currentTrackAttempt)}';

          try {
            final response = await _resilientGet(url);
            if (response.statusCode == 200) {
              final parsed = jsonDecode(response.body);
              if (parsed is List && parsed.isNotEmpty) {
                parsed.sort((a, b) {
                  final aSync =
                      a['syncedLyrics']?.toString().isNotEmpty ?? false;
                  final bSync =
                      b['syncedLyrics']?.toString().isNotEmpty ?? false;
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

                for (var item in parsed) {
                  final syncedLyrics = item['syncedLyrics'];
                  if (syncedLyrics != null &&
                      syncedLyrics.toString().trim().isNotEmpty) {
                    await File(lrcPath).writeAsString(syncedLyrics);
                    await _processVocalBoundingBox(
                      audioPath,
                      syncedLyrics,
                      localSec,
                    );

                    debugPrint(
                      "🟢 [NLP Tracker] LRC consolidado y Bounding Box guardado: $currentTrackAttempt",
                    );
                    return;
                  }
                }
              }
            }
          } catch (e) {
            debugPrint("🟡 [NLP Tracker] Pipeline iterativo evadió error: $e");
          }
          trackWords.removeLast();
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }

      final fallbackUrl =
          'https://lrclib.net/api/search?q=${Uri.encodeComponent(filename)}';
      try {
        final fallbackResponse = await _resilientGet(fallbackUrl);
        if (fallbackResponse.statusCode == 200) {
          final parsed = jsonDecode(fallbackResponse.body);
          if (parsed is List && parsed.isNotEmpty) {
            parsed.sort((a, b) {
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

            for (var item in parsed) {
              final syncedLyrics = item['syncedLyrics'];
              if (syncedLyrics != null &&
                  syncedLyrics.toString().trim().isNotEmpty) {
                await File(lrcPath).writeAsString(syncedLyrics);
                await _processVocalBoundingBox(
                  audioPath,
                  syncedLyrics,
                  localSec,
                );

                debugPrint(
                  "🟢 [NLP Tracker] LRC y Bounding Box salvados vía Failsafe Delta.",
                );
                return;
              }
            }
          }
        }
      } catch (e) {
        debugPrint("🟡 [NLP Tracker] Failsafe evadió error: $e");
      }
    } catch (e) {
      debugPrint("🔴 [NLP Tracker] Excepción crítica de I/O: $e");
    }
  }

  Future<void> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || Platform.isAndroid || Platform.isIOS) {
      return;
    }

    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final content = await lrcFile.readAsString();
        if (content.contains('Letra no encontrada') ||
            content.contains('Error de conexión') ||
            content.contains('Error Auto-Healing') ||
            lrcFile.lengthSync() <= 20) {
          debugPrint(
            "♻️ [NLP Auto-Healing] Letra residual/inválida detectada. Purgando para reintento: $lrcPath",
          );
          await lrcFile.delete();
        } else {
          return;
        }
      } catch (e) {
        debugPrint(
          "⚠️ [NLP I/O] Imposible leer .lrc existente, forzando purga: $e",
        );
        await lrcFile.delete();
      }
    }

    try {
      await _fetchAndSaveLrc(filePath, lrcPath);
    } catch (e) {
      debugPrint("🔴 [NLP Scraper Fatal Error]: $e");
      if (!lrcFile.existsSync()) {
        await lrcFile.writeAsString("[00:00.00] Letra no encontrada\n");
      }
    }
  }
}
