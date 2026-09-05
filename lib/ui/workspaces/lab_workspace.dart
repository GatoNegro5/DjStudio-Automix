import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;

import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;
import '../../providers/automix_provider.dart';
import '../../providers/metadata_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/db_provider.dart';
import '../../providers/nlp_provider.dart';

class LabWorkspace extends ConsumerStatefulWidget {
  const LabWorkspace({super.key});

  @override
  ConsumerState<LabWorkspace> createState() => _LabWorkspaceState();
}

class _LabWorkspaceState extends ConsumerState<LabWorkspace> {
  String _labPath = '';
  Map<String, dynamic> _registry = {};
  bool _isLoading = true;

  String? _selectedFileForEdit;
  final TextEditingController _lrcController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();
  final TextEditingController _ytUrlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initLabEnvironment();
  }

  @override
  void dispose() {
    _lrcController.dispose();
    _searchQueryController.dispose();
    _ytUrlController.dispose();
    super.dispose();
  }

  void _initLabEnvironment() {
    String baseMusicPath = '';
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseMusicPath = userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    } else if (Platform.isMacOS || Platform.isLinux) {
      baseMusicPath = '${Platform.environment['HOME']}/Music';
    } else {
      baseMusicPath = '/storage/emulated/0/Music';
    }

    final labDir = Directory(
      '$baseMusicPath${Platform.pathSeparator}DjStudio_LAB',
    );
    if (!labDir.existsSync()) {
      labDir.createSync(recursive: true);
    }

    _labPath = labDir.path;
    _loadRegistry();
  }

  void _loadRegistry() {
    final registryFile = File(
      '$_labPath${Platform.pathSeparator}quarantine_registry.json',
    );
    if (registryFile.existsSync()) {
      try {
        _registry = jsonDecode(registryFile.readAsStringSync());
      } catch (_) {
        _registry = {};
      }
    } else {
      _registry = {};
    }

    final labDir = Directory(_labPath);
    final physicalFiles = labDir
        .listSync()
        .whereType<File>()
        .map((e) => e.uri.pathSegments.last)
        .toList();

    _registry.removeWhere((key, value) => !physicalFiles.contains(key));

    final validExtensions = ['.mp3', '.m4a', '.webm', '.wav', '.flac'];
    for (var fileName in physicalFiles) {
      final isAudio = validExtensions.any(
        (ext) => fileName.toLowerCase().endsWith(ext),
      );
      if (isAudio && !_registry.containsKey(fileName)) {
        _registry[fileName] = 'Origen Desconocido (Inyección Manual OS)';
      }
    }

    registryFile.writeAsStringSync(jsonEncode(_registry));

    setState(() => _isLoading = false);
  }

  void _loadLrcForEdit(String fileName) {
    try {
      final lrcFileName = fileName.replaceAll(
        RegExp(r'\.(mp3|m4a|webm|wav|flac)$', caseSensitive: false),
        '.lrc',
      );

      String baseMusicPath = Platform.isWindows
          ? '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Music'
          : '${Platform.environment['HOME'] ?? '/storage/emulated/0'}/Music';

      final labDir = Directory(
        '$baseMusicPath${Platform.pathSeparator}DjStudio_LAB',
      );
      final lrcFile = File(
        '${labDir.path}${Platform.pathSeparator}$lrcFileName',
      );

      if (lrcFile.existsSync()) {
        final content = lrcFile.readAsStringSync(encoding: utf8);
        setState(() {
          _selectedFileForEdit = fileName;
          _lrcController.text = content;
        });
      } else {
        setState(() {
          _selectedFileForEdit = fileName;
          _lrcController.text = "";
        });
      }
    } catch (e) {
      debugPrint("🔴 Error cargando LRC en UI: $e");
      setState(() {
        _selectedFileForEdit = fileName;
        _lrcController.text = "Error cargando archivo .lrc: $e";
      });
    }
  }

  void _saveLrc() {
    if (_selectedFileForEdit == null) return;
    final lrcFile = File(
      '$_labPath${Platform.pathSeparator}${_selectedFileForEdit!.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
    );
    lrcFile.writeAsStringSync(_lrcController.text);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✅ Letra sincronizada (.lrc) guardada en disco."),
        backgroundColor: Color(0xFF39FF14),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _restoreFile(String fileName, dynamic registryValue) async {
    try {
      // 🛠️ FIX: Extracción tolerante para soportar JSON Enriquecido o Strings legacy
      String originalPath = registryValue is Map
          ? (registryValue['originalPath']?.toString() ?? '')
          : registryValue.toString();

      if (originalPath.isEmpty || originalPath.contains('Origen Desconocido')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "🔴 ERROR: Ruta original desconocida. Muévelo manualmente.",
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) {
        final targetDir = Directory(File(originalPath).parent.path);
        if (!targetDir.existsSync()) targetDir.createSync(recursive: true);

        file.renameSync(originalPath);

        final lrcFile = File(
          '$_labPath${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
        );
        if (lrcFile.existsSync()) {
          final originalLrcPath = originalPath.replaceAll(
            RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
            '.lrc',
          );
          lrcFile.renameSync(originalLrcPath);
        }

        _registry.remove(fileName);
        final registryFile = File(
          '$_labPath${Platform.pathSeparator}quarantine_registry.json',
        );
        registryFile.writeAsStringSync(jsonEncode(_registry));

        if (_selectedFileForEdit == fileName) {
          _selectedFileForEdit = null;
          _lrcController.clear();
          _searchQueryController.clear();
        }

        _loadRegistry();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("✅ Restaurado: $fileName a su origen."),
              backgroundColor: const Color(0xFF39FF14),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O restaurando: $e");
    }
  }

  void _deleteFile(String fileName) {
    try {
      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) file.deleteSync();

      final lrcFile = File(
        '$_labPath${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
      );
      if (lrcFile.existsSync()) lrcFile.deleteSync();

      _registry.remove(fileName);
      final registryFile = File(
        '$_labPath${Platform.pathSeparator}quarantine_registry.json',
      );
      registryFile.writeAsStringSync(jsonEncode(_registry));

      if (_selectedFileForEdit == fileName) {
        _selectedFileForEdit = null;
        _lrcController.clear();
        _searchQueryController.clear();
      }

      _loadRegistry();
    } catch (e) {
      debugPrint("🔴 Error de I/O eliminando: $e");
    }
  }

  void _openWebBrowser(String url) {
    if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [url]);
    }
  }

  Future<void> _searchInternalLrclib() async {
    final query = _searchQueryController.text.trim();
    if (query.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: Colors.orangeAccent),
      ),
    );

    try {
      final results = await ref
          .read(automixProvider.notifier)
          .searchLyrics(query);
      if (!mounted) return;
      Navigator.pop(context);

      final syncedResults = results
          .where(
            (r) =>
                r['syncedLyrics'] != null &&
                r['syncedLyrics'].toString().isNotEmpty,
          )
          .toList();

      showDialog(
        context: context,
        builder: (ctx) {
          final isMobile = MediaQuery.of(ctx).size.width < 600;
          return AlertDialog(
            backgroundColor: const Color(0xFF121212),
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: Colors.orangeAccent),
              borderRadius: BorderRadius.circular(8),
            ),
            title: const Text(
              "Resultados Internos (LRCLIB)",
              style: TextStyle(color: Colors.orangeAccent, fontSize: 14),
            ),
            content: SizedBox(
              width: isMobile ? MediaQuery.of(ctx).size.width * 0.9 : 500,
              height: isMobile ? MediaQuery.of(ctx).size.height * 0.7 : 400,
              child: syncedResults.isEmpty
                  ? const Center(
                      child: Text(
                        "No se encontraron letras sincronizadas en el API.",
                        style: TextStyle(color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: syncedResults.length,
                      itemBuilder: (context, index) {
                        final track = syncedResults[index];
                        final int durationSec =
                            (track['duration'] as num?)?.toInt() ?? 0;
                        final durMin = (durationSec ~/ 60).toString().padLeft(
                          2,
                          '0',
                        );
                        final durSec = (durationSec % 60).toString().padLeft(
                          2,
                          '0',
                        );

                        return ListTile(
                          contentPadding: isMobile
                              ? EdgeInsets.zero
                              : const EdgeInsets.symmetric(horizontal: 16),
                          leading: const Icon(
                            Icons.check_circle,
                            color: Color(0xFF39FF14),
                          ),
                          title: Text(
                            "${track['artistName']} - ${track['trackName']}",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: isMobile ? 12 : 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            "Álbum: ${track['albumName']} • Duración: $durMin:$durSec",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: isMobile ? 10 : 11,
                            ),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white10,
                              foregroundColor: Colors.orangeAccent,
                            ),
                            child: Text(
                              "IMPORTAR",
                              style: TextStyle(fontSize: isMobile ? 10 : 12),
                            ),
                            onPressed: () {
                              setState(() {
                                _lrcController.text = track['syncedLyrics'];
                              });
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "Letra importada al editor. Dale a 'Guardar en Disco'.",
                                  ),
                                  backgroundColor: Colors.orangeAccent,
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  "Cerrar",
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

  String _getFfprobePath() {
    if (Platform.isAndroid || Platform.isIOS) return 'ffprobe';
    if (Platform.isMacOS) {
      if (File('/opt/homebrew/bin/ffprobe').existsSync()) {
        return '/opt/homebrew/bin/ffprobe';
      }
      if (File('/usr/local/bin/ffprobe').existsSync()) {
        return '/usr/local/bin/ffprobe';
      }
      return 'ffprobe';
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final localPath = Platform.isWindows
        ? '$exeDir\\ffprobe.exe'
        : '$exeDir/ffprobe';
    return File(localPath).existsSync() ? localPath : 'ffprobe';
  }

  String _getFfmpegPath() {
    if (Platform.isAndroid || Platform.isIOS) return 'ffmpeg';
    if (Platform.isMacOS) {
      if (File('/opt/homebrew/bin/ffmpeg').existsSync()) {
        return '/opt/homebrew/bin/ffmpeg';
      }
      if (File('/usr/local/bin/ffmpeg').existsSync()) {
        return '/usr/local/bin/ffmpeg';
      }
      return 'ffmpeg';
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final localPath = Platform.isWindows
        ? '$exeDir\\ffmpeg.exe'
        : '$exeDir/ffmpeg';
    return File(localPath).existsSync() ? localPath : 'ffmpeg';
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

  Future<void> _rescueLabTrackFromYoutube(
    String url,
    String targetOriginalPath,
  ) async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '🔴 VETO TÉCNICO: La extracción nativa (yt-dlp) requiere binarios de escritorio. No disponible en móvil.',
            ),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    final ValueNotifier<String> statusNotifier = ValueNotifier<String>(
      "Iniciando conexión...",
    );

    debugPrint("🟢 [LAB TRACKER START] Rescate solicitado para: $url");
    debugPrint("🟢 [LAB TRACKER START] Target Original: $targetOriginalPath");

    try {
      final testFile = File(targetOriginalPath);
      if (testFile.existsSync()) {
        final raf = testFile.openSync(mode: FileMode.append);
        raf.closeSync();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "🔴 ERROR I/O: El archivo está reproduciéndose. Libéralo del reproductor primero.",
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Colors.redAccent),
            const SizedBox(width: 20),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: statusNotifier,
                builder: (context, value, child) => Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    try {
      final tempDir = Directory.systemTemp;

      String ytdlpPath = 'yt-dlp';
      if (Platform.isWindows) {
        ytdlpPath = '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe';
      } else if (Platform.isMacOS) {
        if (File('/opt/homebrew/bin/yt-dlp').existsSync()) {
          ytdlpPath = '/opt/homebrew/bin/yt-dlp';
        } else if (File('/usr/local/bin/yt-dlp').existsSync())
          ytdlpPath = '/usr/local/bin/yt-dlp';
      }

      final tempAudioPrefix =
          '${tempDir.path}${Platform.pathSeparator}lab_rescue_temp';

      debugPrint("🟢 [LAB TRACKER I/O] Directorio Temp: ${tempDir.path}");

      try {
        final existingFiles = tempDir.listSync().where(
          (f) => f.path.startsWith(tempAudioPrefix),
        );
        for (var f in existingFiles) {
          f.deleteSync();
        }
      } catch (_) {}

      if (Platform.isWindows && !File(ytdlpPath).existsSync()) {
        statusNotifier.value = "Descargando motor extractor yt-dlp...";
        final dlUrl = Uri.parse(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        );
        final response = await http.get(dlUrl);
        await File(ytdlpPath).writeAsBytes(response.bodyBytes);
      }

      statusNotifier.value =
          "1/6. Descargando stream crudo nativo (Bypass DRM)...";

      final process = await Process.start(ytdlpPath, [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=android_vr',
        '-o',
        '$tempAudioPrefix.%(ext)s',
        url,
      ]);

      String errorTrace = "";
      process.stdout.listen((_) {});
      process.stderr.listen((bytes) {
        errorTrace += String.fromCharCodes(bytes);
      });

      final exitCode = await process.exitCode;

      File? downloadedFile;
      try {
        final files = tempDir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.startsWith(tempAudioPrefix) &&
                  !f.path.endsWith('.lrc'),
            )
            .toList();
        if (files.isNotEmpty) downloadedFile = files.first;
      } catch (_) {}

      if (exitCode == 0 &&
          downloadedFile != null &&
          downloadedFile.existsSync()) {
        final ext = downloadedFile.path.split('.').last;
        statusNotifier.value = "2/6. Sobrescritura Atómica en Laboratorio...";

        final baseOriginalName = targetOriginalPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
          '',
        );
        final newTargetFile = '$baseOriginalName.$ext';
        final targetOriginalFile = File(targetOriginalPath);
        final newFile = File(newTargetFile);
        final targetLrcFile = File('$baseOriginalName.lrc');

        await downloadedFile.copy(newFile.path);
        await downloadedFile.delete();

        if (targetOriginalPath != newTargetFile &&
            targetOriginalFile.existsSync()) {
          try {
            targetOriginalFile.deleteSync();
          } catch (_) {}
        }

        if (targetLrcFile.existsSync()) {
          debugPrint("🟢 [LAB TRACKER FS] Purgando LRC antiguo desfasado.");
          targetLrcFile.deleteSync();
        }

        String finalPath = newFile.path;

        statusNotifier.value = "3/6. Limpieza Metadata...";
        finalPath = await ref
            .read(metadataWorkerProvider)
            .processSingleFile(finalPath);

        // 🧠 LÓGICA DE BYPASS POR PESO FÍSICO (REMIX/MEGAMIX)
        final double fileSizeMB = File(finalPath).lengthSync() / (1024 * 1024);
        final bool isHeavyMix = fileSizeMB > 16.0;

        if (isHeavyMix) {
          debugPrint(
            "🟢 [LAB TRACKER] Track pesado/Remix detectado (${fileSizeMB.toStringAsFixed(1)}MB). Omitiendo NLP.",
          );
          statusNotifier.value =
              "⏭️ Mix pesado. Omitiendo Scraping de Letras...";
          await Future.delayed(const Duration(seconds: 1));
        } else {
          statusNotifier.value = "3/6. Scraping LRCLIB (NLP)...";
          debugPrint("🟢 [LAB TRACKER NLP] Invocando LRCLIB Prioritario...");
          await ref.read(nlpWorkerProvider).processSingleFile(finalPath);

          if (!targetLrcFile.existsSync()) {
            debugPrint(
              "⚠️ [LAB TRACKER NLP] Sin éxito. Usando Fallback VTT...",
            );
            statusNotifier.value = "⚠️ Extrayendo subtítulos de YouTube...";
            try {
              final yt = YoutubeExplode();
              final videoId = VideoId(url);
              final manifest = await yt.videos.closedCaptions.getManifest(
                videoId,
              );

              if (manifest.tracks.isNotEmpty) {
                ClosedCaptionTrackInfo? selectedTrack;
                for (var lang in ['es', 'en']) {
                  try {
                    selectedTrack = manifest.tracks.firstWhere(
                      (t) =>
                          t.language.code.toLowerCase().contains(lang) &&
                          !t.isAutoGenerated,
                    );
                    break;
                  } catch (_) {}
                }
                selectedTrack ??= manifest.tracks.firstWhere(
                  (t) => t.language.code.toLowerCase().contains('es'),
                  orElse: () => manifest.tracks.first,
                );

                final track = await yt.videos.closedCaptions.get(selectedTrack);
                final lrcBuffer = StringBuffer();

                for (var caption in track.captions) {
                  final start = caption.offset;
                  final min = start.inMinutes.toString().padLeft(2, '0');
                  final sec = (start.inSeconds % 60).toString().padLeft(2, '0');
                  final ms = ((start.inMilliseconds % 1000) ~/ 10)
                      .toString()
                      .padLeft(2, '0');

                  final text = caption.text
                      .replaceAll('\n', ' ')
                      .replaceAll(RegExp(r'<[^>]*>'), '')
                      .trim();
                  final lowerText = text.toLowerCase();
                  final normalizedText = lowerText
                      .replaceAll('ú', 'u')
                      .replaceAll('í', 'i')
                      .replaceAll('ó', 'o');
                  bool isGarbage = false;

                  if (normalizedText.contains(
                    RegExp(
                      r'\[musica\]|\(musica\)|\[aplausos\]|\(aplausos\)|instrumental|♪|🎵',
                    ),
                  )) {
                    isGarbage = true;
                  }
                  if (normalizedText.startsWith('[') &&
                      normalizedText.endsWith(']')) {
                    isGarbage = true;
                  }
                  if (normalizedText.startsWith('(') &&
                      normalizedText.endsWith(')')) {
                    isGarbage = true;
                  }

                  final alphaNumOnly = lowerText.replaceAll(
                    RegExp(r'[^a-z0-9]'),
                    '',
                  );
                  if (alphaNumOnly.length <= 2) isGarbage = true;

                  if (!isGarbage && text.isNotEmpty) {
                    lrcBuffer.writeln('[$min:$sec.$ms]$text');
                  }
                }
                if (lrcBuffer.isNotEmpty) {
                  await targetLrcFile.writeAsString(lrcBuffer.toString());
                  debugPrint(
                    "🟢 [LAB TRACKER I/O] Letra VTT generada y blindada.",
                  );
                }
              }
              yt.close();
            } catch (e) {
              debugPrint("⚠️ [LAB TRACKER NLP] Fallo en Fallback YouTube: $e");
            }
          }
        }

        statusNotifier.value =
            "4/6. Aplicando Auto-Trim C++ (Cortando silencios)...";
        final durationBeforeMs = await _getAudioDurationMs(finalPath);
        await ref.read(dspWorkerProvider).processSingleFile(finalPath);
        final durationAfterMs = await _getAudioDurationMs(finalPath);

        statusNotifier.value =
            "5/6. Compensación del Vector de Tiempo (LRC)...";
        final trimmedMs = durationBeforeMs - durationAfterMs;
        debugPrint("🟢 [LAB TRACKER DSP] Audio cortado en: $trimmedMs ms");

        if (trimmedMs > 50) {
          final lrcToPatch = finalPath.replaceAll(
            RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
            '.lrc',
          );
          await _offsetLrcTimeline(lrcToPatch, trimmedMs);
        }

        statusNotifier.value = "6/6. Indexando en Base de Datos ISAR...";
        await rust_dsp.injectWatermark(inputPath: finalPath);
        final rawGenre = await rust_dsp.readAudioGenre(inputPath: finalPath);
        await ref
            .read(dbServiceProvider)
            .saveTrackMetadata(
              path: finalPath,
              mixProfile: 'constant_power',
              durationMs: 6000,
              genre: rawGenre,
              cueInMs: 0,
              mixOutMs: null,
            );
        await ref
            .read(dspWorkerProvider)
            .generateStaticBpmCache(Directory(finalPath).parent.path);

        final oldFileName = targetOriginalPath
            .split(Platform.pathSeparator)
            .last;
        final finalFileName = finalPath.split(Platform.pathSeparator).last;

        if (oldFileName != finalFileName &&
            _registry.containsKey(oldFileName)) {
          final originalOrigin = _registry[oldFileName];
          _registry.remove(oldFileName);

          if (originalOrigin is Map) {
            originalOrigin['originalPath'] = originalOrigin['originalPath']
                ?.toString()
                .replaceAll(
                  RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
                  '.$ext',
                );
            _registry[finalFileName] = originalOrigin;
          } else {
            final newOrigin = originalOrigin.toString().replaceAll(
              RegExp(r'\.mp3$|\.webm$|\.m4a$', caseSensitive: false),
              '.$ext',
            );
            _registry[finalFileName] = newOrigin;
          }

          File(
            '$_labPath${Platform.pathSeparator}quarantine_registry.json',
          ).writeAsStringSync(jsonEncode(_registry));

          if (_selectedFileForEdit == oldFileName) {
            _selectedFileForEdit = finalFileName;
          }
        }

        _loadRegistry();
        _loadLrcForEdit(finalFileName);

        // 🛠️ INYECCIÓN KRAEOKE FIRE-AND-FORGET CONDICIONADA AL PESO
        if (!isHeavyMix) {
          KaraokeAIEngine.spawnBackgroundExtraction(finalPath);
        }

        if (mounted) {
          Navigator.pop(context);
          _ytUrlController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                isHeavyMix
                    ? '✅ Rescate completado (Karaoke omitido por peso).'
                    : '✅ Rescate listo. 🤖 Generando Karaoke en fondo...',
              ),
              backgroundColor: const Color(0xFF39FF14),
            ),
          );
        }
      } else {
        throw Exception(
          "CLI Exit $exitCode | Traza: ${errorTrace.isNotEmpty ? errorTrace : 'Archivo físico no generado.'}",
        );
      }
    } catch (e) {
      debugPrint("🔴 [LAB TRACKER FATAL] $e");
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔴 Fallo de Rescate: $e'),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 8),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------
  // 🛠️ WIDGETS DE RENDERIZADO MODULAR
  // ---------------------------------------------------------

  Widget _buildDiagnosticCard(Map<String, dynamic> telemetryData) {
    final errorCode = telemetryData['errorCode'] ?? 'UNKNOWN';
    final msg = telemetryData['errorMsg'] ?? 'Error desconocido';
    final action =
        telemetryData['recommendedAction'] ?? 'Revise manualmente el archivo.';
    final stage = telemetryData['failedAtStage'] ?? 'N/A';

    Color badgeColor = Colors.redAccent;
    IconData badgeIcon = Icons.error_outline;

    if (errorCode == 'ERR_TIMEOUT') {
      badgeColor = Colors.orangeAccent;
      badgeIcon = Icons.thermostat;
    } else if (errorCode == 'ERR_CODEC') {
      badgeColor = Colors.purpleAccent;
      badgeIcon = Icons.broken_image;
    } else if (errorCode == 'ERR_FILE_IO') {
      badgeColor = Colors.yellowAccent;
      badgeIcon = Icons.lock_outline;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 15),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.1),
        border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(badgeIcon, color: badgeColor, size: 20),
              const SizedBox(width: 10),
              Text(
                "Diagnóstico de Falla: $errorCode",
                style: TextStyle(
                  color: badgeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  "Stage: $stage",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            msg,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'Consolas',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb, color: Colors.yellow, size: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Recomendación: $action",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftPanel(
    List<MapEntry<String, dynamic>> entries,
    bool isMobile,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final fileName = entries[index].key;
          final registryValue = entries[index].value;
          final isSelected = _selectedFileForEdit == fileName;

          // 🛠️ FIX: Extracción tolerante de la ruta original
          final originalPath = registryValue is Map
              ? (registryValue['originalPath']?.toString() ??
                    'Origen desconocido')
              : registryValue.toString();

          final hasTelemetry =
              registryValue is Map && registryValue.containsKey('errorCode');

          return Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.orangeAccent.withValues(alpha: 0.1)
                  : Colors.transparent,
              border: const Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: ListTile(
              onTap: () => _loadLrcForEdit(fileName),
              leading: Icon(
                hasTelemetry ? Icons.healing : Icons.audio_file,
                color: isSelected
                    ? Colors.orangeAccent
                    : (hasTelemetry ? Colors.redAccent : Colors.white38),
              ),
              title: Text(
                fileName,
                style: TextStyle(
                  color: isSelected ? Colors.orangeAccent : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: isMobile ? 12 : 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                "Origen: ${originalPath.split(Platform.pathSeparator).reversed.skip(1).take(2).toList().reversed.join('/')}",
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: isMobile ? 9 : 10,
                  fontFamily: 'Consolas',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: const Color(0xFF1A1A1A),
                onSelected: (value) {
                  if (value == 'restore') _restoreFile(fileName, registryValue);
                  if (value == 'delete') _deleteFile(fileName);
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.restore, color: Color(0xFF39FF14), size: 18),
                        SizedBox(width: 10),
                        Text(
                          'Restaurar a Origen',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_forever,
                          color: Colors.redAccent,
                          size: 18,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Destruir Archivos',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRightPanel(bool isMobile) {
    if (_selectedFileForEdit == null) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border.all(color: Colors.white10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          "Selecciona una pista para abrir el instrumental del Laboratorio.",
          style: TextStyle(color: Colors.white38),
          textAlign: TextAlign.center,
        ),
      );
    }

    final registryValue = _registry[_selectedFileForEdit];
    final bool hasTelemetry = registryValue is Map;

    return Column(
      children: [
        // 🛠️ INYECCIÓN: Tarjeta de Diagnóstico Activa si hay Telemetría DLQ
        if (hasTelemetry)
          _buildDiagnosticCard(Map<String, dynamic>.from(registryValue)),

        Container(
          padding: EdgeInsets.all(isMobile ? 10 : 15),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: Colors.orangeAccent.withValues(alpha: 0.5),
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Arsenal de Búsqueda y Sincronización",
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: isMobile ? 11 : 12,
                ),
              ),
              const SizedBox(height: 15),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchQueryController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.black,
                        hintText: "Nombre de canción para buscar letra...",
                        hintStyle: TextStyle(color: Colors.white38),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: _searchInternalLrclib,
                    icon: const Icon(Icons.api, size: 16),
                    label: const Text("Buscar LRCLIB"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FFFF),
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ytUrlController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Color(0xFF2A0000),
                        hintText:
                            "Pega el link de YouTube aquí para descargar/sobrescribir...",
                        hintStyle: TextStyle(color: Colors.white38),
                        border: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.redAccent),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      final url = _ytUrlController.text.trim();
                      if (url.startsWith('http')) {
                        // 🛠️ FIX: Extracción tolerante para inyectar la URL al motor yt-dlp
                        final originalPath = registryValue is Map
                            ? (registryValue['originalPath']?.toString() ??
                                  '$_labPath${Platform.pathSeparator}$_selectedFileForEdit')
                            : (registryValue?.toString() ??
                                  '$_labPath${Platform.pathSeparator}$_selectedFileForEdit');

                        _rescueLabTrackFromYoutube(url, originalPath);
                      } else {
                        final q = Uri.encodeComponent(
                          '${_searchQueryController.text} official audio',
                        );
                        _openWebBrowser(
                          'https://www.youtube.com/results?search_query=$q',
                        );
                      }
                    },
                    icon: const Icon(Icons.video_library, size: 16),
                    label: const Text("Reemplazo YouTube"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),

              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser('https://genius.com/search?q=$q');
                    },
                    icon: const Icon(
                      Icons.text_snippet,
                      color: Colors.yellowAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "Genius",
                      style: TextStyle(
                        color: Colors.yellowAccent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        _openWebBrowser('https://lrc-maker.github.io/'),
                    icon: const Icon(
                      Icons.tap_and_play,
                      color: Color(0xFF39FF14),
                      size: 14,
                    ),
                    label: const Text(
                      "LRC Maker",
                      style: TextStyle(color: Color(0xFF39FF14), fontSize: 11),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser('https://www.musixmatch.com/search/$q');
                    },
                    icon: const Icon(
                      Icons.library_music,
                      color: Colors.pinkAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "Musixmatch",
                      style: TextStyle(color: Colors.pinkAccent, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        Expanded(
          child: Container(
            padding: EdgeInsets.all(isMobile ? 10 : 20),
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              border: Border(
                left: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                right: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                bottom: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
              ),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isMobile)
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.orangeAccent,
                        ),
                        onPressed: () =>
                            setState(() => _selectedFileForEdit = null),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    if (isMobile) const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Editando LRC: ${_selectedFileForEdit!.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}",
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Consolas',
                          fontSize: isMobile ? 11 : 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _saveLrc,
                      icon: Icon(Icons.save, size: isMobile ? 14 : 18),
                      label: Text(
                        isMobile ? "Guardar" : "Guardar en Disco",
                        style: TextStyle(fontSize: isMobile ? 10 : 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Expanded(
                  child: TextField(
                    controller: _lrcController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Consolas',
                      fontSize: isMobile ? 11 : 13,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          "Pega aquí la letra sincronizada (.lrc)...\n\n[00:15.30] Una morena me dijo\n[00:18.45] que la llevara a Jamapa",
                      hintStyle: const TextStyle(color: Colors.white24),
                      filled: true,
                      fillColor: const Color(0xFF0A0A0A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _registry.entries.toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = constraints.maxWidth < 850;
        return Padding(
          padding: EdgeInsets.all(isMobile ? 15.0 : 30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.science,
                    color: Colors.orangeAccent,
                    size: isMobile ? 24 : 30,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      "Laboratorio de Cuarentena (DLQ)",
                      style: TextStyle(
                        fontSize: isMobile ? 18 : 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.orangeAccent,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                "Entorno de aislamiento y manipulación cruda. Extrae, sincroniza o reemplaza audios/letras defectuosas antes de reinyectarlos.",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: isMobile ? 11 : 13,
                ),
              ),
              const SizedBox(height: 20),

              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.orangeAccent),
                )
              else if (entries.isEmpty)
                Container(
                  padding: const EdgeInsets.all(40),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Text(
                    "✅ Cuarentena limpia. No hay archivos defectuosos.",
                    style: TextStyle(color: Color(0xFF39FF14), fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Expanded(
                  child: isMobile
                      ? (_selectedFileForEdit == null
                            ? _buildLeftPanel(entries, isMobile)
                            : _buildRightPanel(isMobile))
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 1,
                              child: _buildLeftPanel(entries, isMobile),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 2,
                              child: _buildRightPanel(isMobile),
                            ),
                          ],
                        ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class KaraokeAIEngine {
  static void spawnBackgroundExtraction(String path) {
    final isFile = File(path).existsSync();
    final isDir = Directory(path).existsSync();

    // 1. Verificamos que la ruta exista física en el disco
    if (!isFile && !isDir) {
      debugPrint("🔴 [AI ENGINE] Ruta ignorada (No existe): $path");
      return;
    }

    // 2. Si es archivo, exigimos MP3. Si es carpeta, lo dejamos pasar libremente.
    if (isFile && !path.toLowerCase().endsWith('.mp3')) {
      debugPrint("🔴 [AI ENGINE] Archivo ignorado (No es MP3): $path");
      return;
    }

    debugPrint("🤖 [AI ENGINE] Lanzando subproceso Demucs en: $path");

    try {
      Process.start('python', [
        'C:\\Python\\djstudio_player\\karaoke_ai_processor.py',
        path,
      ], runInShell: true).then((Process process) {
        // Blindaje contra bytes malformados (cp1252 vs utf8)
        const decoder = Utf8Decoder(allowMalformed: true);

        process.stdout.transform(decoder).listen((data) {
          debugPrint("🔵 [DEMUCS]: ${data.trim()}");
        });
        process.stderr.transform(decoder).listen((data) {
          debugPrint("🔴 [DEMUCS PROGRESS]: ${data.trim()}");
        });

        process.exitCode.then((code) {
          debugPrint("✅ [AI ENGINE] Extracción IA terminada con código: $code");
        });
      });
    } catch (e) {
      debugPrint("🔴 [FATAL I/O] Fallo al iniciar puente Python: $e");
    }
  }
}
