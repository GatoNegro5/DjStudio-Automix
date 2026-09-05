import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

import '../../providers/directory_provider.dart';
import '../../providers/pipeline_provider.dart';
import '../../providers/metadata_provider.dart';
import '../../providers/nlp_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/db_provider.dart';

// ==========================================
// 🧠 ESTADO GLOBAL DEL MOTOR DE IA
// ==========================================
class AiEngineState {
  final bool isRunning;
  final String status;
  AiEngineState({this.isRunning = false, this.status = ''});
}

class AiEngineNotifier extends StateNotifier<AiEngineState> {
  AiEngineNotifier() : super(AiEngineState());

  void start(String path) {
    state = AiEngineState(isRunning: true, status: 'Iniciando Motor IA...');
  }

  void updateStatus(String status) {
    state = AiEngineState(isRunning: true, status: status);
  }

  void stop() {
    state = AiEngineState(isRunning: false, status: '');
  }
}

final aiEngineProvider = StateNotifierProvider<AiEngineNotifier, AiEngineState>(
  (ref) {
    return AiEngineNotifier();
  },
);

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

  Future<bool> _showPreFlightCheck(BuildContext context) async {
    final bool isMobile = Platform.isAndroid || Platform.isIOS;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFF00FFFF), width: 1.5),
                borderRadius: BorderRadius.circular(12),
              ),
              title: Row(
                children: [
                  Icon(
                    isMobile ? Icons.phone_android : Icons.computer,
                    color: const Color(0xFF00FFFF),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    "Revisión antes de iniciar",
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isMobile
                          ? "Estás en el celular. Haremos una preparación rápida de las canciones:"
                          : "Estás en la computadora. Aplicaremos la mejora de sonido completa:",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 20),

                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Buscar letras automáticamente",
                    ),
                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Calcular el momento exacto para mezclar",
                    ),
                    _buildCapabilityRow(
                      Icons.check_circle,
                      const Color(0xFF39FF14),
                      "Detectar la velocidad (Ritmo)",
                    ),

                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Divider(color: Colors.white10),
                    ),

                    _buildCapabilityRow(
                      isMobile ? Icons.lock : Icons.check_circle,
                      isMobile ? Colors.white24 : const Color(0xFF39FF14),
                      "Igualar el volumen de todas las pistas",
                      isMobile ? "Usa la compu" : null,
                    ),
                    _buildCapabilityRow(
                      isMobile ? Icons.lock : Icons.check_circle,
                      isMobile ? Colors.white24 : const Color(0xFF39FF14),
                      "Recortar espacios vacíos al inicio y final",
                      isMobile ? "Usa la compu" : null,
                    ),

                    if (isMobile) ...[
                      const SizedBox(height: 15),
                      const Text(
                        "💡 Tip: Para que tus canciones suenen más fuerte y nítidas, mejóralas primero en tu computadora y luego pásalas al celular.",
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    "CANCELAR",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFFF),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("INICIAR PREPARACIÓN"),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Widget _buildCapabilityRow(
    IconData icon,
    Color color,
    String title, [
    String? badge,
  ]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: color == Colors.white24 ? Colors.white54 : Colors.white,
                fontSize: 13,
              ),
            ),
          ),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _executeKaraokeBatch(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) {
    if (Platform.isAndroid || Platform.isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("🔴 VETO TÉCNICO: La IA de Karaoke requiere PC/Mac."),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (targetPath.isEmpty) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "🤖 Motor IA Activado. Puedes navegar a otros módulos mientras trabaja.",
        ),
        backgroundColor: Color(0xFFB026FF),
      ),
    );

    // Dispara el Job masivo hacia Python pasándole el puente de la UI
    KaraokeAIEngine.spawnBackgroundExtraction(targetPath, ref: ref);
  }

  Future<void> _executeUniversalPipeline(
    BuildContext context,
    WidgetRef ref,
    String targetPath,
  ) async {
    if (context.mounted) {
      bool isAuthorized = await _showPreFlightCheck(context);
      if (!isAuthorized) return;
    }

    final pipe = ref.read(pipelineProvider.notifier);
    ref.read(directoryProvider.notifier).scanPath(targetPath);
    bool checkAbort() => ref.read(pipelineProvider).isAborted;

    final bool isMobileOS = Platform.isAndroid || Platform.isIOS;

    final Map<String, Map<String, dynamic>> mixProfiles = {
      'salsa': {'curve': 'echo_out', 'durationMs': 0},
      'merengue': {'curve': 'echo_out', 'durationMs': 0},
      'cumbia': {'curve': 'brake_stop', 'durationMs': 1000},
      'nacional': {'curve': 'brake_stop', 'durationMs': 500},
      'vallenato': {'curve': 'echo_out', 'durationMs': 0},
      'guaracha': {'curve': 'brake_stop', 'durationMs': 1000},
      '80s': {'curve': 'quick_fade', 'durationMs': 2500},
      'rock': {'curve': 'eq_kill', 'durationMs': 2000},
      'balada': {'curve': 'quick_fade', 'durationMs': 3000},
      'española': {'curve': 'quick_fade', 'durationMs': 2500},
      'bachata': {'curve': 'constant_power', 'durationMs': 4000},
      'actualidad': {'curve': 'bass_swap', 'durationMs': 6000},
      'fiesta': {'curve': 'bass_swap', 'durationMs': 6000},
      'descargas': {'curve': 'constant_power', 'durationMs': 5000},
    };

    int consecutiveErrors = 0;
    String? criticalFailureMessage;
    bool isThermalThrottling = false;

    final checkpointFile = File(
      '$targetPath${Platform.pathSeparator}.dj_master_checkpoint.json',
    );
    Map<String, dynamic> checkpoint = {
      'status': 'started',
      'timestamp': DateTime.now().toIso8601String(),
      'processed': <String>[],
      'failed': <String>[],
    };

    if (checkpointFile.existsSync()) {
      try {
        final existingData = jsonDecode(checkpointFile.readAsStringSync());
        final String lastStatus = existingData['status'] ?? 'unknown';

        if (lastStatus != 'completed') {
          checkpoint['processed'] = existingData['processed'] ?? <String>[];
          checkpoint['failed'] = existingData['failed'] ?? <String>[];
          final int recoveredCount = (checkpoint['processed'] as List).length;

          debugPrint(
            "🔄 [PROCESS VALIDATOR] Sesión inconclusa detectada ($lastStatus). Recuperando $recoveredCount pistas.",
          );

          if (context.mounted && recoveredCount > 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '🔄 Validador Activo: Retomando sesión. Se saltarán $recoveredCount pistas.',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
                backgroundColor: const Color(0xFF00FFFF),
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } else {
          checkpointFile.deleteSync();
        }
      } catch (e) {
        debugPrint(
          "⚠️ [PROCESS VALIDATOR] Checkpoint corrupto. Iniciando en limpio.",
        );
      }
    }

    try {
      final dir = Directory(targetPath);
      if (!dir.existsSync()) return;

      final files = dir.listSync(recursive: true).whereType<File>().where((f) {
        final lowerPath = f.path.toLowerCase();
        return (lowerPath.endsWith('.mp3') && !lowerPath.endsWith('_k.mp3')) ||
            lowerPath.endsWith('.webm');
      }).toList();

      int total = files.length;
      if (total == 0) return;

      checkpoint['status'] = 'in_progress';
      checkpointFile.writeAsStringSync(jsonEncode(checkpoint));

      for (int i = 0; i < total; i++) {
        if (checkAbort()) break;

        final file = files[i];
        final originalName = file.uri.pathSegments.last;
        String currentPath = file.path;
        String currentStage = "INIT";

        if ((checkpoint['processed'] as List).contains(originalName) ||
            (checkpoint['failed'] as List).contains(originalName)) {
          pipe.updateProgress(
            i + 1,
            total,
            originalName,
            "⏭️ Validador de I/O: Pista ya procesada. Saltando...",
          );
          await Future.delayed(const Duration(milliseconds: 10));
          continue;
        }

        try {
          currentStage = "METADATA_CLEANUP";
          pipe.updateProgress(
            i + 1,
            total,
            originalName,
            "📝 Limpiando nombres...",
          );
          currentPath = await ref
              .read(metadataWorkerProvider)
              .processSingleFile(currentPath);
          if (checkAbort()) break;

          final cleanName = currentPath.split(Platform.pathSeparator).last;

          final double fileSizeMB =
              File(currentPath).lengthSync() / (1024 * 1024);
          final bool isHeavyMix = fileSizeMB > 16.0;

          int durationAfterMs = 0;

          if (!isMobileOS) {
            currentStage = "DSP_FFMPEG";
            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "🪄 Mejorando calidad de sonido...",
            );

            final durationBeforeMs = (await rust_dsp.getAudioDurationMs(
              inputPath: currentPath,
            )).toInt();

            await ref
                .read(dspWorkerProvider)
                .processSingleFile(currentPath)
                .timeout(
                  const Duration(seconds: 180),
                  onTimeout: () => throw Exception(
                    "Timeout DSP: Estrangulamiento Térmico FFmpeg.",
                  ),
                );
            if (checkAbort()) break;

            durationAfterMs = (await rust_dsp.getAudioDurationMs(
              inputPath: currentPath,
            )).toInt();

            final trimmedMs = durationBeforeMs - durationAfterMs;
            if (trimmedMs > 50) {
              final lrcFileToPatch = currentPath.replaceAll(
                RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
                '.lrc',
              );
              await _offsetLrcTimeline(lrcFileToPatch, trimmedMs);
            }

            currentStage = "WATERMARK_ID3";
            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "🔒 Guardando cambios...",
            );
            await rust_dsp
                .injectWatermark(inputPath: currentPath)
                .timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => throw Exception(
                    "Timeout: Bloqueo de disco al inyectar ID3v2.",
                  ),
                );
            if (checkAbort()) break;
          } else {
            pipe.updateProgress(
              i + 1,
              total,
              cleanName,
              "📱 Preparando en modo celular...",
            );
            await Future.delayed(const Duration(milliseconds: 50));
          }

          final finalName = currentPath.split(Platform.pathSeparator).last;

          currentStage = "NLP_LYRICS";
          if (isHeavyMix) {
            pipe.updateProgress(
              i + 1,
              total,
              finalName,
              "⏭️ Mix Pesado (${fileSizeMB.toStringAsFixed(1)}MB). Omitiendo NLP...",
            );
            await Future.delayed(const Duration(milliseconds: 500));
          } else {
            pipe.updateProgress(
              i + 1,
              total,
              finalName,
              "🎤 Descargando letras...",
            );
            try {
              await ref
                  .read(nlpWorkerProvider)
                  .processSingleFile(currentPath)
                  .timeout(
                    const Duration(seconds: 60),
                    onTimeout: () => throw Exception("Timeout de Red LRCLib."),
                  );
            } catch (e) {
              debugPrint(
                "⚠️ [NLP Aislando Error] Letra no encontrada para $finalName: $e",
              );
            }
          }
          if (checkAbort()) break;

          String rawGenre = 'desconocido';
          if (!isMobileOS) {
            currentStage = "GENRE_CLASSIFICATION";
            pipe.updateProgress(
              i + 1,
              total,
              finalName,
              "🎛️ Configurando género musical...",
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

          currentStage = "DB_ISAR";
          pipe.updateProgress(
            i + 1,
            total,
            finalName,
            "🎧 Calculando la mezcla perfecta...",
          );

          final existingMeta = await ref
              .read(dbServiceProvider)
              .getTrackMetadata(currentPath);
          final isManual = existingMeta?.isManualCue ?? false;

          int physicalDurationMs = durationAfterMs > 0
              ? durationAfterMs
              : (await rust_dsp.getAudioDurationMs(
                  inputPath: currentPath,
                )).toInt();

          int calculatedCueIn =
              (rawGenre.contains('electro') || rawGenre.contains('rock'))
              ? 100
              : 350;
          int calculatedMixOut = physicalDurationMs > assignedDuration
              ? physicalDurationMs - assignedDuration
              : physicalDurationMs - 2000;
          if (calculatedMixOut < 0) calculatedMixOut = 0;

          int finalCueIn =
              existingMeta != null &&
                  (isManual ||
                      (existingMeta.cueInMs != null &&
                          existingMeta.cueInMs! > 0))
              ? existingMeta.cueInMs!
              : calculatedCueIn;
          int finalMixOut =
              existingMeta != null &&
                  (isManual ||
                      (existingMeta.mixOutMs != null &&
                          existingMeta.mixOutMs! > 0))
              ? existingMeta.mixOutMs!
              : calculatedMixOut;

          await ref
              .read(dbServiceProvider)
              .saveTrackMetadata(
                path: currentPath,
                mixProfile: assignedProfile,
                durationMs: assignedDuration,
                genre: rawGenre,
                cueInMs: finalCueIn,
                mixOutMs: finalMixOut,
                isManualCue: isManual,
              );

          consecutiveErrors = 0;
          (checkpoint['processed'] as List).add(originalName);
          checkpoint['timestamp'] = DateTime.now().toIso8601String();
          checkpointFile.writeAsStringSync(jsonEncode(checkpoint));
        } catch (e) {
          debugPrint(
            "🔴 Error preparando la pista $originalName en stage $currentStage: $e",
          );
          pipe.addQuarantine(originalName);

          (checkpoint['failed'] as List).add(originalName);
          checkpoint['timestamp'] = DateTime.now().toIso8601String();
          checkpointFile.writeAsStringSync(jsonEncode(checkpoint));

          String errorCode = "ERR_UNKNOWN";
          String recommendedAction =
              "Archivo corrupto. Considera eliminarlo y descargar otra versión.";

          if (currentStage == "METADATA_CLEANUP") {
            errorCode = "ERR_FILE_IO";
            recommendedAction =
                "El archivo está bloqueado por otro programa (ej. Rekordbox, Serato o un reproductor). Ciérralos e inténtalo de nuevo.";
          } else if (currentStage == "DSP_FFMPEG") {
            errorCode = "ERR_CODEC";
            recommendedAction =
                "El codec del archivo MP3/M4A está roto o vacío. Reemplázalo descargando una nueva copia desde YouTube DL.";
          } else if (currentStage == "WATERMARK_ID3") {
            errorCode = "ERR_TAGS";
            recommendedAction =
                "Fallo al inyectar firmas ID3v2. Las etiquetas originales están corruptas. Intenta limpiar las etiquetas del archivo.";
          } else if (currentStage == "DB_ISAR") {
            errorCode = "ERR_DATABASE";
            recommendedAction =
                "Fallo al guardar en ISAR Database. Ejecuta un Reset de Fábrica si el problema persiste.";
          } else if (e.toString().contains("Timeout DSP")) {
            errorCode = "ERR_TIMEOUT";
            recommendedAction =
                "Fallo por alta temperatura de la CPU al normalizar el audio. Intenta masterizar esta pista sola más tarde.";
          }

          try {
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

            final failFile = File(currentPath);
            if (failFile.existsSync()) {
              final newPath =
                  '${labDir.path}${Platform.pathSeparator}$originalName';
              failFile.renameSync(newPath);

              registry[originalName] = {
                "originalPath": currentPath,
                "errorCode": errorCode,
                "errorMsg": e.toString(),
                "recommendedAction": recommendedAction,
                "failedAtStage": currentStage,
                "timestamp": DateTime.now().toIso8601String(),
              };

              final lrcFile = File(
                currentPath.replaceAll(
                  RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
                  '.lrc',
                ),
              );
              if (lrcFile.existsSync()) {
                lrcFile.renameSync(
                  '${labDir.path}${Platform.pathSeparator}${originalName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
                );
              }
              registryFile.writeAsStringSync(jsonEncode(registry));
            }
          } catch (ioErr) {
            debugPrint("🔴 Error crítico de I/O al aislar archivo: $ioErr");
          }

          consecutiveErrors++;
          final errorMessage = e.toString();

          if (errorMessage.contains("Timeout DSP")) {
            isThermalThrottling = true;
            criticalFailureMessage =
                "🌡️ ALERTA TÉRMICA: Tu procesador se ha sobrecalentado y el motor DSP colapsó.\n\n👉 ACCIÓN: Deja enfriar el equipo unos minutos y luego vuelve a darle a 'Masterización Global'. El Validador de Procesos saltará todo el trabajo anterior y retomará justo donde te quedaste.";
            checkpoint['status'] = 'thermal_halt';
            checkpointFile.writeAsStringSync(jsonEncode(checkpoint));
            pipe.abort();
            break;
          } else if (consecutiveErrors >= 3) {
            isThermalThrottling = false;
            criticalFailureMessage =
                "💥 COLAPSO I/O: Se han detectado múltiples fallos consecutivos de disco o base de datos.\n\n👉 ACCIÓN: Es OBLIGATORIO que ejecutes el 'Reset de Fábrica' antes de intentar masterizar. Recuerda borrar manualmente el archivo oculto .dj_master_checkpoint.json en tu carpeta si quieres forzar un re-procesamiento total.";
            checkpoint['status'] = 'io_crash';
            checkpointFile.writeAsStringSync(jsonEncode(checkpoint));
            pipe.abort();
            break;
          }
        }

        await Future.delayed(const Duration(milliseconds: 100));
      }

      if (!checkAbort()) {
        pipe.updateProgress(
          total,
          total,
          "Organizando biblioteca...",
          "🥁 Analizando velocidades (Ritmo)",
        );
        await ref.read(dspWorkerProvider).generateStaticBpmCache(targetPath);

        if (criticalFailureMessage == null) {
          checkpoint['status'] = 'completed';
          checkpoint['timestamp'] = DateTime.now().toIso8601String();
          checkpointFile.writeAsStringSync(jsonEncode(checkpoint));
        }
      }
    } catch (e) {
      debugPrint("🔴 [ERROR AL PREPARAR CARPETA]: $e");
    } finally {
      if (context.mounted) {
        final state = ref.read(pipelineProvider);

        if (criticalFailureMessage != null) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: isThermalThrottling
                      ? Colors.orangeAccent
                      : Colors.redAccent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              title: Row(
                children: [
                  Icon(
                    isThermalThrottling
                        ? Icons.thermostat
                        : Icons.warning_amber_rounded,
                    color: isThermalThrottling
                        ? Colors.orangeAccent
                        : Colors.redAccent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    isThermalThrottling
                        ? "Corte Térmico (Thermal Throttling)"
                        : "Colapso del Pipeline",
                    style: TextStyle(
                      color: isThermalThrottling
                          ? Colors.orangeAccent
                          : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              content: Text(
                criticalFailureMessage!,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isThermalThrottling
                        ? Colors.orangeAccent
                        : Colors.redAccent,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    "ENTENDIDO",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        } else if (state.total > 0) {
          _showSummaryDialog(
            context,
            "Preparación Completada",
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
    final aiState = ref.watch(aiEngineProvider); // 🧠 Escucha a la IA

    // 🛠️ BLOQUEO TOTAL: Si el DSP o la IA están trabajando, bloquea interacciones en esta ruta
    final bool isBusy = !pipeState.isIdle || aiState.isRunning;

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;
        final bool isMobileOS = Platform.isAndroid || Platform.isIOS;

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
              if (!pipeState.isIdle)
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

        final List<Widget> cardNodes = [];

        if (!isMobileOS) {
          cardNodes.add(
            _buildActionCard(
              title: "MASTERIZACIÓN PROFESIONAL",
              description:
                  "Pipeline atómico (PC/Mac). Optimiza audio (LUFS), recorta silencios, extrae semántica y asigna curvas.",
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
          );
        } else {
          cardNodes.add(
            _buildActionCard(
              title: "PREPARACIÓN MÓVIL",
              description:
                  "Alineación NLP e Indexación ISAR. (La Masterización DSP no está disponible en Android).",
              icon: Icons.phone_android,
              color: Colors.cyanAccent,
              isPrimary: true,
              onTap: (dirState.currentPath.isEmpty || isBusy)
                  ? null
                  : () => _executeUniversalPipeline(
                      context,
                      ref,
                      dirState.currentPath,
                    ),
            ),
          );
        }

        cardNodes.addAll([
          // 🛠️ TARJETA MUTANTE: Se transforma y muestra el porcentaje al activarse
          _buildActionCard(
            title: aiState.isRunning
                ? "IA TRABAJANDO..."
                : "EXTRACCIÓN KARAOKE IA",
            description: aiState.isRunning
                ? aiState.status
                : "Procesa la carpeta aislando las voces (Crea pistas _K.mp3) en segundo plano (Requiere PC).",
            icon: aiState.isRunning ? Icons.memory : Icons.mic_external_off,
            color: aiState.isRunning
                ? Colors.orangeAccent
                : const Color(0xFFB026FF),
            isPrimary: false,
            onTap: (dirState.currentPath.isEmpty || isBusy)
                ? null
                : () =>
                      _executeKaraokeBatch(context, ref, dirState.currentPath),
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
        ]);

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
                  height: 200,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: cardNodes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 15),
                    itemBuilder: (_, i) =>
                        SizedBox(width: 240, child: cardNodes[i]),
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
                    const SizedBox(width: 15),
                    Expanded(flex: 2, child: cardNodes[3]),
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
          file.renameSync(newPath);
          registry[fileName] = path;

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
      Navigator.pop(context);
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
    final Set<String> allBadPaths = {};
    // 🛠️ FIX ARQUITECTÓNICO: Jamás enviar al LAB las pistas "Sin Cues".
    // El LAB es para reparar archivos rotos. Los Cues se inyectan en la vista Live DJ.
    allBadPaths.addAll(unsealed);
    allBadPaths.addAll(noLyrics);
    allBadPaths.addAll(noBpm);

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
                        "Falta Set In/Out en ISAR (Se configuran en Live DJ)",
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  description,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF39FF14).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF39FF14).withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  "${items.length} archivos",
                  style: const TextStyle(
                    color: Color(0xFF39FF14),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
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

        // 🛠️ INYECCIÓN: Validación Nativa FFI (Sin FFprobe)
        bool isSealed = false;
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          isSealed = await rust_dsp.checkWatermark(inputPath: file.path);
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

        // 🛠️ FIX ARQUITECTÓNICO: Filtrado estricto por Cues Humanos
        if (meta == null || !meta.isManualCue) {
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

class KaraokeAIEngine {
  static void spawnBackgroundExtraction(String path, {WidgetRef? ref}) {
    final isFile = File(path).existsSync();
    final isDir = Directory(path).existsSync();

    if (!isFile && !isDir) return;
    if (isFile && !path.toLowerCase().endsWith('.mp3')) return;

    if (ref != null && ref.read(aiEngineProvider).isRunning) {
      debugPrint("⚠️ [AI ENGINE] Veto: Ya hay un proceso neuronal corriendo.");
      return;
    }

    ref?.read(aiEngineProvider.notifier).start(path);
    debugPrint("🤖 [AI ENGINE] Lanzando subproceso Demucs en: $path");

    try {
      Process.start('python', [
        'C:\\Python\\djstudio_player\\karaoke_ai_processor.py',
        path,
      ], runInShell: true).then((Process process) {
        const decoder = Utf8Decoder(allowMalformed: true);
        String currentTrack = "";

        process.stdout.transform(decoder).listen((data) {
          final text = data.trim();
          debugPrint("🔵 [DEMUCS]: $text");

          if (text.contains('[Procesando IA Demucs SINGLE]')) {
            currentTrack = text.split('SINGLE]').last.trim();
            ref
                ?.read(aiEngineProvider.notifier)
                .updateStatus('Analizando: $currentTrack');
          } else if (text.contains('[Exito]')) {
            ref
                ?.read(aiEngineProvider.notifier)
                .updateStatus('¡Instrumental Listo!: $currentTrack');
          }
        });

        process.stderr.transform(decoder).listen((data) {
          final text = data.trim();
          if (text.contains('%|')) {
            final match = RegExp(r'(\d+)%').firstMatch(text);
            if (match != null) {
              final percent = match.group(0);
              ref
                  ?.read(aiEngineProvider.notifier)
                  .updateStatus('Aislando Voces: $percent - $currentTrack');
            }
          }
        });

        process.exitCode.then((code) {
          debugPrint("✅ [AI ENGINE] Extracción IA terminada con código: $code");
          ref?.read(aiEngineProvider.notifier).stop();
        });
      });
    } catch (e) {
      debugPrint("🔴 [FATAL I/O] Fallo al iniciar puente Python: $e");
      ref?.read(aiEngineProvider.notifier).stop();
    }
  }
}
