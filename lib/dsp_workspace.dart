import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

import 'providers/directory_provider.dart';
import 'providers/pipeline_provider.dart';
import 'providers/metadata_provider.dart';
import 'providers/nlp_provider.dart';
import 'providers/dsp_provider.dart';
import 'providers/db_provider.dart';

class DspNlpWorkspace extends ConsumerWidget {
  const DspNlpWorkspace({super.key});

  void _showSummaryDialog(
    BuildContext context,
    String title,
    int total,
    List<String> failedTracks, {
    bool isAborted = false,
    int current = 0,
  }) {
    final int processed = isAborted ? current : (total - failedTracks.length);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: isAborted ? Colors.orangeAccent : const Color(0xFF39FF14),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Row(
          children: [
            Icon(
              isAborted ? Icons.warning_amber_rounded : Icons.fact_check,
              color: isAborted ? Colors.orangeAccent : const Color(0xFF39FF14),
            ),
            const SizedBox(width: 10),
            Text(
              isAborted ? "Operación Abortada: $title" : "Reporte: $title",
              style: TextStyle(
                color: isAborted
                    ? Colors.orangeAccent
                    : const Color(0xFF39FF14),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: failedTracks.isEmpty ? 100 : 300,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isAborted
                    ? "⚠️ Proceso detenido en la pista: $processed / $total"
                    : "✅ Procesados con éxito: $processed / $total",
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              if (failedTracks.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text(
                  "❌ Archivos con error o saltados (Cuarentena):",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 5),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      border: Border.all(color: Colors.white10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView.builder(
                      itemCount: failedTracks.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: Text(
                            "• ${failedTracks[index]}",
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontFamily: 'Consolas',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: isAborted
                  ? Colors.orangeAccent
                  : const Color(0xFF39FF14),
              foregroundColor: Colors.black,
            ),
            child: const Text(
              "Entendido",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------
  // 🛠️ MÓDULO DE TELEMETRÍA Y COMPENSACIÓN VECTORIAL
  // ---------------------------------------------------------
  String _getFfprobePath() {
    if (Platform.isAndroid || Platform.isIOS) return 'ffprobe';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final localPath = Platform.isWindows
        ? '$exeDir\\ffprobe.exe'
        : '$exeDir/ffprobe';
    return File(localPath).existsSync() ? localPath : 'ffprobe';
  }

  Future<int> _getAudioDurationMs(String path) async {
    try {
      final result = await Process.run(_getFfprobePath(), [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        path,
      ]);
      final durationSec =
          double.tryParse(result.stdout.toString().trim()) ?? 0.0;
      return (durationSec * 1000).toInt();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _offsetLrcTimeline(String lrcPath, int trimmedMs) async {
    final file = File(lrcPath);
    if (!file.existsSync() || trimmedMs <= 0) return;

    try {
      final lines = await file.readAsLines();
      final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
      final newLines = <String>[];

      for (var line in lines) {
        final match = regex.firstMatch(line);
        if (match != null) {
          final min = int.parse(match.group(1)!);
          final sec = int.parse(match.group(2)!);
          int ms = int.parse(match.group(3)!);
          if (match.group(3)!.length == 2) ms *= 10;

          int totalMs = (min * 60000) + (sec * 1000) + ms - trimmedMs;
          if (totalMs < 0) totalMs = 0;

          final newMin = (totalMs ~/ 60000).toString().padLeft(2, '0');
          final newSec = ((totalMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final newMs = ((totalMs % 1000) ~/ 10).toString().padLeft(2, '0');
          final text = match.group(4)!;

          newLines.add('[$newMin:$newSec.$newMs]$text');
        } else {
          newLines.add(line);
        }
      }
      await file.writeAsString(newLines.join('\n'));
    } catch (_) {}
  }

  // 🛠️ MOTOR UNIVERSAL (AOT Cues + Vector Compensation + Mobile Bypass)
  Future<void> _executeUniversalPipeline(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    ref.read(directoryProvider.notifier).scanPath(targetPath);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    final bool isMobileOS =
        Platform.isAndroid || Platform.isIOS; // 🛡️ SENSOR DE KERNEL

    final Map<String, Map<String, dynamic>> mixProfiles = {
      'reggaeton': {'curve': 'eq_kill', 'durationMs': 4000},
      'salsa': {'curve': 'sharp', 'durationMs': 2000},
      'merengue': {'curve': 'sharp', 'durationMs': 2500},
      'balada': {'curve': 'linear', 'durationMs': 8000},
      'rock': {'curve': 'constant_power', 'durationMs': 3500},
      'cumbia': {'curve': 'constant_power', 'durationMs': 3000},
      'electro': {'curve': 'eq_kill', 'durationMs': 7000},
      'latin': {'curve': 'constant_power', 'durationMs': 4500},
      'pop': {'curve': 'constant_power', 'durationMs': 4000},
    };

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) return;

      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) =>
                f.path.toLowerCase().endsWith('.mp3') ||
                f.path.toLowerCase().endsWith('.webm'),
          )
          .toList();

      int total = files.length;
      if (total == 0) return;

      for (int i = 0; i < total; i++) {
        if (checkAbort()) break;

        final file = files[i];
        final originalName = file.uri.pathSegments.last;
        String currentPath = file.path;

        try {
          // 1. Metadata
          pipe.updateProgress(
            i + 1,
            total,
            originalName,
            "⚙️ Nomenclatura y Regex...",
          );
          currentPath = await ref
              .read(metadataWorkerProvider)
              .processSingleFile(currentPath);
          if (checkAbort()) break;

          final cleanName = currentPath.split(Platform.pathSeparator).last;
          int durationAfterMs = 0;

          // 2 & 3. DSP C++ y Sello (Aislado para Desktop)
          if (!isMobileOS) {
            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "🔊 Masterizando Audio (C++)",
            );
            final durationBeforeMs = await _getAudioDurationMs(currentPath);

            await ref
                .read(dspWorkerProvider)
                .processSingleFile(currentPath)
                .timeout(
                  const Duration(seconds: 45),
                  onTimeout: () => throw Exception(
                    "C++ Deadlock: Excedido límite de I/O en Masterización.",
                  ),
                );
            if (checkAbort()) break;

            durationAfterMs = await _getAudioDurationMs(currentPath);
            final trimmedMs = durationBeforeMs - durationAfterMs;
            if (trimmedMs > 50) {
              final lrcFileToPatch = currentPath.replaceAll(
                RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
                '.lrc',
              );
              await _offsetLrcTimeline(lrcFileToPatch, trimmedMs);
            }

            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "🔐 Sellando Watermark",
            );
            await rust_dsp
                .injectWatermark(inputPath: currentPath)
                .timeout(
                  const Duration(seconds: 15),
                  onTimeout: () => throw Exception(
                    "C++ Deadlock: Excedido límite de I/O inyectando ID3v2.",
                  ),
                );
            if (checkAbort()) break;
          } else {
            // 🛡️ BYPASS MÓVIL
            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "⏭️ Bypass I/O (Plataforma Móvil)",
            );
            await Future.delayed(const Duration(milliseconds: 50));
          }

          final finalName = currentPath.split(Platform.pathSeparator).last;

          // 4. NLP Letras (Soportado en Móvil vía HTTP)
          pipe.updateProgress(
            i + 1,
            total,
            finalName,
            "📝 Scraping de Letras (NLP)",
          );
          await ref
              .read(nlpWorkerProvider)
              .processSingleFile(currentPath)
              .timeout(
                const Duration(seconds: 20),
                onTimeout: () =>
                    throw Exception("NLP Timeout: El scraper colapsó."),
              );
          if (checkAbort()) break;

          // 5. Asignando Curvas (Lectura ID3 aislada en Móvil)
          String rawGenre = 'desconocido';
          if (!isMobileOS) {
            pipe.updateProgress(
              i + 1,
              total,
              finalName,
              "🎛️ Asignando Curvas ISAR",
            );
            rawGenre = await rust_dsp.readAudioGenre(inputPath: currentPath);
          }

          String assignedProfile = 'constant_power';
          int assignedDuration = 6000;
          if (rawGenre.isNotEmpty && rawGenre != 'desconocido') {
            for (final key in mixProfiles.keys) {
              if (rawGenre.contains(key)) {
                assignedProfile = mixProfiles[key]!['curve'] as String;
                assignedDuration = mixProfiles[key]!['durationMs'] as int;
                break;
              }
            }
          }

          // 6. Cues Estructurales (Motor Heurístico 2.0 Blindado)
          pipe.updateProgress(
            i + 1,
            total,
            finalName,
            "🎯 Calculando Puntos Estructurales...",
          );
          final existingMeta = await ref
              .read(dbServiceProvider)
              .getTrackMetadata(currentPath);

          int? calculatedCueIn;
          int? calculatedMixOut;

          final isManual = existingMeta?.isManualCue ?? false;

          if (!isManual) {
            final lrcFile = File(
              currentPath.replaceAll(
                RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
                '.lrc',
              ),
            );

            if (lrcFile.existsSync()) {
              try {
                final lines = await lrcFile.readAsLines();
                final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
                int firstVocalMs = -1;
                int lastVocalMs = -1;

                for (var line in lines) {
                  final match = regex.firstMatch(line);
                  if (match != null) {
                    final text = match.group(4)!.trim().toLowerCase();
                    bool isGarbage = false;

                    if (text.length < 3 ||
                        text.contains('🎵') ||
                        text.contains('♪') ||
                        text.startsWith('(') ||
                        text.startsWith('[')) {
                      isGarbage = true;
                    } else if (text.contains('instrumental') ||
                        text.contains('sync') ||
                        text.contains('lyric') ||
                        text.contains('letra no encontrada') ||
                        text.contains('error') ||
                        text.contains('autor') ||
                        text.contains('sincronizado') ||
                        text.contains('by ') ||
                        text.contains('fuente') ||
                        text.contains(' - ')) {
                      isGarbage = true;
                    }

                    if (!isGarbage) {
                      final min = int.parse(match.group(1)!);
                      final sec = int.parse(match.group(2)!);
                      int ms = int.parse(match.group(3)!);
                      if (match.group(3)!.length == 2) ms *= 10;

                      int currentMs = (min * 60000) + (sec * 1000) + ms;
                      if (firstVocalMs == -1) firstVocalMs = currentMs;
                      lastVocalMs = currentMs;
                    }
                  }
                }

                if (firstVocalMs != -1) {
                  int optimalBuffer = assignedDuration + 2000;
                  calculatedCueIn = (firstVocalMs >= optimalBuffer)
                      ? (firstVocalMs - optimalBuffer)
                      : 0;

                  int idealMixOut = lastVocalMs + 2000;

                  // 🛠️ LIMITADOR GEOMÉTRICO (Requiere duración física. Si es móvil, se salta el bloqueo estricto)
                  if (durationAfterMs > 0 &&
                      (idealMixOut + assignedDuration) > durationAfterMs) {
                    calculatedMixOut =
                        durationAfterMs - assignedDuration - 1000;
                  } else {
                    calculatedMixOut = idealMixOut;
                  }

                  if (calculatedCueIn != null &&
                      calculatedMixOut <= calculatedCueIn) {
                    if (durationAfterMs > 0) {
                      calculatedMixOut =
                          durationAfterMs - assignedDuration - 1000;
                    } else {
                      calculatedMixOut =
                          calculatedCueIn + assignedDuration; // Fallback ciego
                    }
                  }
                  if (calculatedMixOut < 0) {
                    calculatedMixOut = 0;
                  }
                }
              } catch (_) {}
            }
          }

          await ref
              .read(dbServiceProvider)
              .saveTrackMetadata(
                path: currentPath,
                mixProfile: assignedProfile,
                durationMs: assignedDuration,
                genre: rawGenre,
                cueInMs: isManual
                    ? existingMeta!.cueInMs
                    : (calculatedCueIn ?? 0),
                mixOutMs: isManual ? existingMeta!.mixOutMs : calculatedMixOut,
                isManualCue: isManual,
              );
        } catch (e) {
          debugPrint("🔴 Error aislando pista $originalName: $e");
          pipe.addQuarantine(originalName);
        }

        // 🛠️ GC YIELD: Obliga a Dart a pausar medio segundo.
        // Permite al Disco Duro vaciar su caché y previene el congelamiento de la PC.
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (!checkAbort()) {
        pipe.updateProgress(
          total,
          total,
          "Indexando...",
          "🥁 Calculando Caché BPM Global",
        );
        // Symphonia es puro Rust, funciona 100% en Android sin FFmpeg
        await ref.read(dspWorkerProvider).generateStaticBpmCache(targetPath);
      }
    } catch (e) {
      debugPrint("🔴 [PIPELINE ERROR FATAL]: $e");
    } finally {
      if (context.mounted) {
        final state = ref.read(pipelineProvider);
        if (state.total > 0) {
          _showSummaryDialog(
            context,
            "Masterización Universal",
            state.total,
            state.quarantinedTracks,
            isAborted: state.isAborted,
            current: state.current,
          );
        }
        ref.read(directoryProvider.notifier).scanPath(targetPath);
      }
      pipe.reset();
    }
  }

  // 🛠️ PURGA UNIFICADA (Reset de Fábrica)
  Future<void> _executeFactoryReset(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    try {
      pipe.updateProgress(0, 1, "Preparando purga...", "Iniciando Reset...");
      await ref
          .read(dspWorkerProvider)
          .clearPipelineWatermarks(targetPath, isCancelled: checkAbort);

      if (!checkAbort()) {
        await ref
            .read(dspWorkerProvider)
            .clearIsarDspData(targetPath, isCancelled: checkAbort);
      }
    } catch (e) {
      debugPrint("🔴 [FACTORY RESET ERROR]: $e");
    } finally {
      final state = ref.read(pipelineProvider);
      if (context.mounted && state.total > 0) {
        _showSummaryDialog(
          context,
          "Reset de Fábrica (Audio + ISAR)",
          state.total,
          state.quarantinedTracks,
          isAborted: state.isAborted,
          current: state.current,
        );
      }
      pipe.reset();
    }
  }

  void _showQuickFolderMenu(
    BuildContext rootContext,
    WidgetRef ref,
    String currentPath,
  ) {
    Directory baseDir;
    if (currentPath.isNotEmpty) {
      baseDir = Directory(currentPath).parent;
    } else {
      if (Platform.isWindows) {
        baseDir = Directory('${Platform.environment['USERPROFILE']}\\Music');
      } else if (Platform.isMacOS || Platform.isLinux) {
        baseDir = Directory('${Platform.environment['HOME']}/Music');
      } else {
        baseDir = Directory('/storage/emulated/0/Music');
      }
    }

    List<FileSystemEntity> subFolders = [];
    try {
      if (baseDir.existsSync()) {
        subFolders = baseDir.listSync().whereType<Directory>().toList();
        subFolders.sort((a, b) => a.path.compareTo(b.path));
      }
    } catch (e) {
      debugPrint("⚠️ [I/O ERROR]: Permiso denegado al leer $baseDir");
    }

    showDialog(
      context: rootContext,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFFF007F)),
          ),
          title: const Text(
            "Selección Rápida (Auto-Pipeline)",
            style: TextStyle(
              color: Color(0xFFFF007F),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 500,
            height: 400,
            child: subFolders.isEmpty
                ? const Text(
                    "No se encontraron subcarpetas o faltan permisos de almacenamiento.",
                    style: TextStyle(color: Colors.white54),
                  )
                : ListView.builder(
                    itemCount: subFolders.length,
                    itemBuilder: (context, index) {
                      final folder = subFolders[index];
                      final folderName = folder.path
                          .split(Platform.pathSeparator)
                          .last;
                      return ListTile(
                        leading: const Icon(
                          Icons.folder_special,
                          color: Color(0xFF39FF14),
                        ),
                        title: Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          folder.path,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        hoverColor: Colors.white10,
                        onTap: () {
                          Navigator.pop(context);
                          _executeUniversalPipeline(
                            rootContext,
                            ref,
                            folder.path,
                          );
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Abortar",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                ref.read(directoryProvider.notifier).loadDirectory();
              },
              child: const Text(
                "Usar Explorador de Sistema",
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final pipeState = ref.watch(pipelineProvider);
    final bool isBusy = !pipeState.isIdle;

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;

        final Widget directoryPanel = Container(
          padding: EdgeInsets.all(isMobileLandscape ? 10 : 15),
          decoration: BoxDecoration(
            color: Colors.black45,
            border: Border.all(
              color: pipeState.isAborted
                  ? Colors.redAccent
                  : const Color(0xFFFF007F),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_open,
                color: pipeState.isAborted
                    ? Colors.redAccent
                    : const Color(0xFFFF007F),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Directorio Objetivo:",
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      dirState.currentPath.isEmpty
                          ? "NINGUNA CARPETA SELECCIONADA"
                          : dirState.currentPath,
                      style: TextStyle(
                        color: dirState.currentPath.isEmpty
                            ? Colors.redAccent
                            : (pipeState.isAborted
                                  ? Colors.redAccent
                                  : const Color(0xFFFF007F)),
                        fontFamily: 'Consolas',
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ],
                ),
              ),
              if (!isBusy)
                ElevatedButton.icon(
                  onPressed: () =>
                      _showQuickFolderMenu(context, ref, dirState.currentPath),
                  icon: const Icon(Icons.flash_on),
                  label: const Text("Explorar"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    foregroundColor: const Color(0xFF39FF14),
                    side: const BorderSide(color: Color(0xFF39FF14)),
                  ),
                ),
              if (isBusy)
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              "[${pipeState.current}/${pipeState.total}] ${pipeState.moduleStatus}",
                              style: TextStyle(
                                color: pipeState.isAborted
                                    ? Colors.orangeAccent
                                    : const Color(0xFF39FF14),
                                fontFamily: 'Consolas',
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 5),
                            LinearProgressIndicator(
                              value: pipeState.total == 0
                                  ? 0
                                  : pipeState.current / pipeState.total,
                              backgroundColor: Colors.white10,
                              color: pipeState.isAborted
                                  ? Colors.orangeAccent
                                  : const Color(0xFF39FF14),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 15),
                      IconButton(
                        onPressed: pipeState.isAborted
                            ? null
                            : () => ref.read(pipelineProvider.notifier).abort(),
                        icon: const Icon(
                          Icons.cancel,
                          color: Colors.redAccent,
                          size: 35,
                        ),
                        tooltip: "Freno de Emergencia",
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );

        // 🛠️ ARQUITECTURA DE TARJETAS (Híbrida: Row para Desktop, ListView Horizontal para Móvil)
        final List<Widget> cardNodes = [
          _buildActionCard(
            title: "MASTERIZACIÓN GLOBAL",
            description:
                "Pipeline atómico. Optimiza audio, extrae semántica y asigna curvas.",
            icon: Icons.rocket_launch,
            color: const Color(0xFF39FF14),
            isPrimary: true,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () => _executeUniversalPipeline(
                    context,
                    ref,
                    dirState.currentPath,
                  ),
          ),
          _buildActionCard(
            title: "INFORME DE AUDITORÍA",
            description:
                "Identifica cuellos de botella: faltantes de letras, BPMs o errores de volumen.",
            icon: Icons.analytics_outlined,
            color: Colors.cyanAccent,
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () => _executeAuditReport(context, ref, dirState.currentPath),
          ),
          _buildActionCard(
            title: "RESET DE FÁBRICA",
            description: "Destruye firmas ID3v2 y purga la Base de Datos ISAR.",
            icon: Icons.dangerous,
            color: Colors.redAccent,
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () =>
                      _executeFactoryReset(context, ref, dirState.currentPath),
          ),
        ];

        if (isMobileLandscape) {
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(15.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Laboratorio de Masterización Automática",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF007F),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Centro de control universal. Analiza espectro, normaliza niveles, extrae letras e inyecta BPMs de forma desatendida.",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 20),
                directoryPanel,
                const SizedBox(height: 20),
                SizedBox(
                  height: 200, // Alto fijo para carrusel
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: cardNodes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 15),
                    itemBuilder: (_, i) => SizedBox(
                      width:
                          240, // Ancho fijo estricto para evitar asfixia horizontal
                      child: cardNodes[i],
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Laboratorio de Masterización Automática",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFF007F),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Centro de control universal. Analiza espectro, normaliza niveles, extrae letras e inyecta BPMs de forma desatendida.",
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 30),
              directoryPanel,
              const SizedBox(height: 30),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: cardNodes[0]),
                    const SizedBox(width: 15),
                    Expanded(flex: 2, child: cardNodes[1]),
                    const SizedBox(width: 15),
                    Expanded(flex: 2, child: cardNodes[2]),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required bool isPrimary,
    VoidCallback? onTap,
  }) {
    final bool isDisabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      splashColor: color.withValues(alpha: 0.3),
      highlightColor: color.withValues(alpha: 0.1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDisabled
                ? [const Color(0xFF1A1A1A), const Color(0xFF121212)]
                : [
                    color.withValues(alpha: isPrimary ? 0.15 : 0.08),
                    const Color(0xFF121212),
                  ],
          ),
          border: Border.all(
            color: isDisabled ? Colors.white10 : color.withValues(alpha: 0.5),
            width: isPrimary ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: isDisabled
              ? []
              : [
                  BoxShadow(
                    color: color.withValues(alpha: isPrimary ? 0.25 : 0.1),
                    blurRadius: 20,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        // 🛠️ INMUNIZACIÓN: Scroll interno evita desbordes matemáticos si la caja se contrae
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDisabled
                      ? Colors.white10
                      : color.withValues(alpha: 0.1),
                  boxShadow: isDisabled
                      ? []
                      : [
                          BoxShadow(
                            color: color.withValues(alpha: 0.4),
                            blurRadius: 15,
                            spreadRadius: 2,
                          ),
                        ],
                ),
                child: Icon(
                  icon,
                  size: isPrimary ? 40 : 25,
                  color: isDisabled ? Colors.white24 : color,
                ),
              ),
              const SizedBox(height: 15),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isPrimary ? 14 : 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: isDisabled ? Colors.white38 : Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: isDisabled ? Colors.white24 : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportAuditToCSV(
    BuildContext context,
    String targetPath,
    List<String> unsealed,
    List<String> noLyrics,
    List<String> noBpm,
    List<String> noCues,
  ) async {
    try {
      final file = File(
        '$targetPath${Platform.pathSeparator}Auditoria_DataHealth.csv',
      );
      final buffer = StringBuffer();
      buffer.writeln("ANOMALÍA;ARCHIVO");

      for (final track in unsealed) {
        buffer.writeln("Sin Audio DSP (Sello Faltante);$track");
      }
      for (final track in noLyrics) {
        buffer.writeln("NLP Fallido (Sin Letra);$track");
      }
      for (final track in noBpm) {
        buffer.writeln("Sin BPM o Curva (Fallo de Caché);$track");
      }
      for (final track in noCues) {
        buffer.writeln("Cues Estructurales Faltantes;$track");
      }

      await file.writeAsString(buffer.toString());

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ Reporte exportado exitosamente a CSV: ${file.path}",
            ),
            backgroundColor: const Color(0xFF39FF14),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O al exportar CSV: $e");
    }
  }

  Future<void> _sendToLab(
    BuildContext context,
    String targetPath,
    Set<String> badPaths,
  ) async {
    if (badPaths.isEmpty) return;

    // Crear carpeta LAB al mismo nivel que las carpetas de música
    final baseDir = Directory(targetPath).parent;
    final labDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}DjStudio_LAB',
    );
    if (!labDir.existsSync()) labDir.createSync(recursive: true);

    final registryFile = File(
      '${labDir.path}${Platform.pathSeparator}quarantine_registry.json',
    );
    Map<String, dynamic> registry = {};
    if (registryFile.existsSync()) {
      try {
        registry = jsonDecode(registryFile.readAsStringSync());
      } catch (_) {}
    }

    int movedCount = 0;
    for (String path in badPaths) {
      final file = File(path);
      if (file.existsSync()) {
        final fileName = file.uri.pathSegments.last;
        final newPath = '${labDir.path}${Platform.pathSeparator}$fileName';

        try {
          file.renameSync(newPath); // Movimiento físico atómico
          registry[fileName] = path; // Guardamos el origen

          // Mover también el .lrc si existe
          final lrcFile = File(
            path.replaceAll(
              RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
              '.lrc',
            ),
          );
          if (lrcFile.existsSync()) {
            lrcFile.renameSync(
              '${labDir.path}${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
            );
          }
          movedCount++;
        } catch (e) {
          debugPrint("🔴 Error moviendo archivo al LAB: $e");
        }
      }
    }

    registryFile.writeAsStringSync(jsonEncode(registry));

    if (context.mounted) {
      Navigator.pop(context); // Cierra el modal de auditoría
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✅ $movedCount archivos aislados en el LAB."),
          backgroundColor: Colors.orangeAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showAuditDialog(
    BuildContext context,
    String targetPath,
    int total,
    List<String> unsealed,
    List<String> noLyrics,
    List<String> noBpm,
    List<String> noCues,
  ) {
    // Consolidar todos los paths defectuosos en un Set único
    final Set<String> allBadPaths = {};
    allBadPaths.addAll(unsealed);
    allBadPaths.addAll(noLyrics);
    allBadPaths.addAll(noBpm);
    allBadPaths.addAll(noCues);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.cyanAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Row(
          children: [
            const Icon(Icons.analytics, color: Colors.cyanAccent),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                "Auditoría de Salud (Data Health)",
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.file_download, color: Color(0xFF39FF14)),
              tooltip: "Exportar a CSV",
              onPressed: () => _exportAuditToCSV(
                ctx,
                targetPath,
                unsealed,
                noLyrics,
                noBpm,
                noCues,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 650,
          height: 450,
          child: DefaultTabController(
            length: 4,
            child: Column(
              children: [
                Text(
                  "Pistas analizadas: $total",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                const TabBar(
                  indicatorColor: Colors.cyanAccent,
                  labelColor: Colors.cyanAccent,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: TextStyle(fontSize: 11),
                  tabs: [
                    Tab(text: "Audio Crudo"),
                    Tab(text: "Sin Letras"),
                    Tab(text: "Falta BPM/Curva"),
                    Tab(text: "Sin Cues"),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildAuditList(
                        unsealed,
                        "Archivos sin procesar por DSP (Sin sello ID3v2)",
                      ),
                      _buildAuditList(
                        noLyrics,
                        "Archivos sin .lrc válido asociado",
                      ),
                      _buildAuditList(
                        noBpm,
                        "Pistas no indexadas en caché de mezcla",
                      ),
                      _buildAuditList(
                        noCues,
                        "Sin CuePoints en ISAR (Instrumental o error de lectura)",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (allBadPaths.isNotEmpty)
            ElevatedButton.icon(
              onPressed: () => _sendToLab(ctx, targetPath, allBadPaths),
              icon: const Icon(Icons.science),
              label: Text("Extraer al LAB (${allBadPaths.length})"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent,
                foregroundColor: Colors.black,
              ),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text(
              "Cerrar",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuditList(List<String> items, String description) {
    if (items.isEmpty) {
      return const Center(
        child: Text(
          "✅ Todo en orden. 0 anomalías detectadas.",
          style: TextStyle(color: Color(0xFF39FF14)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Text(
            description,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black45,
              border: Border.all(color: Colors.white10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                // Parseo visual: Solo muestra el nombre, pero la lista interna guarda el Path absoluto
                final displayPath = items[index]
                    .split(Platform.pathSeparator)
                    .last;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    "• $displayPath",
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontFamily: 'Consolas',
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _executeAuditReport(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    final pipe = ref.read(pipelineProvider.notifier);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    // 🛠️ CAMBIO ESTRUCTURAL: Ahora almacenamos el PATH absoluto, no solo el filename, para poder moverlos al LAB.
    List<String> unsealedTracks = [];
    List<String> noLyricsTracks = [];
    List<String> noBpmTracks = [];
    List<String> noCuesTracks = [];

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) return;

      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mp3'))
          .toList();

      int total = files.length;
      if (total == 0) return;

      Map<String, dynamic> metadataCache = {};
      final cacheFile = File(
        '$targetPath${Platform.pathSeparator}_dj_metadata.json',
      );
      if (cacheFile.existsSync()) {
        try {
          metadataCache = jsonDecode(await cacheFile.readAsString());
        } catch (_) {}
      }

      for (int i = 0; i < total; i++) {
        if (checkAbort()) break;
        final file = files[i];
        final filename = file.uri.pathSegments.last;
        pipe.updateProgress(i + 1, total, filename, "Auditoría en progreso...");

        bool isSealed = false;
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          final result = await Process.run('ffprobe', [
            '-v',
            'quiet',
            '-show_entries',
            'format_tags=DjStudio_M3_V2',
            '-of',
            'default=noprint_wrappers=1:nokey=1',
            file.path,
          ]);
          isSealed =
              result.stdout.toString().trim().toLowerCase() == 'verified';
        }

        if (!isSealed) unsealedTracks.add(file.path);

        final lrcPath = file.path.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '.lrc',
        );
        final lrcFile = File(lrcPath);
        if (!lrcFile.existsSync()) {
          noLyricsTracks.add(file.path);
        } else {
          final content = await lrcFile.readAsString();
          if (content.contains('Letra no encontrada') ||
              content.contains('Error')) {
            noLyricsTracks.add(file.path);
          }
        }

        final normalizedPath = file.path.replaceAll('\\', '/');
        bool hasBpmCache =
            metadataCache.containsKey(file.path) ||
            metadataCache.containsKey(filename) ||
            metadataCache.containsKey(normalizedPath);

        if (!hasBpmCache) noBpmTracks.add(file.path);

        final meta = await ref
            .read(dbServiceProvider)
            .getTrackMetadata(file.path);
        if (meta == null || meta.cueInMs == null) {
          noCuesTracks.add(file.path);
        }
      }

      if (!checkAbort() && context.mounted) {
        _showAuditDialog(
          context,
          targetPath,
          total,
          unsealedTracks,
          noLyricsTracks,
          noBpmTracks,
          noCuesTracks,
        );
      }
    } catch (e) {
      debugPrint("🔴 [AUDIT ERROR]: $e");
    } finally {
      pipe.reset();
    }
  }
}
