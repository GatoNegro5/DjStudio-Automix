import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/directory_provider.dart';
import '../../providers/automix_provider.dart';
import '../../providers/pipeline_provider.dart';
import '../../providers/dsp_provider.dart';
import '../../providers/theme_provider.dart';

// =====================================================================
// ROUTE 0: UNIFIED DJ WORKSPACE (IDE 3-PANEL REKORDBOX STYLE)
// =====================================================================
class AutomixWorkspace extends ConsumerStatefulWidget {
  const AutomixWorkspace({super.key});

  @override
  ConsumerState<AutomixWorkspace> createState() => _AutomixWorkspaceState();
}

class _AutomixWorkspaceState extends ConsumerState<AutomixWorkspace> {
  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(automixProvider.select((p) => p.isPlaying), (
      previous,
      isPlaying,
    ) {
      if (isPlaying) {
        ref.read(hardwareGovernorProvider.notifier).lockForLivePerformance();
        debugPrint(
          "🔒 [MUTEX] Live DJ Activo: Procesador bloqueado para rendimiento en vivo.",
        );
      } else {
        ref.read(hardwareGovernorProvider.notifier).releaseLock();
        debugPrint(
          "🔓 [MUTEX] Live DJ en Pausa: Liberando núcleos para el Auto-Master.",
        );
      }
    });

    final size = MediaQuery.of(context).size;
    final isDesktop = size.width > 800;
    final isMobileLandscape = size.height < 500;

    final Widget desktopBottomPanels = Row(
      children: [
        Material(
          color: DjStudioTheme.bgPanel,
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

    return SafeArea(
      child: Column(
        children: [
          const Expanded(flex: 65, child: MixerPanel()),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            flex: 35,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(width: 800, child: desktopBottomPanels),
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
        key: Key('${dir.path}_$isExpanded'),
        initiallyExpanded: isExpanded,
        onExpansionChanged: (expanded) {
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
    final expandedPaths = ref.watch(
      directoryProvider.select((s) => s.expandedPaths),
    );
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    return Column(
      children: [
        Container(
          padding: EdgeInsets.all(isMobile ? 6.0 : 12.0),
          decoration: const BoxDecoration(
            color: DjStudioTheme.bgPanel,
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
                  itemBuilder: (context, index) =>
                      _buildFolderNode(_subDirs[index], 0, expandedPaths),
                ),
        ),
      ],
    );
  }
}

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
          color: DjStudioTheme.bgPanel,
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
                            .read(automixQueueProvider.notifier)
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
                  minimumSize: Size(0, isMobile ? 24 : 30),
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
                                    .read(automixQueueProvider.notifier)
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
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      return home != null ? '$home/Music/DjPlaylists' : '/tmp/DjPlaylists';
    } else {
      return '/storage/emulated/0/Music/DjPlaylists';
    }
  }

  Future<void> _playLocalTrack(
    WidgetRef ref,
    List<String> playlist,
    int index,
  ) async {
    try {
      await ref
          .read(automixProvider.notifier)
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
                                .read(automixQueueProvider.notifier)
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
      automixProvider.select((p) => p.currentTrackPath),
    );
    final isPlaying = ref.watch(automixProvider.select((p) => p.isPlaying));
    final automixNotifier = ref.read(automixProvider.notifier);

    final automixQueue = ref.watch(automixQueueProvider);
    final sortMode = ref.watch(trackSortProvider);
    final playedTracks = ref.watch(playedTracksProvider);
    final bpmCache = ref.watch(bpmCacheProvider);
    final isBusy = ref.watch(pipelineProvider.select((p) => !p.isIdle));
    final bool isMobile = MediaQuery.of(context).size.width < 800;

    ref.listen<String?>(automixProvider.select((p) => p.currentTrackPath), (
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
        automixNotifier.syncDynamicPlaylist(currentOrderedPaths);
      }
    });

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: isMobile ? 4 : 8,
          ),
          color: DjStudioTheme.bgPanel,
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
                          ref.read(automixQueueProvider.notifier).clearQueue(),
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
                    color: DjStudioTheme.bgDark,
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
                          ? DjStudioTheme.deckA.withValues(alpha: 0.15)
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
                                    .read(automixQueueProvider.notifier)
                                    .removeTrack(file.path),
                                tooltip: "Quitar",
                              ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (isPlayingThisTrack) {
                                  automixNotifier.togglePlayPause();
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
      automixProvider.select((s) => s.currentTrackPath),
    );
    final isPlaying = ref.watch(automixProvider.select((s) => s.isPlaying));
    final lyrics = ref.watch(automixProvider.select((s) => s.lyrics));
    final mixStrategy = ref.watch(automixProvider.select((s) => s.mixStrategy));
    final autoMixArmed = ref.watch(
      automixProvider.select((s) => s.autoMixArmed),
    );
    final isRecording = ref.watch(wasapiRecordProvider);
    final automixNotifier = ref.read(automixProvider.notifier);

    final bool canRecord = Platform.isWindows || Platform.isLinux;

    ref.listen<int>(automixProvider.select((state) => state.activeLyricIndex), (
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
                    color: DjStudioTheme.bgPanel,
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
                    onSync: () => automixNotifier.autoSyncFirstLyric(),
                    onSyncMed: () => automixNotifier.autoSyncFromCurrentLyric(),
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
                              automixProvider.select((s) => s.activeLyricIndex),
                            );
                            final isCurrent = index == activeIdx;
                            final isNext = index == activeIdx + 1;
                            final isPassed = index < activeIdx;

                            Color textColor;
                            double fontSize;
                            FontWeight fontWeight;

                            if (isCurrent) {
                              textColor = const Color(0xFF39FF14);
                              fontSize = isMobileLandscape ? 15 : 24;
                              fontWeight =
                                  FontWeight.bold; // 🛡️ FIX: Era '=' no ':'
                            } else if (isNext) {
                              textColor = Colors.white.withValues(alpha: 0.95);
                              fontSize = isMobileLandscape ? 11 : 14;
                              fontWeight = FontWeight.w600;
                            } else {
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
                  color: DjStudioTheme.bgPanel,
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
                          IconButton(
                            iconSize: 28,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              mixStrategy == MixStrategy.random
                                  ? Icons.shuffle
                                  : Icons.format_list_numbered,
                            ),
                            color: mixStrategy == MixStrategy.random
                                ? const Color(0xFF39FF14)
                                : Colors.white54,
                            tooltip: mixStrategy == MixStrategy.random
                                ? 'Modo: Aleatorio (Shuffle)'
                                : 'Modo: Secuencial',
                            onPressed: () {
                              automixNotifier.toggleMixStrategy();
                            },
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
                            onPressed: () => automixNotifier.togglePlayPause(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Consumer(
                        builder: (context, ref, _) {
                          final position = ref.watch(
                            automixProvider.select((s) => s.position),
                          );
                          final duration = ref.watch(
                            automixProvider.select((s) => s.duration),
                          );
                          final triggerRemainingMs = ref.watch(
                            automixProvider.select((s) => s.triggerRemainingMs),
                          );
                          final customCueInMs = ref.watch(
                            automixProvider.select((s) => s.customCueInMs),
                          );
                          final customMixOutMs = ref.watch(
                            automixProvider.select((s) => s.customMixOutMs),
                          );
                          final nextTrackPath = ref.watch(
                            automixProvider.select((s) => s.nextTrackPath),
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
                                            : () => automixNotifier
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
                                            : () => automixNotifier.setMixPoint(
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
                                                await automixNotifier
                                                    .setMixPoint('OUT');
                                                if (!ref
                                                    .read(automixProvider)
                                                    .autoMixArmed) {
                                                  automixNotifier
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
                                            : () => automixNotifier
                                                  .clearMixPoints(),
                                        icon: Icon(
                                          Icons.delete_sweep,
                                          color: autoMixArmed
                                              ? Colors.white12
                                              : Colors.white54,
                                          size: 18,
                                        ),
                                        tooltip:
                                            "Borrar Cues (Restaurar Letra de Internet)",
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
                                      automixNotifier.seek(
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
                                      automixNotifier.seek(
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
                                        automixNotifier.seek(
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
                    if (canRecord) ...[
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
  final VoidCallback onSyncMed;

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

  Future<void> _sendCurrentTrackToLab(
    String trackPath,
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (trackPath.isEmpty) return;

    final file = File(trackPath);
    if (!file.existsSync()) return;

    final automixState = ref.read(automixProvider);
    final automixNotifier = ref.read(automixProvider.notifier);

    int nextIndex = automixState.currentIndex + 1;
    bool hasNext = nextIndex < automixState.playlist.length;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            automixState.isPlaying && hasNext
                ? "🧪 Mezclando pista entrante... Se aislará al terminar."
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

    if (automixState.isPlaying) {
      if (hasNext) {
        await automixNotifier.forceTransition(nextIndex);
      } else {
        await automixNotifier.stopAndRelease();
      }
    } else {
      await automixNotifier.stopAndRelease();
    }

    String baseMusicPath;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseMusicPath = userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    } else if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'];
      baseMusicPath = home != null ? '$home/Music' : '/tmp';
    } else {
      baseMusicPath = '/storage/emulated/0/Music';
    }

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

    await Future.delayed(const Duration(milliseconds: 500));

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

      // 🛡️ FIX: Se remueve de ambos Providers sincronizadamente
      ref.read(automixQueueProvider.notifier).removeTrack(trackPath);
      automixNotifier.removeTrack(trackPath);

      if (!automixState.isPlaying && hasNext) {
        final newPlaylist = List<String>.from(automixState.playlist)
          ..remove(trackPath);
        int loadIndex = automixState.currentIndex;
        if (loadIndex >= newPlaylist.length) loadIndex = 0;

        if (newPlaylist.isNotEmpty) {
          await automixNotifier.loadContextAndPlay(newPlaylist, loadIndex);
          await automixNotifier.pause();
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("✅ Pista extraída al Laboratorio exitosamente."),
            backgroundColor: Color(0xFF39FF14),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O consolidando el Laboratorio: $e");
    }
  }

  void _openFullscreenLyrics() {
    final automixState = ref.read(automixProvider);
    final lyrics = automixState.lyrics;
    final displayTitle = automixState.currentTrackPath != null
        ? automixState.currentTrackPath!.replaceAll('\\', '/').split('/').last
        : "Visor de Letras en Vivo";

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF121212),
        insetPadding: const EdgeInsets.all(15),
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
                            automixProvider.select((s) => s.activeLyricIndex),
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
                Consumer(
                  builder: (context, ref, child) {
                    final currentPath = ref.watch(
                      automixProvider.select((p) => p.currentTrackPath),
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

    double visualMixWidth = size.width - triggerX;
    if (customMixOutMs > 0) {
      visualMixWidth = (8000 / durationMs) * size.width;
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
