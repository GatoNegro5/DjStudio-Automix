import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/directory_provider.dart';
import 'providers/player_provider.dart';
import 'providers/pipeline_provider.dart';
import 'providers/dsp_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'; // 🛠️ FIX: Faltaba esta dependencia

// =====================================================================
// ROUTE 0: UNIFIED DJ WORKSPACE (IDE 3-PANEL REKORDBOX STYLE)
// =====================================================================
class UnifiedDjWorkspace extends StatefulWidget {
  const UnifiedDjWorkspace({super.key});

  @override
  State<UnifiedDjWorkspace> createState() => _UnifiedDjWorkspaceState();
}

class _UnifiedDjWorkspaceState extends State<UnifiedDjWorkspace> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;
    final isMobileLandscape = size.height < 500;

    // 🛠️ PANEL INFERIOR (COMPRESIÓN HORIZONTAL APLICADA)
    final Widget desktopBottomPanels = Row(
      children: [
        Material(
          color: const Color(0xFF0A0A0A),
          // 🛠️ El Explorador se reduce a 150px en celulares
          child: SizedBox(
            width: isMobileLandscape ? 150 : 220,
            child: const LibraryTreePanel(),
          ),
        ),
        const VerticalDivider(width: 1, color: Colors.white10),
        const Expanded(flex: 4, child: FolderContentPanel()),
        const VerticalDivider(width: 1, color: Colors.white10),
        const Expanded(flex: 5, child: AutomixPanel()),
      ],
    );

    if (isDesktop) {
      return Column(
        children: [
          const Expanded(flex: 4, child: MixerPanel()),
          const Divider(height: 1, color: Colors.white10),
          Expanded(flex: 5, child: desktopBottomPanels),
        ],
      );
    }

    // 🛠️ MÓVIL: RECALIBRACIÓN VERTICAL (EJE Y)
    return SafeArea(
      child: Column(
        children: [
          // 🛠️ 65% DE ALTURA PARA EL MIXER (GARANTIZA ESPACIO PARA 2+ LÍNEAS DE LETRA)
          const Expanded(flex: 65, child: MixerPanel()),
          const Divider(height: 1, color: Colors.white10),
          // 🛠️ 35% DE ALTURA PARA EL EXPLORADOR Y AUTOMIX
          Expanded(
            flex: 35,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                // 🛠️ MATRIZ REDUCIDA A 800px (Elimina casi por completo el scroll horizontal)
                width: 800,
                child: desktopBottomPanels,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- COMPONENTE 1: ÁRBOL DE DIRECTORIOS ---
class LibraryTreePanel extends ConsumerStatefulWidget {
  const LibraryTreePanel({super.key});

  @override
  ConsumerState<LibraryTreePanel> createState() => _LibraryTreePanelState();
}

class _LibraryTreePanelState extends ConsumerState<LibraryTreePanel> {
  String _rootPath = '';
  List<Directory> _subDirs = [];

  @override
  void initState() {
    super.initState();
    _initializeRoot();
  }

  void _initializeRoot() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      _rootPath = userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    } else if (Platform.isAndroid) {
      _rootPath = '/storage/emulated/0/Music';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      _rootPath = home != null ? '$home/Music' : '/';
    } else {
      _rootPath = '/';
    }
    _loadSubDirs();
  }

  void _loadSubDirs() {
    final dir = Directory(_rootPath);
    try {
      if (dir.existsSync()) {
        setState(() {
          _subDirs = dir.listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path));
        });
      }
    } catch (e) {
      debugPrint(
        "⚠️ [I/O ERROR]: Acceso denegado o ruta inválida en $_rootPath: $e",
      );
      setState(() {
        _subDirs = [];
      });
    }
  }

  Future<void> _changeRootDirectory() async {
    await ref.read(directoryProvider.notifier).loadDirectory();
    final newPath = ref.read(directoryProvider).currentPath;
    if (newPath.isNotEmpty && newPath != _rootPath) {
      setState(() {
        _rootPath = newPath;
        _loadSubDirs();
      });
    }
  }

  // 🛠️ INYECCIÓN: El nodo ahora exige conocer la lista de rutas expandidas desde RAM
  Widget _buildFolderNode(Directory dir, int depth, Set<String> expandedPaths) {
    List<Directory> childDirs = [];
    try {
      childDirs = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {}

    if (childDirs.isEmpty || depth >= 2) {
      return Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -4),
          minVerticalPadding: 0,
          contentPadding: EdgeInsets.only(
            left: 15.0 + (depth * 15.0),
            right: 10.0,
          ),
          leading: const Icon(Icons.folder, color: Colors.white54, size: 16),
          title: Text(
            dir.path.replaceAll('\\', '/').split('/').last,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => ref.read(directoryProvider.notifier).scanPath(dir.path),
          hoverColor: Colors.white10,
        ),
      );
    }

    final isExpanded = expandedPaths.contains(dir.path);

    return Theme(
      data: ThemeData(
        dividerColor: Colors.transparent,
        listTileTheme: const ListTileThemeData(
          dense: true,
          visualDensity: VisualDensity(vertical: -4),
          minVerticalPadding: 0,
        ),
      ),
      child: ExpansionTile(
        // 🛠️ FIX: Forzamos el repintado inyectando el estado en la Key.
        // Si el JSON dice "Abierto", Flutter reconstruirá el widget acatando la orden.
        key: Key('${dir.path}_$isExpanded'),
        initiallyExpanded: isExpanded,
        onExpansionChanged: (expanded) {
          // 🛠️ DISPARADOR: Comunica a Riverpod y salva el JSON
          ref.read(directoryProvider.notifier).toggleNode(dir.path, expanded);
        },
        tilePadding: EdgeInsets.only(left: 15.0 + (depth * 15.0), right: 10.0),
        leading: const Icon(
          Icons.folder_open,
          color: Color(0xFF00FFFF),
          size: 16,
        ),
        title: Text(
          dir.path.replaceAll('\\', '/').split('/').last,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: childDirs
            .map(
              (childDir) =>
                  _buildFolderNode(childDir, depth + 1, expandedPaths),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 🛠️ ESCUCHA: Riverpod le inyecta la memoria visual al componente padre
    final expandedPaths = ref.watch(
      directoryProvider.select((s) => s.expandedPaths),
    );
    // 🛠️ SENSOR DE HARDWARE
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(isMobile ? 6.0 : 12.0), // Compresión Y
          decoration: const BoxDecoration(
            color: Colors.black,
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Explorador",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: isMobile ? 11 : 13,
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.add_to_drive,
                  color: const Color(0xFF00FFFF),
                  size: isMobile ? 15 : 18,
                ),
                onPressed: _changeRootDirectory,
                tooltip: "Cambiar Raíz",
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        Expanded(
          child: _subDirs.isEmpty
              ? const Center(
                  child: Text(
                    "Vacío",
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: _subDirs.length,
                  itemBuilder: (context, index) => _buildFolderNode(
                    _subDirs[index],
                    0,
                    expandedPaths,
                  ), // 🛠️ Paso del estado por cascada
                ),
        ),
      ],
    );
  }
}

// 🛠️ ESTADOS GLOBALES DE GESTIÓN AUTOMIX Y RECORD
enum TrackSortMode { alphabetical, bpmDesc, bpmAsc }

class TrackSortNotifier extends Notifier<TrackSortMode> {
  @override
  TrackSortMode build() => TrackSortMode.alphabetical;
  void updateMode(TrackSortMode mode) => state = mode;
}

final trackSortProvider = NotifierProvider<TrackSortNotifier, TrackSortMode>(
  TrackSortNotifier.new,
);

class PlayedTracksNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    _loadSession();
    return {};
  }

  String _getSessionFilePath() {
    String baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseDir = userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isAndroid) {
      baseDir = '/storage/emulated/0/Music/DjPlaylists';
    } else {
      final home = Platform.environment['HOME'];
      baseDir = home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_played_tracks_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as List<dynamic>;
        state = data.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
  }

  Future<void> _saveSession(Set<String> currentPlayed) async {
    try {
      final file = File(_getSessionFilePath());
      await file.writeAsString(jsonEncode(currentPlayed.toList()));
    } catch (_) {}
  }

  void addTrack(String track) {
    if (!state.contains(track)) {
      final newState = {...state, track};
      state = newState;
      _saveSession(newState);
    }
  }

  void removeTrack(String track) {
    if (state.contains(track)) {
      final newState = Set<String>.from(state);
      newState.remove(track);
      state = newState;
      _saveSession(newState);
    }
  }
}

final playedTracksProvider =
    NotifierProvider<PlayedTracksNotifier, Set<String>>(
      PlayedTracksNotifier.new,
    );

class AutomixQueueNotifier extends Notifier<List<File>> {
  @override
  List<File> build() {
    _loadSession();
    return [];
  }

  String _getSessionFilePath() {
    String baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseDir = userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isAndroid) {
      baseDir = '/storage/emulated/0/Music/DjPlaylists';
    } else {
      final home = Platform.environment['HOME'];
      baseDir = home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_automix_session.json';
  }

  Future<void> _loadSession() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as List<dynamic>;
        List<File> files = [];
        for (String p in data) {
          if (File(p).existsSync()) files.add(File(p));
        }
        state = files;
      }
    } catch (_) {}
  }

  Future<void> _saveSession(List<File> currentQueue) async {
    try {
      final file = File(_getSessionFilePath());
      final paths = currentQueue.map((f) => f.path).toList();
      await file.writeAsString(jsonEncode(paths));
    } catch (_) {}
  }

  void addTrack(File file) {
    final newState = state.where((f) => f.path != file.path).toList();
    newState.add(file);
    state = newState;
    _saveSession(newState);
  }

  void addAll(List<File> files) {
    var newState = List<File>.from(state);
    for (var f in files) {
      newState.removeWhere((existing) => existing.path == f.path);
      newState.add(f);
    }
    state = newState;
    _saveSession(newState);
  }

  void removeTrack(String path) {
    final newState = state.where((f) => f.path != path).toList();
    state = newState;
    _saveSession(newState);
  }

  void clearQueue() {
    state = [];
    _saveSession([]);
  }

  void restoreQueue(List<String> paths) {
    List<File> files = [];
    for (String p in paths) {
      if (File(p).existsSync()) files.add(File(p));
    }
    state = files;
    _saveSession(files);
  }
}

final automixProvider = NotifierProvider<AutomixQueueNotifier, List<File>>(
  AutomixQueueNotifier.new,
);

class BpmCacheNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => {};

  Future<void> loadCache(String directoryPath) async {
    if (directoryPath.isEmpty) {
      state = {};
      return;
    }
    try {
      await ref.read(dspWorkerProvider).generateStaticBpmCache(directoryPath);
    } catch (_) {}

    final file = File(
      '$directoryPath${Platform.pathSeparator}_dj_metadata.json',
    );
    if (file.existsSync()) {
      try {
        final content = await file.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final Map<String, double> newCache = {};

        decoded.forEach((key, value) {
          if (value is num) {
            newCache[key] = value.toDouble();
          } else if (value is Map && value['bpm'] != null) {
            newCache[key] = (value['bpm'] as num).toDouble();
          }
        });
        state = newCache;
      } catch (e) {
        state = {};
      }
    } else {
      state = {};
    }
  }
}

final bpmCacheProvider =
    NotifierProvider<BpmCacheNotifier, Map<String, double>>(
      BpmCacheNotifier.new,
    );

class WasapiRecordNotifier extends Notifier<bool> {
  Process? _recordingProcess;
  String? _currentOutputPath;
  String _lastErrorLog = "";

  @override
  bool build() => false;

  Future<void> toggleRecording(BuildContext context) async {
    if (state) {
      await stopRecording(context);
    } else {
      await startRecording(context);
    }
  }

  String _getFFmpegPath() {
    if (Platform.isAndroid || Platform.isIOS) return 'ffmpeg';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final localFFmpeg = Platform.isWindows
        ? '$exeDir\\ffmpeg.exe'
        : '$exeDir/ffmpeg';
    if (File(localFFmpeg).existsSync()) return localFFmpeg;
    return 'ffmpeg';
  }

  Future<String> _getLoopbackDevice() async {
    if (Platform.isWindows) {
      try {
        final process = await Process.run(_getFFmpegPath(), [
          '-list_devices',
          'true',
          '-f',
          'dshow',
          '-i',
          'dummy',
        ]);
        final logs = process.stderr.toString();
        final lines = logs.split('\n');

        for (int i = 0; i < lines.length; i++) {
          final lowerLine = lines[i].toLowerCase();
          if (lowerLine.contains('(audio)') &&
              (lowerLine.contains('mezcla') ||
                  lowerLine.contains('estéreo') ||
                  lowerLine.contains('stereo'))) {
            if (i + 1 < lines.length &&
                lines[i + 1].toLowerCase().contains('alternative name')) {
              final match = RegExp(r'"([^"]+)"').firstMatch(lines[i + 1]);
              if (match != null) return 'audio=${match.group(1)!}';
            }
          }
        }
      } catch (_) {}
      return r'audio=@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_{E2847FF6-6193-463E-848F-0E16C78BD2EA}';
    } else if (Platform.isMacOS) {
      return ':0';
    } else {
      throw UnsupportedError(
        'Driver de loopback no soportado en esta plataforma.',
      );
    }
  }

  Future<void> startRecording(BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      if (context.mounted) {
        _showErrorDialog(
          context,
          "VETO TÉCNICO: Sandbox Restringido",
          "La captura del Master Out en Android/iOS está bloqueada a nivel de Kernel por políticas de privacidad. Se requiere migrar a APIs nativas (MediaProjection/ReplayKit).",
        );
      }
      return;
    }

    final userProfile =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final baseDir = Platform.isWindows
        ? '$userProfile\\Music\\GrabacionesDj'
        : '$userProfile/Music/GrabacionesDj';

    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final dateStr = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    _currentOutputPath =
        '${dir.path}${Platform.pathSeparator}LiveMix_$dateStr.mp3';
    _lastErrorLog = "";

    try {
      final deviceName = await _getLoopbackDevice();
      final format = Platform.isWindows ? 'dshow' : 'avfoundation';

      debugPrint(
        "🟢 [Hardware Tracker] Ruteando bus maestro a: $deviceName ($format)",
      );

      final args = [
        '-y',
        '-f',
        format,
        '-i',
        deviceName,
        '-c:a',
        'libmp3lame',
        '-b:a',
        '320k',
        _currentOutputPath!,
      ];

      _recordingProcess = await Process.start(_getFFmpegPath(), args);
      state = true;

      _recordingProcess!.stderr.transform(utf8.decoder).listen((log) {
        _lastErrorLog += log;
      });

      _recordingProcess!.exitCode.then((code) {
        if (code != 0 && code != 255 && state) {
          state = false;
          if (context.mounted) {
            _showErrorDialog(
              context,
              "🔴 VETO TÉCNICO: FFmpeg Colapsó",
              _lastErrorLog,
            );
          }
        }
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '🔴 GRABANDO MASTER OUT: LiveMix_$dateStr.mp3',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 [RECORD FATAL]: $e");
    }
  }

  Future<void> stopRecording(BuildContext context) async {
    if (_recordingProcess != null) {
      _recordingProcess!.stdin.writeln('q');
      await Future.delayed(const Duration(milliseconds: 500));
      _recordingProcess!.kill();
      _recordingProcess = null;
    }

    state = false;

    final file = File(_currentOutputPath ?? '');
    final fileExists = file.existsSync() && file.lengthSync() > 0;

    if (context.mounted) {
      if (fileExists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Mezcla renderizada en: $_currentOutputPath',
              style: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: const Color(0xFF39FF14),
            duration: const Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '❌ ERROR: Archivo vacío o I/O bloqueado.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.redAccent,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showErrorDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Colors.redAccent),
          borderRadius: BorderRadius.circular(8),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.redAccent,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: SingleChildScrollView(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'Consolas',
                fontSize: 11,
              ),
            ),
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
      ),
    );
  }
}

final wasapiRecordProvider = NotifierProvider<WasapiRecordNotifier, bool>(
  WasapiRecordNotifier.new,
);

// --- COMPONENTE 2: BROWSER (Contenido Bruto de la Carpeta) ---
class FolderContentPanel extends ConsumerWidget {
  const FolderContentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final bpmCache = ref.watch(bpmCacheProvider);
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    ref.listen<String>(directoryProvider.select((d) => d.currentPath), (
      previous,
      next,
    ) {
      if (next != previous) ref.read(bpmCacheProvider.notifier).loadCache(next);
    });

    double getTrackBpm(String filename) {
      if (bpmCache.containsKey(filename)) return bpmCache[filename]!;
      final match = RegExp(
        r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
        caseSensitive: false,
      ).firstMatch(filename);
      return match != null ? double.parse(match.group(1)!) : 0.0;
    }

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: const Color(0xFF141414),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  dirState.currentPath.isEmpty
                      ? "Selecciona carpeta..."
                      : dirState.currentPath
                            .replaceAll('\\', '/')
                            .split('/')
                            .last,
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 11 : 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton.icon(
                onPressed: dirState.files.isEmpty
                    ? null
                    : () {
                        for (var f in dirState.files) {
                          ref
                              .read(playedTracksProvider.notifier)
                              .removeTrack(f.path);
                        }
                        ref
                            .read(automixProvider.notifier)
                            .addAll(dirState.files);
                      },
                icon: Icon(Icons.playlist_add, size: isMobile ? 14 : 16),
                label: Text(
                  "Cargar Todo",
                  style: TextStyle(fontSize: isMobile ? 10 : 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: const Color(0xFF39FF14),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(
                    0,
                    isMobile ? 24 : 30,
                  ), // Compresión de botón
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: dirState.files.isEmpty
              ? const Center(
                  child: Text(
                    "Carpeta vacía o sin MP3.",
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: dirState.files.length,
                  itemBuilder: (context, index) {
                    final file = dirState.files[index];
                    final fileName = file.uri.pathSegments.last;
                    final bpm = getTrackBpm(fileName);

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: const Icon(
                          Icons.audiotrack,
                          color: Colors.white24,
                          size: 18,
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              bpm > 0
                                  ? "${bpm.toStringAsFixed(1)} BPM"
                                  : "--- BPM",
                              style: TextStyle(
                                color: bpm > 0
                                    ? Colors.white54
                                    : Colors.white24,
                                fontFamily: 'Consolas',
                                fontSize: 10,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                color: Color(0xFF00FFFF),
                                size: 20,
                              ),
                              onPressed: () {
                                ref
                                    .read(playedTracksProvider.notifier)
                                    .removeTrack(file.path);
                                ref
                                    .read(automixProvider.notifier)
                                    .addTrack(file);
                              },
                              tooltip: "Añadir al Automix",
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// --- COMPONENTE 3: AUTOMIX (AISLADO PARA PERFORMANCE) ---
class AutomixPanel extends ConsumerWidget {
  const AutomixPanel({super.key});

  String _getPlaylistsDir() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      return userProfile != null
          ? '$userProfile\\Music\\DjPlaylists'
          : 'C:\\Music\\DjPlaylists';
    } else if (Platform.isAndroid) {
      return '/storage/emulated/0/Music/DjPlaylists';
    } else {
      final home = Platform.environment['HOME'];
      return home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    }
  }

  Future<void> _playLocalTrack(
    WidgetRef ref,
    List<String> playlist,
    int index,
  ) async {
    try {
      await ref
          .read(playerProvider.notifier)
          .loadContextAndPlay(playlist, index);
    } catch (e) {
      debugPrint("🔴 [TRACKER ERROR FATAL]: $e");
    }
  }

  Future<void> _saveAutomixQueue(
    BuildContext context,
    List<File> currentQueue,
  ) async {
    if (currentQueue.isEmpty) return;
    try {
      final baseDir = _getPlaylistsDir();
      final dir = Directory(baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final dateStr = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;

      final sep = Platform.isWindows ? '\\' : '/';
      final file = File('$baseDir${sep}Set_$dateStr.json');

      final paths = currentQueue.map((f) => f.path).toList();
      await file.writeAsString(jsonEncode({"playlist": paths}));

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lista serializada: Set_$dateStr.json',
              style: const TextStyle(
                color: Color(0xFF39FF14),
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
            backgroundColor: const Color(0xFF181818),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadAutomixQueue(BuildContext context, WidgetRef ref) async {
    try {
      final baseDir = _getPlaylistsDir();
      final dir = Directory(baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (files.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No existen Playlists guardadas.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              backgroundColor: Colors.black,
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121212),
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFFF007F)),
                borderRadius: BorderRadius.circular(8),
              ),
              title: const Text(
                "Librería de Sets (Playlists)",
                style: TextStyle(
                  color: Color(0xFFFF007F),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              content: SizedBox(
                width: 400,
                height: 400,
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final fileName = file.path
                        .replaceAll('\\', '/')
                        .split('/')
                        .last
                        .replaceAll('.json', '');
                    final date = file.lastModifiedSync();
                    final dateString =
                        "${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        leading: const Icon(
                          Icons.queue_music,
                          color: Color(0xFF39FF14),
                        ),
                        title: Text(
                          fileName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          dateString,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                            size: 18,
                          ),
                          onPressed: () {
                            file.deleteSync();
                            Navigator.pop(dialogContext);
                            _loadAutomixQueue(context, ref);
                          },
                        ),
                        onTap: () async {
                          try {
                            final content = await file.readAsString();
                            final data =
                                jsonDecode(content) as Map<String, dynamic>;
                            final List<dynamic> rawPaths =
                                data['playlist'] ?? [];
                            final List<String> paths = rawPaths
                                .map((e) => e.toString())
                                .toList();
                            ref
                                .read(automixProvider.notifier)
                                .restoreQueue(paths);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } catch (_) {}
                        },
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text(
                    "Cerrar",
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            );
          },
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrackPath = ref.watch(
      playerProvider.select((p) => p.currentTrackPath),
    );
    final isPlaying = ref.watch(playerProvider.select((p) => p.isPlaying));
    final playerNotifier = ref.read(playerProvider.notifier);

    final automixQueue = ref.watch(automixProvider);
    final sortMode = ref.watch(trackSortProvider);
    final playedTracks = ref.watch(playedTracksProvider);
    final bpmCache = ref.watch(bpmCacheProvider);
    final isBusy = ref.watch(pipelineProvider.select((p) => !p.isIdle));
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    ref.listen<String?>(playerProvider.select((p) => p.currentTrackPath), (
      previous,
      next,
    ) {
      if (next != null && !playedTracks.contains(next)) {
        Future.microtask(
          () => ref.read(playedTracksProvider.notifier).addTrack(next),
        );
      }
    });

    List<File> displayFiles = List.from(automixQueue);
    displayFiles.removeWhere(
      (file) =>
          playedTracks.contains(file.path) && file.path != currentTrackPath,
    );

    double getTrackBpm(String filename) {
      if (bpmCache.containsKey(filename)) return bpmCache[filename]!;
      final match = RegExp(
        r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
        caseSensitive: false,
      ).firstMatch(filename);
      return match != null ? double.parse(match.group(1)!) : 0.0;
    }

    if (sortMode == TrackSortMode.alphabetical) {
      displayFiles.sort(
        (a, b) => a.uri.pathSegments.last.toLowerCase().compareTo(
          b.uri.pathSegments.last.toLowerCase(),
        ),
      );
    } else if (sortMode == TrackSortMode.bpmDesc) {
      displayFiles.sort(
        (a, b) => getTrackBpm(
          b.uri.pathSegments.last,
        ).compareTo(getTrackBpm(a.uri.pathSegments.last)),
      );
    } else if (sortMode == TrackSortMode.bpmAsc) {
      displayFiles.sort(
        (a, b) => getTrackBpm(
          a.uri.pathSegments.last,
        ).compareTo(getTrackBpm(b.uri.pathSegments.last)),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isPlaying || currentTrackPath != null) {
        final currentOrderedPaths = displayFiles.map((f) => f.path).toList();
        playerNotifier.syncDynamicPlaylist(currentOrderedPaths);
      }
    });

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: const Color(0xFF1A1A1A),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shuffle,
                    color: const Color(0xFFFF007F),
                    size: isMobile ? 14 : 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "AUTOMIX (${displayFiles.length})",
                    style: TextStyle(
                      color: const Color(0xFFFF007F),
                      fontWeight: FontWeight.bold,
                      fontSize: isMobile ? 11 : 13,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 15),
                  if (automixQueue.isNotEmpty) ...[
                    IconButton(
                      icon: Icon(
                        Icons.delete_sweep,
                        color: Colors.redAccent,
                        size: isMobile ? 14 : 16,
                      ),
                      onPressed: () =>
                          ref.read(automixProvider.notifier).clearQueue(),
                      tooltip: "Limpiar Cola",
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.save,
                        color: const Color(0xFF00FFFF),
                        size: isMobile ? 14 : 16,
                      ),
                      onPressed: () => _saveAutomixQueue(context, automixQueue),
                      tooltip: "Guardar Lista en Disco",
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                    ),
                  ],
                  IconButton(
                    icon: Icon(
                      Icons.folder_open,
                      color: const Color(0xFF39FF14),
                      size: isMobile ? 14 : 16,
                    ),
                    onPressed: () => _loadAutomixQueue(context, ref),
                    tooltip: "Cargar Lista",
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<TrackSortMode>(
                    initialValue: sortMode,
                    icon: Icon(
                      Icons.sort,
                      color: Colors.white70,
                      size: isMobile ? 16 : 20,
                    ),
                    color: const Color(0xFF121212),
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(color: Color(0xFFFF007F)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    tooltip: "Ordenar Automix",
                    onSelected: (mode) =>
                        ref.read(trackSortProvider.notifier).updateMode(mode),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: TrackSortMode.alphabetical,
                        child: Text(
                          "Alfabético (A-Z)",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      PopupMenuItem(
                        value: TrackSortMode.bpmDesc,
                        child: Text(
                          "BPM (Mayor a Menor)",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                      PopupMenuItem(
                        value: TrackSortMode.bpmAsc,
                        child: Text(
                          "BPM (Menor a Mayor)",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 5),

                  ElevatedButton.icon(
                    onPressed: displayFiles.isEmpty || isBusy
                        ? null
                        : () {
                            final allPaths = displayFiles
                                .map((f) => f.path)
                                .toList();
                            _playLocalTrack(ref, allPaths, 0);
                          },
                    icon: Icon(Icons.play_arrow, size: isMobile ? 14 : 16),
                    label: Text(
                      "PLAY",
                      style: TextStyle(
                        fontSize: isMobile ? 10 : 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF007F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 15),
                      minimumSize: Size(0, isMobile ? 24 : 30),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: displayFiles.isEmpty
              ? const Center(
                  child: Text(
                    "La cola Automix está vacía.\nAñade pistas o carga una Playlist guardada.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: displayFiles.length,
                  itemBuilder: (context, index) {
                    final file = displayFiles[index];
                    final fileName = file.uri.pathSegments.last;
                    final isPlayingThisTrack = currentTrackPath == file.path;
                    final bpm = getTrackBpm(fileName);

                    return Material(
                      color: isPlayingThisTrack
                          ? const Color(0xFF1F000F)
                          : Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: Icon(
                          isPlayingThisTrack
                              ? Icons.volume_up
                              : Icons.drag_handle,
                          color: isPlayingThisTrack
                              ? const Color(0xFFFF007F)
                              : Colors.white24,
                          size: 18,
                        ),
                        title: Text(
                          fileName,
                          style: TextStyle(
                            color: isPlayingThisTrack
                                ? const Color(0xFFFF007F)
                                : Colors.white,
                            fontWeight: isPlayingThisTrack
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              bpm > 0 ? bpm.toStringAsFixed(1) : "---",
                              style: TextStyle(
                                color: bpm > 0
                                    ? const Color(0xFFFF007F)
                                    : Colors.white24,
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (!isPlayingThisTrack)
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.redAccent,
                                  size: 18,
                                ),
                                onPressed: () => ref
                                    .read(automixProvider.notifier)
                                    .removeTrack(file.path),
                                tooltip: "Quitar",
                              ),

                            // 🛠️ FIX RADICAL: Removido 'isBusy' del condicional. Forzado de HitTest.
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (isPlayingThisTrack) {
                                  playerNotifier.togglePlayPause();
                                } else {
                                  final allPaths = displayFiles
                                      .map((f) => f.path)
                                      .toList();
                                  _playLocalTrack(ref, allPaths, index);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Icon(
                                  (isPlayingThisTrack && isPlaying)
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: const Color(0xFF39FF14),
                                  size: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// --- COMPONENTE: MEZCLADORA (AISLADA PARA PERFORMANCE) ---
class MixerPanel extends ConsumerStatefulWidget {
  const MixerPanel({super.key});

  @override
  ConsumerState<MixerPanel> createState() => _MixerPanelState();
}

class _MixerPanelState extends ConsumerState<MixerPanel> {
  final FixedExtentScrollController _lyricsController =
      FixedExtentScrollController();

  @override
  void dispose() {
    _lyricsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentTrackPath = ref.watch(
      playerProvider.select((s) => s.currentTrackPath),
    );
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final lyrics = ref.watch(playerProvider.select((s) => s.lyrics));
    final mixStrategy = ref.watch(playerProvider.select((s) => s.mixStrategy));
    final autoMixArmed = ref.watch(
      playerProvider.select((s) => s.autoMixArmed),
    );
    final isRecording = ref.watch(wasapiRecordProvider);
    final playerNotifier = ref.read(playerProvider.notifier);

    ref.listen<int>(playerProvider.select((state) => state.activeLyricIndex), (
      previous,
      next,
    ) {
      if (next >= 0 && _lyricsController.hasClients) {
        _lyricsController.animateToItem(
          next,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });

    String displayTitle = "Esperando pista...";
    if (currentTrackPath != null) {
      displayTitle = currentTrackPath.replaceAll('\\', '/').split('/').last;
    }

    String displaySubtitle = isPlaying
        ? (lyrics.isEmpty
              ? "⚠️ Letras no encontradas. Usa 'Mejorar Pista'."
              : "Reproduciendo (Mezcla Semántica Activa)")
        : (currentTrackPath != null
              ? "Pista en Pausa"
              : "Motor libmpv en espera");

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobileLandscape = constraints.maxHeight < 400;

        return Padding(
          padding: EdgeInsets.all(isMobileLandscape ? 5.0 : 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0A0A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isRecording
                          ? Colors.redAccent.withValues(alpha: 0.5)
                          : Colors.white10,
                    ),
                  ),
                  child: LyricsSyncPanel(
                    title: displayTitle,
                    hasLyrics: lyrics.isNotEmpty,
                    noLyricsWidget: Center(
                      child: Text(
                        displaySubtitle,
                        style: TextStyle(
                          color: isPlaying
                              ? const Color(0xFFFF007F)
                              : Colors.white54,
                          fontSize: 14,
                          fontWeight: isPlaying
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    onSync: () => playerNotifier.autoSyncFirstLyric(),
                    onSyncMed: () => playerNotifier.autoSyncFromCurrentLyric(),
                    // 🛠️ FIX RADICAL: ShaderMask destruido. Renderizado directo a la GPU.
                    lyricsWidget: ListWheelScrollView(
                      controller: _lyricsController,
                      itemExtent: isMobileLandscape ? 22.0 : 32.0,
                      diameterRatio: 10.0,
                      perspective: 0.0001,
                      physics: const NeverScrollableScrollPhysics(),
                      children: List.generate(lyrics.length, (index) {
                        return Consumer(
                          builder: (context, ref, _) {
                            final activeIdx = ref.watch(
                              playerProvider.select((s) => s.activeLyricIndex),
                            );
                            final isCurrent = index == activeIdx;
                            final isNext = index == activeIdx + 1;
                            final isPassed = index < activeIdx;

                            Color textColor;
                            double fontSize;
                            FontWeight fontWeight;

                            if (isCurrent) {
                              textColor = const Color(0xFF39FF14);
                              fontSize = isMobileLandscape ? 13 : 19;
                              fontWeight = FontWeight.bold;
                            } else if (isNext) {
                              textColor = Colors.white.withValues(alpha: 0.95);
                              fontSize = isMobileLandscape ? 11 : 14;
                              fontWeight = FontWeight.w600;
                            } else {
                              // El color ya tiene opacidad (white38), logrando el desvanecimiento sin usar shaders
                              textColor = Colors.white38;
                              fontSize = isMobileLandscape ? 10 : 12;
                              fontWeight = FontWeight.normal;
                            }

                            return Center(
                              child: Text(
                                lyrics[index].text.toString(),
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: fontSize,
                                  fontWeight: fontWeight,
                                  fontStyle: isPassed
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.visible,
                              ),
                            );
                          },
                        );
                      }),
                    ),
                  ),
                ),
              ),
              SizedBox(height: isMobileLandscape ? 2 : 15),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobileLandscape ? 10 : 20,
                  vertical: isMobileLandscape ? 5 : 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF181818),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 24,
                            child: DropdownButton<MixStrategy>(
                              value: mixStrategy,
                              dropdownColor: Colors.black,
                              icon: const Icon(
                                Icons.shuffle,
                                color: Color(0xFFB026FF),
                                size: 16,
                              ),
                              underline: const SizedBox(),
                              style: const TextStyle(
                                color: Color(0xFFB026FF),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: MixStrategy.sequential,
                                  child: Text("Secuencial"),
                                ),
                                DropdownMenuItem(
                                  value: MixStrategy.random,
                                  child: Text("Aleatorio"),
                                ),
                              ],
                              onChanged: (MixStrategy? val) {
                                if (val != null) {
                                  playerNotifier.setMixStrategy(val);
                                }
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_fill,
                              color: const Color(0xFF39FF14),
                              size: 45,
                            ),
                            onPressed: () => playerNotifier.togglePlayPause(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Consumer(
                        builder: (context, ref, _) {
                          final position = ref.watch(
                            playerProvider.select((s) => s.position),
                          );
                          final duration = ref.watch(
                            playerProvider.select((s) => s.duration),
                          );
                          final triggerRemainingMs = ref.watch(
                            playerProvider.select((s) => s.triggerRemainingMs),
                          );
                          final customCueInMs = ref.watch(
                            playerProvider.select((s) => s.customCueInMs),
                          );
                          final customMixOutMs = ref.watch(
                            playerProvider.select((s) => s.customMixOutMs),
                          );
                          final nextTrackPath = ref.watch(
                            playerProvider.select((s) => s.nextTrackPath),
                          );

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')}",
                                    style: const TextStyle(
                                      color: Color(0xFF39FF14),
                                      fontFamily: 'Consolas',
                                      fontSize: 12,
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      IconButton(
                                        onPressed: currentTrackPath == null
                                            ? null
                                            : () => playerNotifier
                                                  .toggleAutoMixBypass(),
                                        icon: Icon(
                                          autoMixArmed
                                              ? Icons.lock_outline
                                              : Icons.lock_open,
                                          color: autoMixArmed
                                              ? const Color(0xFF00FFFF)
                                              : Colors.white24,
                                          size: 18,
                                        ),
                                        tooltip: autoMixArmed
                                            ? "AutoMix ARMADO"
                                            : "AutoMix BYPASS (Navegación Libre)",
                                        constraints: const BoxConstraints(),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                        ),
                                      ),
                                      ElevatedButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () => playerNotifier.setMixPoint(
                                                'IN',
                                              ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.white10,
                                          foregroundColor: const Color(
                                            0xFF39FF14,
                                          ),
                                          disabledForegroundColor:
                                              Colors.white24,
                                          disabledBackgroundColor:
                                              Colors.black12,
                                          minimumSize: const Size(60, 24),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                        child: const Text(
                                          "SET IN",
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 5),
                                      ElevatedButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () async {
                                                await playerNotifier
                                                    .setMixPoint('OUT');
                                                if (!ref
                                                    .read(playerProvider)
                                                    .autoMixArmed) {
                                                  playerNotifier
                                                      .toggleAutoMixBypass();
                                                }
                                              },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.white10,
                                          foregroundColor: const Color(
                                            0xFFFF007F,
                                          ),
                                          disabledForegroundColor:
                                              Colors.white24,
                                          disabledBackgroundColor:
                                              Colors.black12,
                                          minimumSize: const Size(60, 24),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                        child: const Text(
                                          "SET OUT",
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        onPressed:
                                            (currentTrackPath == null ||
                                                autoMixArmed)
                                            ? null
                                            : () => playerNotifier
                                                  .clearMixPoints(),
                                        icon: Icon(
                                          Icons.delete_sweep,
                                          color: autoMixArmed
                                              ? Colors.white12
                                              : Colors.white54,
                                          size: 18,
                                        ),
                                        tooltip:
                                            "Borrar Cues (Restaurar NLP del Sistema)",
                                        constraints: const BoxConstraints(),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    "-${(duration - position).inMinutes}:${((duration - position).inSeconds % 60).toString().padLeft(2, '0')}",
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontFamily: 'Consolas',
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) {
                                      if (duration.inMilliseconds == 0) return;
                                      final double percent =
                                          (details.localPosition.dx /
                                                  constraints.maxWidth)
                                              .clamp(0.0, 1.0);
                                      final targetMs =
                                          (percent * duration.inMilliseconds)
                                              .toInt();
                                      playerNotifier.seek(
                                        Duration(milliseconds: targetMs),
                                      );
                                    },
                                    onHorizontalDragUpdate: (details) {
                                      if (duration.inMilliseconds == 0) return;
                                      final double percent =
                                          (details.localPosition.dx /
                                                  constraints.maxWidth)
                                              .clamp(0.0, 1.0);
                                      final targetMs =
                                          (percent * duration.inMilliseconds)
                                              .toInt();
                                      playerNotifier.seek(
                                        Duration(milliseconds: targetMs),
                                      );
                                    },
                                    child: CustomPaint(
                                      size: Size(constraints.maxWidth, 24),
                                      painter: SemanticDeckPainter(
                                        positionMs: position.inMilliseconds,
                                        durationMs: duration.inMilliseconds,
                                        triggerRemainingMs: triggerRemainingMs,
                                        lyrics: lyrics,
                                        nextTrackName: nextTrackPath
                                            ?.replaceAll('\\', '/')
                                            .split('/')
                                            .last,
                                        customCueInMs: customCueInMs,
                                        customMixOutMs: customMixOutMs,
                                        autoMixArmed: autoMixArmed,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 2),
                              SizedBox(
                                height: 12,
                                child: SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 5,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 10,
                                    ),
                                    activeTrackColor: Colors.white54,
                                    inactiveTrackColor: Colors.white10,
                                    thumbColor: Colors.white,
                                  ),
                                  child: Slider(
                                    value: duration.inMilliseconds > 0
                                        ? position.inMilliseconds
                                              .toDouble()
                                              .clamp(
                                                0.0,
                                                duration.inMilliseconds
                                                    .toDouble(),
                                              )
                                        : 0.0,
                                    min: 0.0,
                                    max: duration.inMilliseconds > 0
                                        ? duration.inMilliseconds.toDouble()
                                        : 1.0,
                                    onChanged: (val) {
                                      if (duration.inMilliseconds > 0) {
                                        playerNotifier.seek(
                                          Duration(milliseconds: val.toInt()),
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 20),
                    SizedBox(
                      width: 70,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            isRecording ? "REC" : "MASTER",
                            style: TextStyle(
                              color: isRecording
                                  ? Colors.redAccent
                                  : Colors.white38,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 5),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              isRecording
                                  ? Icons.stop_circle
                                  : Icons.fiber_manual_record,
                              color: isRecording
                                  ? Colors.redAccent
                                  : Colors.white54,
                              size: 40,
                            ),
                            onPressed: () => ref
                                .read(wasapiRecordProvider.notifier)
                                .toggleRecording(context),
                          ),
                        ],
                      ),
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

class LyricsSyncPanel extends ConsumerStatefulWidget {
  final String title;
  final bool hasLyrics;
  final Widget lyricsWidget;
  final Widget noLyricsWidget;
  final VoidCallback onSync;
  final VoidCallback onSyncMed; // 🛠️ Inyección de la nueva rutina

  const LyricsSyncPanel({
    super.key,
    required this.title,
    required this.hasLyrics,
    required this.lyricsWidget,
    required this.noLyricsWidget,
    required this.onSync,
    required this.onSyncMed,
  });

  @override
  ConsumerState<LyricsSyncPanel> createState() => _LyricsSyncPanelState();
}

class _LyricsSyncPanelState extends ConsumerState<LyricsSyncPanel> {
  bool isArmed = false;

  void _openFixLyricsModal() {
    final playerState = ref.read(playerProvider);
    if (playerState.currentTrackPath == null) return;

    final initialQuery = playerState.currentTrackPath!
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '');

    showDialog(
      context: context,
      builder: (ctx) => FixLyricsModal(
        initialQuery: initialQuery,
        audioPath: playerState.currentTrackPath!,
        localDurationMs: playerState.duration.inMilliseconds,
      ),
    );
  }

  // 🛠️ NUEVO MÓDULO: MODO TEATRO PARA LETRAS (FULLSCREEN)
  void _openFullscreenLyrics() {
    final playerState = ref.read(playerProvider);
    final lyrics = playerState.lyrics;
    final displayTitle = playerState.currentTrackPath != null
        ? playerState.currentTrackPath!.replaceAll('\\', '/').split('/').last
        : "Visor de Letras en Vivo";

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF121212),
        insetPadding: const EdgeInsets.all(15), // Ocupa casi toda la pantalla
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF39FF14), width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Container(
          width: MediaQuery.of(context).size.width,
          height: MediaQuery.of(context).size.height,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      displayTitle,
                      style: const TextStyle(
                        color: Color(0xFF39FF14),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: lyrics.isEmpty
                    ? const Center(
                        child: Text(
                          "No hay letras sincronizadas en caché.",
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : Consumer(
                        builder: (context, ref, _) {
                          final activeIdx = ref.watch(
                            playerProvider.select((s) => s.activeLyricIndex),
                          );

                          return ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            itemCount: lyrics.length,
                            itemBuilder: (context, index) {
                              final isCurrent = index == activeIdx;
                              final isPassed = index < activeIdx;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                ),
                                child: Text(
                                  lyrics[index].text,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? const Color(0xFF39FF14)
                                        : (isPassed
                                              ? Colors.white38
                                              : Colors.white),
                                    fontSize: isCurrent ? 24 : 16,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontStyle: isPassed
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendCurrentTrackToLab(
    String trackPath,
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (trackPath.isEmpty) return;

    final file = File(trackPath);
    if (!file.existsSync()) return;

    final playerState = ref.read(playerProvider);
    final playerNotifier = ref.read(playerProvider.notifier);
    final automixNotifier = ref.read(automixProvider.notifier);

    int nextIndex = playerState.currentIndex + 1;
    bool hasNext = nextIndex < playerState.playlist.length;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            playerState.isPlaying
                ? "🧪 Iniciando Hot-Swap. Aislando en Laboratorio al terminar crossfade..."
                : "🧪 Desenganchando pista y aislando en Laboratorio...",
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          backgroundColor: Colors.orangeAccent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    if (playerState.isPlaying) {
      if (hasNext) {
        playerNotifier.forceTransition(nextIndex);
      } else {
        await playerNotifier.stopAndRelease();
      }
    } else {
      await playerNotifier.stopAndRelease();
    }

    String baseMusicPath = Platform.isWindows
        ? '${Platform.environment['USERPROFILE'] ?? 'C:'}\\Music'
        : '${Platform.environment['HOME'] ?? '/storage/emulated/0'}/Music';

    final labDir = Directory(
      '$baseMusicPath${Platform.pathSeparator}DjStudio_LAB',
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

    final fileName = file.uri.pathSegments.last;
    final newPath = '${labDir.path}${Platform.pathSeparator}$fileName';

    bool moved = false;
    int attempts = 0;

    while (!moved && attempts < 20) {
      try {
        file.renameSync(newPath);
        moved = true;
      } catch (e) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }
    }

    if (!moved) {
      debugPrint("🔴 VETO TÉCNICO: libmpv no liberó el handle.");
      return;
    }

    try {
      registry[fileName] = trackPath;
      final lrcFile = File(
        trackPath.replaceAll(
          RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
          '.lrc',
        ),
      );
      if (lrcFile.existsSync()) {
        lrcFile.renameSync(
          '${labDir.path}${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
        );
      }
      registryFile.writeAsStringSync(jsonEncode(registry));

      automixNotifier.removeTrack(trackPath);

      if (!playerState.isPlaying && hasNext) {
        final newPlaylist = List<String>.from(playerState.playlist)
          ..remove(trackPath);
        int loadIndex = playerState.currentIndex;
        if (loadIndex >= newPlaylist.length) loadIndex = 0;

        if (newPlaylist.isNotEmpty) {
          await playerNotifier.loadContextAndPlay(newPlaylist, loadIndex);
          await playerNotifier.pause();
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ I/O Liberado: Pista extraída al Laboratorio."),
            backgroundColor: Color(0xFF39FF14),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O consolidando el Laboratorio: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobileLandscape = MediaQuery.of(context).size.height < 500;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobileLandscape ? 1 : 8,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: isMobileLandscape ? 12 : 14,
                  ),
                ),
                const SizedBox(width: 15),
                // 🛠️ BOTÓN DE PANTALLA COMPLETA INYECTADO AQUÍ
                IconButton(
                  icon: Icon(
                    Icons.fullscreen,
                    color: Colors.white,
                    size: isMobileLandscape ? 16 : 18,
                  ),
                  onPressed: _openFullscreenLyrics,
                  tooltip: "Modo Teatro (Letras en Pantalla Completa)",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 10),
                IconButton(
                  icon: Icon(
                    Icons.manage_search,
                    color: const Color(0xFF00FFFF),
                    size: isMobileLandscape ? 16 : 18,
                  ),
                  onPressed: _openFixLyricsModal,
                  tooltip: "Buscar Letra (Web)",
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 10),
                Consumer(
                  builder: (context, ref, child) {
                    final currentPath = ref.watch(
                      playerProvider.select((p) => p.currentTrackPath),
                    );
                    return IconButton(
                      icon: Icon(
                        Icons.science,
                        color: Colors.orangeAccent,
                        size: isMobileLandscape ? 16 : 18,
                      ),
                      onPressed: currentPath == null
                          ? null
                          : () => _sendCurrentTrackToLab(
                              currentPath,
                              context,
                              ref,
                            ),
                      tooltip: "Mover Pista al Laboratorio (LAB)",
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    );
                  },
                ),
                if (widget.hasLyrics) ...[
                  const SizedBox(width: 15),
                  Text(
                    "Sync I/O",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: isMobileLandscape ? 10 : 11,
                    ),
                  ),
                  Theme(
                    data: ThemeData(unselectedWidgetColor: Colors.white38),
                    child: Checkbox(
                      value: isArmed,
                      activeColor: const Color(0xFFFF007F),
                      visualDensity: VisualDensity.compact,
                      onChanged: (val) =>
                          setState(() => isArmed = val ?? false),
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: isArmed ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.vertical_align_top,
                            size: isMobileLandscape ? 16 : 18,
                          ),
                          color: const Color(0xFFFF007F),
                          tooltip: "Sync GLOBAL (Mueve toda la letra)",
                          onPressed: isArmed
                              ? () {
                                  widget.onSync();
                                  setState(() => isArmed = false);
                                }
                              : null,
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.adjust,
                            size: isMobileLandscape ? 16 : 18,
                          ),
                          color: const Color(0xFF00FFFF),
                          tooltip:
                              "Sync 2 MED (Mueve la letra desde este punto)",
                          onPressed: isArmed
                              ? () {
                                  widget.onSyncMed();
                                  setState(() => isArmed = false);
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(isMobileLandscape ? 2.0 : 10.0),
            child: !widget.hasLyrics
                ? widget.noLyricsWidget
                : widget.lyricsWidget,
          ),
        ),
      ],
    );
  }
}

class SemanticDeckPainter extends CustomPainter {
  final int positionMs;
  final int durationMs;
  final int triggerRemainingMs;
  final List<dynamic> lyrics;
  final String? nextTrackName;
  final int customCueInMs;
  final int customMixOutMs;
  final bool autoMixArmed;

  SemanticDeckPainter({
    required this.positionMs,
    required this.durationMs,
    required this.triggerRemainingMs,
    required this.lyrics,
    this.nextTrackName,
    required this.customCueInMs,
    required this.customMixOutMs,
    required this.autoMixArmed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (durationMs == 0) return;

    final double ratio = (positionMs / durationMs).clamp(0.0, 1.0);
    final double progressX = ratio * size.width;
    final double triggerX =
        size.width -
        ((triggerRemainingMs / durationMs) * size.width).clamp(0.0, size.width);

    final Rect deckA = Rect.fromLTWH(0, 0, size.width, 10);
    canvas.drawRect(deckA, Paint()..color = const Color(0xFF222222));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, progressX, 10),
      Paint()..color = const Color(0xFF39FF14).withValues(alpha: 0.5),
    );

    final Paint vocalPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8);
    for (var lyric in lyrics) {
      final double lX =
          ((lyric.timestamp.inMilliseconds / durationMs).clamp(0.0, 1.0)) *
          size.width;
      canvas.drawRect(Rect.fromLTWH(lX, 1, 2, 8), vocalPaint);
    }

    // 🛠️ FIX ARCH: Truncamiento visual de Crossfade por falsos positivos de VBR
    double visualMixWidth = size.width - triggerX;
    if (customMixOutMs > 0) {
      visualMixWidth =
          (8000 / durationMs) *
          size.width; // Límite estricto de UI: 8 segundos de crossfade max.
      if (triggerX + visualMixWidth > size.width) {
        visualMixWidth = size.width - triggerX;
      }
    }

    if (autoMixArmed) {
      canvas.drawRect(
        Rect.fromLTWH(triggerX, 0, visualMixWidth, 10),
        Paint()..color = const Color(0xFFFF007F).withValues(alpha: 0.4),
      );
    }

    if (customCueInMs > 0) {
      final double inX =
          ((customCueInMs / durationMs).clamp(0.0, 1.0)) * size.width;

      canvas.drawRect(
        Rect.fromLTWH(0, 0, inX, 10),
        Paint()..color = const Color(0xFFFF007F).withValues(alpha: 0.4),
      );

      canvas.drawLine(
        Offset(inX, 0),
        Offset(inX, 10),
        Paint()
          ..color = const Color(0xFF39FF14)
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(inX, 0),
        3,
        Paint()..color = const Color(0xFF39FF14),
      );
    }

    if (customMixOutMs > 0) {
      final double outX =
          ((customMixOutMs / durationMs).clamp(0.0, 1.0)) * size.width;
      canvas.drawLine(
        Offset(outX, 0),
        Offset(outX, 10),
        Paint()
          ..color = const Color(0xFFFF007F)
          ..strokeWidth = 2,
      );
      canvas.drawCircle(
        Offset(outX, 10),
        3,
        Paint()..color = const Color(0xFFFF007F),
      );

      // 🛠️ UI/UX: Renderizado de 'Dead Zone' (Sombreado de tiempo basura del archivo)
      double deadX = outX + visualMixWidth;
      if (deadX < size.width) {
        canvas.drawRect(
          Rect.fromLTWH(deadX, 0, size.width - deadX, 10),
          Paint()..color = Colors.black.withValues(alpha: 0.7),
        );
      }
    } else if (autoMixArmed) {
      canvas.drawLine(
        Offset(triggerX, 0),
        Offset(triggerX, 10),
        Paint()
          ..color = const Color(0xFFFF007F)
          ..strokeWidth = 2,
      );
    }

    final Rect deckB = Rect.fromLTWH(0, 18, size.width, 10);
    canvas.drawRect(deckB, Paint()..color = const Color(0xFF111111));

    if (autoMixArmed && nextTrackName != null) {
      canvas.drawRect(
        Rect.fromLTWH(triggerX, 18, visualMixWidth, 10),
        Paint()..color = const Color(0xFF00FFFF).withValues(alpha: 0.3),
      );

      // 🛠️ UI/UX: Sombreado de 'Dead Zone' en la pista entrante (Deck B)
      if (customMixOutMs > 0) {
        double deadX = triggerX + visualMixWidth;
        if (deadX < size.width) {
          canvas.drawRect(
            Rect.fromLTWH(deadX, 18, size.width - deadX, 10),
            Paint()..color = Colors.black.withValues(alpha: 0.7),
          );
        }
      }

      final textPainter = TextPainter(
        text: TextSpan(
          text: nextTrackName,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontFamily: 'Consolas',
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: size.width - 10);
      textPainter.paint(canvas, const Offset(4, 16));
    }

    canvas.drawLine(
      Offset(progressX, -5),
      Offset(progressX, 35),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant SemanticDeckPainter oldDelegate) =>
      positionMs != oldDelegate.positionMs ||
      durationMs != oldDelegate.durationMs ||
      customCueInMs != oldDelegate.customCueInMs ||
      customMixOutMs != oldDelegate.customMixOutMs ||
      autoMixArmed != oldDelegate.autoMixArmed;
}

// 🛠️ COMPONENTE: MODAL DE REPARACIÓN DE LETRAS (ALGORITMO FINGERPRINTING)
class FixLyricsModal extends ConsumerStatefulWidget {
  final String initialQuery;
  final String audioPath;
  final int localDurationMs;

  const FixLyricsModal({
    super.key,
    required this.initialQuery,
    required this.audioPath,
    required this.localDurationMs,
  });

  @override
  ConsumerState<FixLyricsModal> createState() => _FixLyricsModalState();
}

class _FixLyricsModalState extends ConsumerState<FixLyricsModal> {
  late TextEditingController _searchController;
  List<Map<String, dynamic>> _results = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.initialQuery);
    _performSearch();
  }

  Future<void> _performSearch() async {
    if (!mounted) return;
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isSearching = true;
      _results = [];
    });

    // 🛠️ RUTEO ESTRATÉGICO: Si es un link de YT, activamos el Scraper Nativo.
    if (query.startsWith('http') &&
        (query.contains('youtube.com') || query.contains('youtu.be'))) {
      await _scrapeCaptionsFromYoutube(query);
      return;
    }

    // --- Flujo Original (LRCLIB) ---
    final res = await ref.read(playerProvider.notifier).searchLyrics(query);

    res.sort((a, b) {
      final aSync = a['syncedLyrics']?.toString().isNotEmpty ?? false;
      final bSync = b['syncedLyrics']?.toString().isNotEmpty ?? false;

      if (aSync && !bSync) return -1;
      if (!aSync && bSync) return 1;

      final aDur = (a['duration'] as num?)?.toInt() ?? 0;
      final bDur = (b['duration'] as num?)?.toInt() ?? 0;
      final localSec = widget.localDurationMs ~/ 1000;

      final aDelta = (aDur - localSec).abs();
      final bDelta = (bDur - localSec).abs();

      return aDelta.compareTo(bDelta);
    });

    final Set<String> seenFingerprints = {};
    final List<Map<String, dynamic>> deduplicatedRes = [];

    for (var item in res) {
      String rawLyrics =
          item['syncedLyrics']?.toString() ??
          item['plainLyrics']?.toString() ??
          '';
      if (rawLyrics.isEmpty) {
        deduplicatedRes.add(item);
        continue;
      }

      String fingerprint = rawLyrics
          .replaceAll(RegExp(r'\[.*?\]'), '')
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
          .toLowerCase();

      if (fingerprint.length > 100) fingerprint = fingerprint.substring(0, 100);

      if (!seenFingerprints.contains(fingerprint)) {
        seenFingerprints.add(fingerprint);
        deduplicatedRes.add(item);
      }
    }

    if (mounted) {
      setState(() {
        _results = deduplicatedRes;
        _isSearching = false;
      });
    }
  }

  // 🛠️ INYECCIÓN: Scraper Directo de Closed Captions para el Laboratorio
  Future<void> _scrapeCaptionsFromYoutube(String videoUrl) async {
    final yt = YoutubeExplode();
    try {
      final videoId = VideoId(videoUrl);
      final video = await yt.videos.get(videoId);
      final manifest = await yt.videos.closedCaptions.getManifest(videoId);

      if (manifest.tracks.isEmpty) {
        throw Exception("El video no contiene subtítulos (Closed Captions).");
      }

      ClosedCaptionTrackInfo? selectedTrack;
      final langs = ['es', 'en'];

      for (var lang in langs) {
        try {
          selectedTrack = manifest.tracks.firstWhere(
            // 🛠️ FIX API v3: .language.code
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
              // 🛠️ FIX API v3: .language.code
              (t) => t.language.code.toLowerCase().contains(lang),
            );
            break;
          } catch (_) {}
        }
      }
      selectedTrack ??= manifest.tracks.first;

      final track = await yt.videos.closedCaptions.get(selectedTrack);
      final lrcBuffer = StringBuffer();

      for (var caption in track.captions) {
        // 🛠️ FIX API v3: .offset en lugar de .start
        final start = caption.offset;
        final min = start.inMinutes.toString().padLeft(2, '0');
        final sec = (start.inSeconds % 60).toString().padLeft(2, '0');
        final ms = ((start.inMilliseconds % 1000) ~/ 10).toString().padLeft(
          2,
          '0',
        );
        final text = caption.text
            .replaceAll('\n', ' ')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();

        if (text.isNotEmpty) lrcBuffer.writeln('[$min:$sec.$ms]$text');
      }

      if (lrcBuffer.isNotEmpty) {
        final syntheticResult = {
          'id': 999999,
          'trackName': video.title,
          'artistName': video.author,
          'albumName': 'YouTube CC Scraper',
          'duration': video.duration?.inSeconds ?? 0,
          'syncedLyrics': lrcBuffer.toString(),
        };

        if (mounted) {
          setState(() {
            _results = [syntheticResult];
            _isSearching = false;
          });
        }
      } else {
        throw Exception(
          "El subtítulo está vacío o en un formato irreconocible.",
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _results = [];
          _isSearching = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🔴 Fallo de Scraper: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      yt.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localSec = widget.localDurationMs ~/ 1000;
    final locMin = (localSec ~/ 60).toString().padLeft(2, '0');
    final locS = (localSec % 60).toString().padLeft(2, '0');

    return AlertDialog(
      backgroundColor: const Color(0xFF121212),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF00FFFF)),
        borderRadius: BorderRadius.circular(8),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            "Arreglar Letra (LRCLIB / YT)",
            style: TextStyle(
              color: Color(0xFF00FFFF),
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          Text(
            "Duración Local: $locMin:$locS",
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontFamily: 'Consolas',
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 500,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: "Ej: Elefante Angel o URL de YouTube",
                      hintStyle: TextStyle(color: Colors.white38),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF00FFFF)),
                      ),
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search, color: Color(0xFF00FFFF)),
                  onPressed: _performSearch,
                ),
              ],
            ),
            const SizedBox(height: 15),
            Expanded(
              child: _isSearching
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF00FFFF),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (context, index) =>
                          const Divider(color: Colors.white10, height: 1),
                      itemBuilder: (context, index) {
                        final track = _results[index];
                        final hasSynced =
                            track['syncedLyrics'] != null &&
                            track['syncedLyrics'].toString().isNotEmpty;

                        String snippet = "Sin letra disponible";
                        String rawLyrics =
                            track['syncedLyrics']?.toString() ??
                            track['plainLyrics']?.toString() ??
                            '';
                        if (rawLyrics.isNotEmpty) {
                          final lines = rawLyrics
                              .split('\n')
                              .map(
                                (l) =>
                                    l.replaceAll(RegExp(r'\[.*?\]'), '').trim(),
                              )
                              .where((l) => l.isNotEmpty)
                              .toList();
                          if (lines.length > 1) {
                            snippet = '🎵 "${lines[0]}\n    ${lines[1]}..."';
                          } else if (lines.isNotEmpty) {
                            snippet = '🎵 "${lines[0]}..."';
                          }
                        }

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
                        final durationStr = "$durMin:$durSec";
                        final isPerfectMatch =
                            (durationSec - localSec).abs() <= 3;

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          leading: Icon(
                            hasSynced ? Icons.check_circle : Icons.cancel,
                            color: hasSynced
                                ? const Color(0xFF39FF14)
                                : Colors.redAccent,
                            size: 24,
                          ),
                          title: Text(
                            "${track['artistName']} - ${track['trackName']}",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  Icon(
                                    Icons.timer,
                                    size: 12,
                                    color: isPerfectMatch
                                        ? const Color(0xFF39FF14)
                                        : Colors.white54,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    "Duración: $durationStr",
                                    style: TextStyle(
                                      color: isPerfectMatch
                                          ? const Color(0xFF39FF14)
                                          : Colors.white54,
                                      fontSize: 11,
                                      fontWeight: isPerfectMatch
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      track['albumName'] ?? 'Álbum Desconocido',
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 11,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                snippet,
                                style: const TextStyle(
                                  color: Color(0xFF00FFFF),
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                          trailing: ElevatedButton(
                            onPressed: hasSynced
                                ? () async {
                                    await ref
                                        .read(playerProvider.notifier)
                                        .applyManualLyrics(
                                          widget.audioPath,
                                          track['syncedLyrics'],
                                        );
                                    if (mounted) Navigator.pop(context);
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white10,
                              foregroundColor: const Color(0xFF00FFFF),
                              disabledForegroundColor: Colors.white24,
                              disabledBackgroundColor: Colors.transparent,
                            ),
                            child: const Text(
                              "APLICAR",
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            "Cancelar",
            style: TextStyle(color: Colors.white54),
          ),
        ),
      ],
    );
  }
}
