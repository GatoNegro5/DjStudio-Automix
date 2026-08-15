import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:http/http.dart' as http;
import 'package:file_selector/file_selector.dart';

// 🛠️ INYECTADO: Backend FFI Nativo y Providers para Auto-Masterización
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;
import 'providers/metadata_provider.dart';
import 'providers/nlp_provider.dart';
import 'providers/dsp_provider.dart';
import 'providers/db_provider.dart';

// =====================================================================
// MÓDULO 2: BÚSQUEDA, EXTRACCIÓN Y AUTO-MASTER YT
// =====================================================================
class YoutubeSearchAndDownloadWorkspace extends ConsumerStatefulWidget {
  const YoutubeSearchAndDownloadWorkspace({super.key});

  @override
  ConsumerState<YoutubeSearchAndDownloadWorkspace> createState() =>
      _YoutubeSearchAndDownloadWorkspaceState();
}

class _YoutubeSearchAndDownloadWorkspaceState
    extends ConsumerState<YoutubeSearchAndDownloadWorkspace> {
  final TextEditingController _searchController = TextEditingController();
  final YoutubeExplode _yt = YoutubeExplode();

  List<Video> _results = [];
  bool _isProcessing = false;
  String _statusText =
      "Sistemas en línea. Busca un artista o pega URL directa.";

  // Controles de I/O y Pipeline
  String _selectedFolderPath = '';
  bool _autoMasterize = true;

  @override
  void initState() {
    super.initState();
    _initDefaultPath();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _yt.close();
    super.dispose();
  }

  void _initDefaultPath() {
    String baseMusicPath = '';
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseMusicPath = userProfile != null
          ? '$userProfile\\Music\\Descargas'
          : 'C:\\Music\\Descargas';
    } else if (Platform.isMacOS || Platform.isLinux) {
      baseMusicPath = '${Platform.environment['HOME']}/Music/Descargas';
    } else {
      baseMusicPath = '/storage/emulated/0/Music/Descargas';
    }

    final baseDir = Directory(baseMusicPath);
    if (!baseDir.existsSync()) {
      baseDir.createSync(recursive: true);
    }

    setState(() {
      _selectedFolderPath = baseDir.path;
    });
  }

  // 🛠️ PROFESIONAL: Uso de API Nativa Oficial de Google (file_selector)
  Future<void> _showFolderSelectionDialog() async {
    try {
      final String? selectedDirectory = await getDirectoryPath(
        confirmButtonText: 'Seleccionar Carpeta',
      );

      if (selectedDirectory != null) {
        setState(() {
          _selectedFolderPath = selectedDirectory;
        });
      }
    } catch (e) {
      debugPrint("🔴 Error invocando el explorador nativo: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 Fallo al abrir el explorador de archivos nativo: $e',
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
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
      debugPrint("✅ Vector LRC compensado en -$trimmedMs ms.");
    } catch (e) {
      debugPrint("🔴 Error realineando LRC: $e");
    }
  }

  Future<void> _handleInput(String input) async {
    if (input.isEmpty) return;
    if (input.startsWith('http')) {
      await _executeDirectDownload(input);
    } else {
      await _executeSearch(input);
    }
  }

  Future<void> _executeSearch(String query) async {
    setState(() {
      _isProcessing = true;
      _statusText = "Buscando '$query' en los servidores de YouTube...";
      _results.clear();
    });

    try {
      final searchResult = await _yt.search.search('$query official audio');
      setState(() {
        _results = searchResult.take(15).toList();
        _statusText = "Resultados listos. Clic en 'Ingestar' para descargar.";
      });
    } catch (e) {
      setState(() => _statusText = "🔴 ERROR de Búsqueda: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _runSingleTrackPipeline(String initialPath) async {
    String currentPath = initialPath;

    try {
      setState(() => _statusText = "⚙️ Limpieza de metadatos...");
      currentPath = await ref
          .read(metadataWorkerProvider)
          .processSingleFile(currentPath);

      setState(() => _statusText = "🔊 Aplicando DSP (C++) & Trim...");

      // 🛠️ INYECCIÓN: Telemetría de Compensación
      final durationBeforeMs = await _getAudioDurationMs(currentPath);
      await ref.read(dspWorkerProvider).processSingleFile(currentPath);
      final durationAfterMs = await _getAudioDurationMs(currentPath);
      final trimmedMs = durationBeforeMs - durationAfterMs;

      if (trimmedMs > 50) {
        setState(
          () => _statusText = "⏱️ Realineando subtítulos (-$trimmedMs ms)...",
        );
        final lrcPath = currentPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
          '.lrc',
        );
        await _offsetLrcTimeline(lrcPath, trimmedMs);
      }

      setState(() => _statusText = "🔐 Inyectando Sello Watermark...");
      await rust_dsp.injectWatermark(inputPath: currentPath);

      setState(() => _statusText = "📝 Scraping de Letras (NLP)...");
      await ref.read(nlpWorkerProvider).processSingleFile(currentPath);

      setState(() => _statusText = "🎛️ Asignando Curvas ISAR...");
      final rawGenre = await rust_dsp.readAudioGenre(inputPath: currentPath);

      String assignedProfile = 'constant_power';
      int assignedDuration = 6000;

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

      if (rawGenre.isNotEmpty && rawGenre != 'desconocido') {
        for (final key in mixProfiles.keys) {
          if (rawGenre.contains(key)) {
            assignedProfile = mixProfiles[key]!['curve'] as String;
            assignedDuration = mixProfiles[key]!['durationMs'] as int;
            break;
          }
        }
      }

      setState(() => _statusText = "🎯 Calculando Cues...");
      final existingMeta = await ref
          .read(dbServiceProvider)
          .getTrackMetadata(currentPath);
      int? calculatedCueIn;
      int? calculatedMixOut;

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
              if (text.length < 4 ||
                  text.contains('🎵') ||
                  text.contains('♪') ||
                  text.startsWith('(') ||
                  text.startsWith('[')) {
                isGarbage = true;
              } else if (text.contains('instrumental') ||
                  text.contains('sync') ||
                  text.contains('lyric') ||
                  text.contains('letra no encontrada') ||
                  text.contains('error de conexión') ||
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
            int optimalBuffer = assignedDuration + 4000;
            calculatedCueIn = (firstVocalMs >= optimalBuffer)
                ? (firstVocalMs - optimalBuffer)
                : 0;
            calculatedMixOut = lastVocalMs + 4000;
          }
        } catch (_) {}
      }

      await ref
          .read(dbServiceProvider)
          .saveTrackMetadata(
            path: currentPath,
            mixProfile: assignedProfile,
            durationMs: assignedDuration,
            genre: rawGenre,
            cueInMs: existingMeta?.cueInMs ?? calculatedCueIn ?? 0,
            mixOutMs: existingMeta?.mixOutMs ?? calculatedMixOut,
          );

      setState(() => _statusText = "🥁 Indexando Caché...");
      await ref
          .read(dspWorkerProvider)
          .generateStaticBpmCache(Directory(currentPath).parent.path);

      setState(() => _statusText = "✅ ¡Track inyectado y listo para Automix!");
    } catch (e) {
      setState(
        () => _statusText = "⚠️ Descargado, pero falló el Auto-Master: $e",
      );
    }
  }

  Future<void> _extractLyricsFromYoutube(
    String videoUrl,
    String mp3Path,
  ) async {
    try {
      setState(
        () => _statusText = "Interceptando manifiesto de subtítulos nativos...",
      );
      final videoId = VideoId(videoUrl);
      final manifest = await _yt.videos.closedCaptions.getManifest(videoId);

      if (manifest.tracks.isEmpty) {
        debugPrint(
          "⚠️ VETO: El stream de YouTube no contiene pista de subtítulos.",
        );
        return;
      }

      ClosedCaptionTrackInfo? selectedTrack;
      final langs = ['es', 'en'];

      for (var lang in langs) {
        try {
          selectedTrack = manifest.tracks.firstWhere(
            (t) =>
                t.language.code.toLowerCase().contains(lang) &&
                !t.isAutoGenerated,
          );
          break;
        } catch (_) {}
      }
      if (selectedTrack == null) {
        for (var lang in langs) {
          try {
            selectedTrack = manifest.tracks.firstWhere(
              (t) => t.language.code.toLowerCase().contains(lang),
            );
            break;
          } catch (_) {}
        }
      }
      selectedTrack ??= manifest.tracks.first;

      final track = await _yt.videos.closedCaptions.get(selectedTrack);
      if (track.captions.isEmpty) return;

      final lrcBuffer = StringBuffer();
      for (var caption in track.captions) {
        final start = caption.offset;
        final min = start.inMinutes.toString().padLeft(2, '0');
        final sec = (start.inSeconds % 60).toString().padLeft(2, '0');
        final ms = ((start.inMilliseconds % 1000) ~/ 10).toString().padLeft(
          2,
          '0',
        );

        // 🛠️ NLP GARBAGE FILTER INYECTADO (Homologado con el Laboratorio)
        final text = caption.text
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
        final lowerText = text.toLowerCase();
        bool isGarbage = false;

        if (text.length <= 2) isGarbage = true;
        if (lowerText.contains(
          RegExp(
            r'\[música\]|\(música\)|\[aplausos\]|\(aplausos\)|instrumental|♪|🎵',
            caseSensitive: false,
          ),
        )) {
          isGarbage = true;
        }
        if (lowerText.startsWith('[') && lowerText.endsWith(']')) {
          isGarbage = true;
        }
        if (lowerText.startsWith('(') && lowerText.endsWith(')')) {
          isGarbage = true;
        }

        if (!isGarbage && text.isNotEmpty) {
          lrcBuffer.writeln('[$min:$sec.$ms]$text');
        }
      }

      if (lrcBuffer.isNotEmpty) {
        final lrcPath = mp3Path.replaceAll(
          RegExp(r'\.mp3$', caseSensitive: false),
          '.lrc',
        );
        await File(lrcPath).writeAsString(lrcBuffer.toString());
        setState(
          () => _statusText = "✅ Letra purificada (.lrc) inyectada con éxito.",
        );
      }
    } catch (e) {
      debugPrint("🔴 [I/O Scraper Error]: $e");
    }
  }

  Future<void> _executeDirectDownload(String targetUrl) async {
    if (_selectedFolderPath.isEmpty) {
      setState(
        () => _statusText =
            "🔴 ERROR: Selecciona una carpeta de destino primero.",
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusText = "Resolviendo firmas DRM e iniciando extracción...";
    });

    try {
      final tempDir = Directory.systemTemp;
      final ytdlpPath = '${tempDir.path}${Platform.pathSeparator}yt-dlp.exe';
      final downloadPath = _selectedFolderPath;

      if (!Directory(downloadPath).existsSync()) {
        Directory(downloadPath).createSync(recursive: true);
      }

      if (Platform.isWindows && !File(ytdlpPath).existsSync()) {
        setState(
          () => _statusText = "Descargando motor extractor (yt-dlp.exe)...",
        );
        final url = Uri.parse(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        );
        final response = await http.get(url);
        await File(ytdlpPath).writeAsBytes(response.bodyBytes);
      }

      final process = await Process.start(ytdlpPath, [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=default',
        '-o',
        '$downloadPath${Platform.pathSeparator}%(title)s.%(ext)s',
        targetUrl,
      ]);

      // 🔴 FIX ARCH: Drenaje pasivo de búferes OS para evitar el Deadlock
      process.stdout.listen((_) {});
      process.stderr.listen((_) {});

      String? extractedMp3Path;

      // Un escaneo de la ruta final a través de la carpeta de destino:
      final exitCode = await process.exitCode;

      if (exitCode == 0) {
        // Dado que yt-dlp guarda la pista con un formato dinámico, escaneamos la carpeta
        // buscando el archivo más reciente (el que acabamos de descargar).
        final files = Directory(downloadPath)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.mp3'))
            .toList();
        if (files.isNotEmpty) {
          files.sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
          extractedMp3Path = files.first.path;
        }

        _searchController.clear();
        if (extractedMp3Path != null && File(extractedMp3Path).existsSync()) {
          await _extractLyricsFromYoutube(targetUrl, extractedMp3Path);
          if (_autoMasterize) {
            await _runSingleTrackPipeline(extractedMp3Path);
          } else {
            setState(
              () => _statusText =
                  "✅ ¡Extracción Completada! MP3 crudo y Letra guardados.",
            );
          }
        } else {
          setState(
            () => _statusText = "✅ ¡Extracción Completada! (Ruta no trazable)",
          );
        }
      } else {
        throw Exception("El binario CLI colapsó con código $exitCode.");
      }
    } catch (e) {
      setState(() => _statusText = "🔴 ERROR FATAL: $e");
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 500;

        final Widget configBar = Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: const Color(0xFF00FFFF).withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, color: Color(0xFF00FFFF), size: 20),
              const SizedBox(width: 10),
              const Text(
                "Destino:",
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: InkWell(
                  onTap: _isProcessing ? null : _showFolderSelectionDialog,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      border: Border.all(color: Colors.white10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selectedFolderPath.isEmpty
                                ? "Seleccionar carpeta..."
                                : _selectedFolderPath,
                            style: const TextStyle(
                              color: Color(0xFF00FFFF),
                              fontFamily: 'Consolas',
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.arrow_drop_down,
                          color: Color(0xFF00FFFF),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: Colors.white24,
                margin: const EdgeInsets.symmetric(horizontal: 15),
              ),
              Tooltip(
                message:
                    "Ejecuta limpieza, NDK Trim, Sello de agua y descarga letras automáticamente.",
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: Color(0xFF39FF14),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      "Auto-Master",
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    Switch(
                      value: _autoMasterize,
                      activeThumbColor: const Color(0xFF39FF14),
                      inactiveThumbColor: Colors.white54,
                      inactiveTrackColor: Colors.white10,
                      onChanged: _isProcessing
                          ? null
                          : (val) => setState(() => _autoMasterize = val),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        final Widget searchBar = Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                enabled: !_isProcessing,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText:
                      "Nombre de canción o https://www.youtube.com/watch?v=...",
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black,
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF00FFFF)),
                    borderRadius: BorderRadius.circular(4.0),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search, color: Color(0xFF00FFFF)),
                    onPressed: _isProcessing
                        ? null
                        : () => _handleInput(_searchController.text.trim()),
                  ),
                ),
                onSubmitted: _isProcessing
                    ? null
                    : (val) => _handleInput(val.trim()),
              ),
            ),
          ],
        );

        final Widget statusBar = Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: const Color(0xFF333333)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _statusText,
            style: TextStyle(
              color: _statusText.contains("ERROR")
                  ? Colors.redAccent
                  : const Color(0xFF39FF14),
              fontFamily: 'Consolas',
              fontSize: 13,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );

        final Widget resultsList = ListView.builder(
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final video = _results[index];
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: ListTile(
                leading: const Icon(
                  Icons.youtube_searched_for,
                  color: Color(0xFF00FFFF),
                ),
                title: Text(
                  video.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  "${video.author} • ${video.duration?.inMinutes ?? 0}:${((video.duration?.inSeconds ?? 0) % 60).toString().padLeft(2, '0')}",
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text("Ingestar"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFFF),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _isProcessing
                      ? null
                      : () => _executeDirectDownload(
                          'https://youtube.com/watch?v=${video.id.value}',
                        ),
                ),
              ),
            );
          },
        );

        if (isMobileLandscape) {
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(15.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Buscador Global & Extracción",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00FFFF),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 20),
                configBar,
                const SizedBox(height: 15),
                searchBar,
                const SizedBox(height: 15),
                statusBar,
                const SizedBox(height: 15),
                if (_results.isNotEmpty)
                  SizedBox(height: 250, child: resultsList),
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
                "Buscador Global & Extracción",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00FFFF),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Busca pistas en la red o pega una URL para inyectarla directamente al disco duro en formato MP3 (320kbps).",
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 25),
              configBar,
              const SizedBox(height: 20),
              searchBar,
              const SizedBox(height: 20),
              statusBar,
              const SizedBox(height: 20),
              if (_results.isNotEmpty) Expanded(child: resultsList),
            ],
          ),
        );
      },
    );
  }
}
