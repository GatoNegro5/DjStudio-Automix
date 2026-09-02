import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
// 🛠️ INYECTADO: Backend FFI Nativo
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;
import 'pipeline_provider.dart';
import 'db_provider.dart'; // 🛠️ FIX: Enlace al controlador de ISAR

final dspWorkerProvider = Provider((ref) => DspWorker(ref));

class DspWorker {
  final Ref ref;
  DspWorker(this.ref);

  // 🛠️ INYECCIÓN ARQUITECTURA: Validación Nativa Ultrarrápida en Dart
  Future<bool> _isWatermarkedFast(String filePath) async {
    try {
      if (Platform.isAndroid || Platform.isIOS) return false;
      final result = await Process.run('ffprobe', [
        '-v',
        'quiet',
        '-show_entries',
        'format_tags=DjStudio_M3_V2',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        filePath,
      ]);
      final output = result.stdout.toString().trim().toLowerCase();
      return output == 'verified';
    } catch (e) {
      return false;
    }
  }

  Future<double> _extractBpmFromID3(String filePath) async {
    try {
      final file = File(filePath);
      final raf = await file.open();
      final header = await raf.read(10);

      if (header.length < 10 ||
          header[0] != 0x49 ||
          header[1] != 0x44 ||
          header[2] != 0x33) {
        await raf.close();
        return 0.0;
      }

      final size =
          (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
      final tagData = await raf.read(size);
      await raf.close();

      for (int i = 0; i < tagData.length - 10; i++) {
        if (tagData[i] == 0x54 &&
            tagData[i + 1] == 0x42 &&
            tagData[i + 2] == 0x50 &&
            tagData[i + 3] == 0x4D) {
          final frameSize =
              (tagData[i + 4] << 24) |
              (tagData[i + 5] << 16) |
              (tagData[i + 6] << 8) |
              tagData[i + 7];
          if (frameSize > 0 && i + 10 + frameSize <= tagData.length) {
            final bpmStringBytes = tagData.sublist(i + 11, i + 10 + frameSize);
            final rawString = String.fromCharCodes(
              bpmStringBytes,
            ).replaceAll(RegExp(r'[^\d.]'), '');
            return double.tryParse(rawString) ?? 0.0;
          }
        }
      }
      return 0.0;
    } catch (e) {
      return 0.0;
    }
  }

  Future<void> generateStaticBpmCache(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final cacheFile = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.json',
    );
    final tempCache = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.tmp',
    );
    final timeFile = File(
      '$directoryPath${Platform.pathSeparator}_dj_timestamps.json',
    );
    final tempTime = File(
      '$directoryPath${Platform.pathSeparator}_dj_timestamps.tmp',
    );

    // 🛠️ UI: Enganchamos el pipeline para ver el análisis espectral en tiempo real
    final pipe = ref.read(pipelineProvider.notifier);

    Map<String, double> cacheData = {};
    Map<String, int> timestamps = {};

    if (cacheFile.existsSync()) {
      try {
        final content = await cacheFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        decoded.forEach((k, v) => cacheData[k] = (v as num).toDouble());
      } catch (_) {}
    }

    if (timeFile.existsSync()) {
      try {
        final content = await timeFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        decoded.forEach((k, v) => timestamps[k] = (v as num).toInt());
      } catch (_) {}
    }

    final files = <File>[];
    try {
      await for (final entity in dir.list(recursive: true).handleError((e) {
        debugPrint("⚠️ [DSP Cache I/O Ignorado]: $e");
      })) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          // 🛠️ REGLA ESTRICTA: Filtrar únicamente MP3
          if (lowerPath.endsWith('.mp3')) {
            files.add(entity);
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [DSP Cache Scan Fatal]: $e");
    }

    bool hasChanges = false;
    int totalFiles = files.length;

    for (var file in files) {
      final filename = file.uri.pathSegments.last;
      final absolutePath = file.path;
      final modified = file.lastModifiedSync().millisecondsSinceEpoch;

      if (!timestamps.containsKey(absolutePath) ||
          timestamps[absolutePath] != modified) {
        // 🛠️ FIX ARQUITECTURA: Bypass automático de BPM para Megamixes (>15MB)
        final double fileSizeMb = file.lengthSync() / (1024 * 1024);
        if (fileSizeMb > 15.0) {
          debugPrint(
            "🟢 [DSP Cache] Megamix detectado (${fileSizeMb.toStringAsFixed(2)}MB). Bypass de BPM aplicado a: $filename",
          );
          timestamps[absolutePath] = modified;
          hasChanges = true;
          continue; // Saltamos la extracción Symphonia/ID3
        }

        debugPrint("⚙️ [DSP Cache] Escaneando binario ID3: $filename");

        // 🛠️ RESPIRACIÓN OBLIGATORIA: Ceder hilo al Garbage Collector
        await Future.delayed(const Duration(milliseconds: 30));

        final bpm = await _extractBpmFromID3(absolutePath);

        if (bpm > 0) {
          cacheData[absolutePath] = bpm;
        } else {
          final match = RegExp(
            r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
            caseSensitive: false,
          ).firstMatch(filename);

          if (match != null) {
            cacheData[absolutePath] = double.parse(match.group(1)!);
          } else {
            // 🛠️ LLAMADA AL NUEVO MOTOR NATIVO: Zero-Touch con Symphonia FFT
            pipe.updateProgress(
              totalFiles,
              totalFiles,
              filename,
              "🧠 Analizando Espectro FFI...",
            );

            try {
              final detectedBpm = await rust_dsp.autoDetectAndInjectBpm(
                inputPath: absolutePath,
              );
              cacheData[absolutePath] = detectedBpm;
              debugPrint(
                "✅ [FFT BPM] Matemático: $detectedBpm BPM -> $filename",
              );
            } catch (e) {
              debugPrint("🔴 [FFT BPM FALLO]: $e -> $filename");
              cacheData[absolutePath] =
                  0.0; // Fallback extremo en caso de archivo corrupto
            }
          }
        }

        timestamps[absolutePath] = modified;
        hasChanges = true;
      }
    }

    if (hasChanges) {
      await tempCache.writeAsString(jsonEncode(cacheData));
      await tempCache.rename(cacheFile.path);

      await tempTime.writeAsString(jsonEncode(timestamps));
      await tempTime.rename(timeFile.path);
      debugPrint("🟢 [DSP Cache] Caché estático actualizado atómicamente.");
    } else {
      debugPrint("🟢 [DSP Cache] Sin cambios físicos. Caché mantenido.");
    }
  }

  Future<void> processEBU(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(directoryPath, "Master LUFS", (
      path, {
      bool isMegamix = false,
    }) async {
      // 🛠️ ENRUTAMIENTO INTELIGENTE: Si es un Megamix, forzamos el pipeline
      // optimizado (1 sola pasada de volumen, usando todos los hilos).
      if (isMegamix) {
        return await rust_dsp.processFullPipeline(
          inputPath: path,
          isMegamix: true,
        );
      }
      // Pistas de tamaño normal usan el cálculo LUFS estricto de doble pasada.
      return await rust_dsp.normalizeLufs(inputPath: path);
    }, isCancelled: isCancelled);
  }

  Future<void> processTrim(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(directoryPath, "DSP Trim", (
      path, {
      bool isMegamix = false,
    }) async {
      // 🛠️ BYPASS ATÓMICO: Un Mix no tiene silencios por definición.
      // Retornamos True al instante y ahorramos 100% de CPU y RAM.
      if (isMegamix) return true;

      return await rust_dsp.processAutoTrim(inputPath: path);
    }, isCancelled: isCancelled);
  }

  Future<void> sealPipeline(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(
      directoryPath,
      "Sello Watermark",
      (path, {bool isMegamix = false}) =>
          rust_dsp.injectWatermark(inputPath: path),
      isCancelled: isCancelled,
      bypassIfWatermarked: false,
    );
  }

  Future<void> clearPipelineWatermarks(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    await _runRustBatch(
      directoryPath,
      "♻️ Reset Watermark",
      (path, {bool isMegamix = false}) =>
          rust_dsp.clearWatermark(inputPath: path),
      isCancelled: isCancelled,
      bypassIfWatermarked: false,
    );
    debugPrint("🟢 [DSP Worker] Sellos físicos eliminados en C++.");
  }

  Future<void> clearIsarDspData(
    String directoryPath, {
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = <File>[];
    try {
      await for (final entity in dir.list(recursive: true).handleError((e) {
        debugPrint("⚠️ [ISAR Purge I/O Ignorado]: $e");
      })) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          // 🛠️ REGLA ESTRICTA: Filtrar únicamente MP3
          if (lowerPath.endsWith('.mp3')) {
            files.add(entity);
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [ISAR Purge Scan Fatal]: $e");
      return;
    }

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) {
        debugPrint("🔴 [DSP Worker] Purga ISAR abortada.");
        break;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;
      pipe.updateProgress(i + 1, total, filename, "🗑️ Purgando DB ISAR");

      try {
        await ref.read(dbServiceProvider).deleteTrackMetadata(file.path);
      } catch (_) {
        pipe.addQuarantine(filename);
        continue;
      }
    }
    debugPrint("🟢 [DSP Worker] Base de datos ISAR purgada exitosamente.");
  }

  Future<void> _runRustBatch(
    String directoryPath,
    String moduleName,
    Future<bool> Function(String, {bool isMegamix}) rustTask, {
    bool Function()? isCancelled,
    bool bypassIfWatermarked = true,
  }) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return;

    final files = <File>[];
    try {
      await for (final entity in dir.list(recursive: true).handleError((e) {
        debugPrint("⚠️ [Rust Batch I/O Ignorado]: $e");
      })) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          if (lowerPath.endsWith('.mp3')) {
            files.add(entity);
          }
        }
      }
    } catch (e) {
      debugPrint("🔴 [Rust Batch Scan Fatal]: $e");
      return;
    }

    int total = files.length;
    final pipe = ref.read(pipelineProvider.notifier);
    final sysCores = Platform.numberOfProcessors;

    for (int i = 0; i < total; i++) {
      if (isCancelled != null && isCancelled()) break;

      bool isLiveActive = ref.read(hardwareGovernorProvider).isLiveDjActive;
      while (isLiveActive) {
        pipe.updateProgress(
          i,
          total,
          "⏸️ SISTEMA EN PAUSA",
          "Protegiendo Live DJ...",
        );
        await Future.delayed(const Duration(seconds: 3));
        isLiveActive = ref.read(hardwareGovernorProvider).isLiveDjActive;
        if (isCancelled != null && isCancelled()) return;
      }

      final file = files[i];
      final filename = file.uri.pathSegments.last;

      try {
        File(
          'C:\\Python\\djstudio_player\\ULTIMA_PISTA.txt',
        ).writeAsStringSync("PISTA ACTUAL:\n${file.path}");
      } catch (_) {}

      pipe.updateProgress(i + 1, total, filename, moduleName);

      try {
        if (bypassIfWatermarked) {
          final hasWatermark = await _isWatermarkedFast(file.path);
          if (hasWatermark) continue;
        }

        // 🛠️ BYPASS ABSOLUTO: Si pesa más de 15MB, saltamos al instante.
        // Cero FFI, Cero Cuarentena.
        final double fileSizeMb = file.lengthSync() / (1024 * 1024);
        if (fileSizeMb > 15.0) {
          debugPrint(
            "⏭️ [BYPASS] Pista ignorada por tamaño (${fileSizeMb.toStringAsFixed(2)}MB): $filename",
          );
          pipe.updateProgress(i + 1, total, filename, "⏭️ Omitido: > 15MB");
          continue;
        }

        final int thermalDelay = sysCores <= 4 ? 1500 : 50;
        await Future.delayed(Duration(milliseconds: thermalDelay));

        // Pistas estándar (< 15MB)
        final success = await rustTask(file.path, isMegamix: false).timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            if (Platform.isWindows) {
              Process.runSync('taskkill', ['/F', '/IM', 'ffmpeg.exe']);
            }
            sleep(const Duration(milliseconds: 1500));
            pipe.updateProgress(i + 1, total, filename, "⚠️ Saltado: Timeout");
            return false;
          },
        );

        if (!success) {
          debugPrint("⚠️ [DSP] Pista ignorada, continúa el bucle.");
        }
      } catch (e) {
        pipe.updateProgress(i + 1, total, "⚠️ Error DSP", moduleName);
      } finally {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<String> processSingleFile(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || Platform.isAndroid || Platform.isIOS) {
      return filePath;
    }

    try {
      final isSealed = await _isWatermarkedFast(filePath);
      if (!isSealed) {
        final double fileSizeMb = file.lengthSync() / (1024 * 1024);
        // 🛠️ BYPASS ABSOLUTO TAMBIÉN EN PISTAS INDIVIDUALES
        if (fileSizeMb > 15.0) return filePath;

        await rust_dsp.processFullPipeline(
          inputPath: filePath,
          isMegamix: false,
        );
      }
    } catch (_) {}

    return filePath;
  }
}
