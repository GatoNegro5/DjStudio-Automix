import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pipeline_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:gatomix/src/rust/api/core_dsp.dart' as rust_dsp;
import '../core/lrc_timeline.dart';
import '../core/lyric_match.dart';
import '../services/id3_title_artist.dart';
import 'db_provider.dart'; // 🛠️ Requerido para inyectar Cues a la BD

bool _enCarpetaOriginal(String path) {
  final String p = path.replaceAll('\\', '/').toLowerCase();
  return p.contains('/.gatomix_original/') || p.endsWith('/.gatomix_original');
}

final nlpWorkerProvider = Provider((ref) => NlpWorker(ref));

class NlpWorker {
  final Ref ref;

  final Map<String, String> _headers = {
    'User-Agent': 'GatoMixPlayer/1.0.0 (Custom Build)',
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
        // 429 / 503 / 5xx: reintento. No es "no hay letra".
        if (res.statusCode == 429 || res.statusCode == 503 || res.statusCode >= 500) {
          if (attempt == maxRetries - 1) {
            return res;
          }

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
            "🟡 [NLP] LRCLIB no respondió tras $maxRetries intentos: $e",
          );
          break;
        }
        await Future.delayed(
          Duration(milliseconds: baseDelayMs * (1 << attempt)),
        );
      }
    }

    throw Exception('LRCLIB no responde');
  }

  /// Último detalle para mostrarlo en pantalla (servidor caído, sin coincidencia).
  String lastDetail = '';

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
        .where((f) => !_enCarpetaOriginal(f.path))
        .toList();

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [NLP Worker] Scraping abortado por el usuario.");
        break;
      }

      final file = files[i];
      if (_enCarpetaOriginal(file.path)) continue;
      final filename = file.uri.pathSegments.last;

      final lrcPath = file.path.replaceAll(
        RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
        '.lrc',
      );
      final lrcFile = File(lrcPath);

      if (lrcFile.existsSync()) {
        final content = await lrcFile.readAsString();
        if (lrcIsProtected(content)) continue;
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

  // Duración EXACTA con Rust (sin ffprobe), igual en las 4 plataformas.
  Future<int> _getLocalDurationSec(String filePath) async {
    try {
      final ms = await rust_dsp.exactDurationMs(inputPath: filePath);
      return (ms.toInt() / 1000).round();
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
    await _unmarkAuto(lrcPath); // letra fijada a mano: ya no es automática

    // Inyectar el Bounding Box al forzar letra manual
    final localSec = await _getLocalDurationSec(audioPath);
    await _processVocalBoundingBox(audioPath, syncedLyrics, localSec);

    debugPrint(
      "🟢 [NLP Tracker] LRC manual sobreescrito con éxito y Cues calculados.",
    );
  }

  // ----------------------------------------------------- coincidencia segura
  // Una letra equivocada es peor que ninguna. ID3 primero; si no, el nombre
  // del archivo. LRCLIB /api/get con la duración medida y, si no hay, /api/search
  // filtrado por artista, título y ±2 s. La misma función la usa Automix.

  Future<({List<dynamic> items, bool serverDown})> _lrclibSearch(String url) async {
    try {
      final response = await _resilientGet(url);
      if (response.statusCode == 200) {
        final parsed = jsonDecode(response.body);
        if (parsed is List) return (items: parsed, serverDown: false);
        return (items: const [], serverDown: false);
      }
      if (response.statusCode == 429 ||
          response.statusCode == 503 ||
          response.statusCode >= 500) {
        lastDetail = 'LRCLIB respondió HTTP ${response.statusCode}';
        return (items: const [], serverDown: true);
      }
    } catch (e) {
      lastDetail = 'LRCLIB no responde: $e';
      debugPrint("🟡 [NLP Tracker] Búsqueda evadió error: $e");
      return (items: const [], serverDown: true);
    }
    return (items: const [], serverDown: false);
  }

  /// La misma búsqueda que Automix. No escribe el archivo.
  Future<LyricChoice> lookupSafeLyric(String audioPath) async {
    final id3 = await loadId3TitleArtist(audioPath);
    final int localSec = await _getLocalDurationSec(audioPath);
    final LyricIdentity id = lyricIdentity(
      path: audioPath,
      id3Artist: id3.artist,
      id3Title: id3.title,
      id3Album: id3.album,
      durationSec: localSec,
    );
    if (id.artist.isEmpty || id.title.isEmpty || localSec <= 0) {
      lastDetail = 'Sin coincidencia segura';
      return const LyricChoice.none();
    }

    Map<String, dynamic>? direct;
    var serverDown = false;
    try {
      final response = await _resilientGet(lrclibGetUri(id).toString());
      if (response.statusCode == 200) {
        final parsed = jsonDecode(response.body);
        if (parsed is Map) direct = Map<String, dynamic>.from(parsed);
      } else if (response.statusCode == 429 ||
          response.statusCode == 503 ||
          response.statusCode >= 500) {
        serverDown = true;
        lastDetail = 'LRCLIB respondió HTTP ${response.statusCode}';
      }
    } catch (e) {
      serverDown = true;
      lastDetail = 'LRCLIB no responde: $e';
    }

    final LyricChoice fromGet = chooseLrclibLyric(id, direct: direct);
    if (fromGet.kind == LyricKind.synced) return fromGet;

    final found = await _lrclibSearch(lrclibSearchUri(id).toString());
    if (found.serverDown) serverDown = true;
    final LyricChoice choice = chooseLrclibLyric(
      id,
      direct: direct,
      searched: found.items,
    );
    if (choice.hasText) return choice;
    if (serverDown) {
      lastDetail = lastDetail.isEmpty ? 'Servidor de letras caído' : lastDetail;
      return const LyricChoice.down();
    }
    lastDetail = 'Sin coincidencia segura';
    return const LyricChoice.none();
  }

  /// Letra sincronizada, plana, sin coincidencia, o servidor caído (reintento).
  /// No pisa un `.lrc` que ya existe.
  Future<LyricStatus> _fetchAndSaveLrc(String audioPath, String lrcPath) async {
    if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) {
      return LyricStatus.kept;
    }
    try {
      final LyricChoice choice = await lookupSafeLyric(audioPath);
      if (!lyricMayDownload(lrcExists: File(lrcPath).existsSync())) {
        return LyricStatus.kept;
      }
      if (choice.kind == LyricKind.synced) {
        await File(lrcPath).writeAsString(choice.fileText);
        await _markAuto(lrcPath);
        final int localSec = await _getLocalDurationSec(audioPath);
        await _processVocalBoundingBox(audioPath, choice.body, localSec);
        lastDetail = '';
        debugPrint("🟢 [NLP Tracker] Letra segura: $audioPath");
        return LyricStatus.ok;
      }
      if (choice.kind == LyricKind.plain) {
        await File(lrcPath).writeAsString(choice.fileText);
        await _markAuto(lrcPath);
        lastDetail = 'Letra plana (sin tiempos)';
        return LyricStatus.plain;
      }
      if (choice.serverDown) {
        debugPrint("🟡 [NLP Tracker] Servidor caído, se reintenta: $audioPath");
        return LyricStatus.retry;
      }
      debugPrint("🟡 [NLP Tracker] Sin coincidencia segura: $audioPath");
      return LyricStatus.noMatch;
    } catch (e) {
      lastDetail = '$e';
      debugPrint("🔴 [NLP Tracker] Excepción crítica de I/O: $e");
      final String msg = e.toString();
      if (msg.contains('LRCLIB') ||
          msg.contains('Socket') ||
          msg.contains('Timeout') ||
          msg.contains('ClientException')) {
        return LyricStatus.retry;
      }
      return LyricStatus.failed;
    }
  }

  // ------------------------------------------- registro de letras AUTOMÁTICAS
  // Solo las letras que descargó esta app se anotan aquí. Las que tú arreglaste
  // (o cualquier .lrc que no esté en la lista) nunca se tocan ni se borran.

  File _autoRegistry(String folder) =>
      File('$folder${Platform.pathSeparator}_lyrics_auto.json');

  Map<String, dynamic> _readAuto(String folder) {
    try {
      final f = _autoRegistry(folder);
      if (f.existsSync()) {
        final d = jsonDecode(f.readAsStringSync());
        if (d is Map<String, dynamic>) return d;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _markAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      reg[f.uri.pathSegments.last] = f.lengthSync();
      await _autoRegistry(folder).writeAsString(jsonEncode(reg));
    } catch (_) {}
  }

  Future<void> _unmarkAuto(String lrcPath) async {
    try {
      final f = File(lrcPath);
      final folder = f.parent.path;
      final reg = _readAuto(folder);
      if (reg.remove(f.uri.pathSegments.last) != null) {
        await _autoRegistry(folder).writeAsString(jsonEncode(reg));
      }
    } catch (_) {}
  }

  /// RESET DE LETRAS: borra solo los .lrc descargados por la app que siguen
  /// SIN cambios (mismo tamaño). Nunca borra una letra fija o editada.
  /// Devuelve cuántas borró.
  Future<int> resetAutoLyrics(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return 0;
    int removed = 0;
    final folders = <String>{directoryPath};
    try {
      for (final e in dir.listSync(recursive: true)) {
        if (e is Directory) folders.add(e.path);
      }
    } catch (_) {}
    for (final folder in folders) {
      if (isCancelled != null && isCancelled()) break;
      if (_enCarpetaOriginal(folder)) continue;
      final reg = _readAuto(folder);
      if (reg.isEmpty) continue;
      final keep = <String, dynamic>{};
      reg.forEach((name, size) {
        final f = File('$folder${Platform.pathSeparator}$name');
        try {
          if (f.existsSync() && f.lengthSync() == (size as num).toInt()) {
            final String text = f.readAsStringSync();
            if (lrcIsProtected(text)) {
              keep[name] = size;
            } else {
              f.deleteSync();
              removed++;
            }
          } else if (f.existsSync()) {
            keep[name] = size; // editada: ya no es automática, se respeta
          }
        } catch (_) {
          keep[name] = size;
        }
      });
      try {
        if (keep.isEmpty) {
          _autoRegistry(folder).deleteSync();
        } else {
          _autoRegistry(folder).writeAsStringSync(jsonEncode(keep));
        }
      } catch (_) {}
    }
    return removed;
  }

  /// Resultado de intentar la letra de una pista.
  /// ok = letra nueva · kept = ya tenía una letra válida (no se toca) ·
  /// noMatch = sin coincidencia segura · failed = error / pista inexistente.
  Future<LyricStatus> processSingleFile(String filePath) async {
    if (_enCarpetaOriginal(filePath)) return LyricStatus.kept;
    final file = File(filePath);
    if (!file.existsSync()) return LyricStatus.failed;

    final lrcPath = filePath.replaceAll(
      RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
      '.lrc',
    );
    final lrcFile = File(lrcPath);

    if (lrcFile.existsSync()) {
      try {
        final content = await lrcFile.readAsString();
        if (lrcIsProtected(content)) {
          return LyricStatus.kept;
        }
        if (content.contains('Letra no encontrada') ||
            content.contains('Error de conexión') ||
            content.contains('Error Auto-Healing') ||
            lrcFile.lengthSync() <= 20) {
          debugPrint(
            "♻️ [NLP Auto-Healing] Letra residual/inválida detectada. Purgando para reintento: $lrcPath",
          );
          await lrcFile.delete();
        } else {
          // Letra válida (descargada o arreglada por Gabriel): INTOCABLE.
          return LyricStatus.kept;
        }
      } catch (e) {
        debugPrint(
          "⚠️ [NLP I/O] Imposible leer .lrc existente, no se toca: $e",
        );
        return LyricStatus.failed;
      }
    }

    try {
      return await _fetchAndSaveLrc(filePath, lrcPath);
    } catch (e) {
      debugPrint("🔴 [NLP Scraper Fatal Error]: $e");
      return LyricStatus.failed;
    }
  }

  /// Descarga las letras de una carpeta y devuelve el conteo por resultado.
  Future<Map<LyricStatus, int>> downloadForDirectory(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final counts = <LyricStatus, int>{for (final s in LyricStatus.values) s: 0};
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return counts;
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) {
          if (_enCarpetaOriginal(f.path)) return false;
          final p = f.path.toLowerCase();
          return p.endsWith('.mp3') && !p.endsWith('_k.mp3');
        })
        .toList();
    final pipe = ref.read(pipelineProvider.notifier);
    final total = files.length;
    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) break;
      final f = files[i];
      if (_enCarpetaOriginal(f.path)) continue;
      final name = f.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, name, "📝 Letras");
      // Mix pesado (> 16 MB): no tiene letra.
      if (f.lengthSync() / (1024 * 1024) > 16.0) {
        counts[LyricStatus.kept] = counts[LyricStatus.kept]! + 1;
        continue;
      }
      final st = await processSingleFile(f.path);
      counts[st] = counts[st]! + 1;
      await Future.delayed(const Duration(milliseconds: 150));
    }
    return counts;
  }
}

enum LyricStatus { ok, kept, noMatch, failed, retry, plain }
