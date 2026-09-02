import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../providers/directory_provider.dart';
import '../../providers/broadcast_provider.dart';
import 'playerDj.dart';

class BroadcastWorkspace extends ConsumerWidget {
  const BroadcastWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 800;

    return Scaffold(
      backgroundColor: DjStudioTheme.bgDark,
      body: Row(
        children: [
          Material(
            color: DjStudioTheme.bgPanel,
            child: SizedBox(
              width: isMobile ? 150 : 220,
              child: const LibraryTreePanel(),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white10),
          const Expanded(flex: 4, child: BroadcastFolderPanel()),
          const VerticalDivider(width: 1, color: Colors.white10),
          const Expanded(flex: 5, child: BroadcastPlayerPanel()),
        ],
      ),
    );
  }
}

class BroadcastFolderPanel extends ConsumerWidget {
  const BroadcastFolderPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(directoryProvider);
    final bool isMobile = MediaQuery.of(context).size.width < 800;

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
                        final rawFiles = dirState.files
                            .whereType<File>()
                            .toList();
                        ref
                            .read(broadcastProvider.notifier)
                            .addAllTracks(rawFiles);
                      },
                icon: Icon(Icons.playlist_add_check, size: isMobile ? 14 : 16),
                label: Text(
                  "Cargar Carpeta",
                  style: TextStyle(fontSize: isMobile ? 10 : 11),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: DjStudioTheme.cyanAccent,
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
                  physics: const BouncingScrollPhysics(),
                  itemCount: dirState.files.length,
                  itemBuilder: (context, index) {
                    final file = dirState.files[index];
                    final fileName = file.uri.pathSegments.last;

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: const Icon(
                          Icons.audio_file,
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
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: DjStudioTheme.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () => ref
                              .read(broadcastProvider.notifier)
                              .addTrack(file),
                          tooltip: "Añadir a la Cola",
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

class BroadcastPlayerPanel extends ConsumerStatefulWidget {
  const BroadcastPlayerPanel({super.key});

  @override
  ConsumerState<BroadcastPlayerPanel> createState() =>
      _BroadcastPlayerPanelState();
}

class _BroadcastPlayerPanelState extends ConsumerState<BroadcastPlayerPanel> {
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(broadcastProvider);
    final pos = state.position;
    final dur = state.duration;
    final currentName = state.currentTrackPath != null
        ? state.currentTrackPath!.replaceAll('\\', '/').split('/').last
        : "SISTEMA EN ESPERA";

    final isMixBypass = state.currentMixMode == BroadcastMixMode.longBypass;
    final engineModeStr = isMixBypass
        ? "BYPASS (MEZCLA PROTEGIDA)"
        : "ACTIVE BEATMATCHING (20s OVERLAP)";
    final engineModeColor = isMixBypass
        ? DjStudioTheme.cyanAccent
        : DjStudioTheme.syncActive;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
          decoration: const BoxDecoration(
            color: Color(0xFF101215),
            border: Border(bottom: BorderSide(color: Colors.white10)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: DjStudioTheme.alertCritical.withValues(alpha: 0.1),
                  border: Border.all(color: DjStudioTheme.alertCritical),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.sensors,
                      color: DjStudioTheme.alertCritical,
                      size: 12,
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      "ON AIR",
                      style: TextStyle(
                        color: DjStudioTheme.alertCritical,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 15),
              const Text(
                "STUDIO 1 - BROADCAST ENGINE",
                style: TextStyle(
                  color: Colors.white54,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),

        Container(
          margin: const EdgeInsets.all(15),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: DjStudioTheme.bgPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "NOW PLAYING",
                style: TextStyle(
                  color: DjStudioTheme.syncActive,
                  fontWeight: FontWeight.bold,
                  fontSize: 9,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                currentName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                    style: const TextStyle(
                      color: DjStudioTheme.cyanAccent,
                      fontFamily: 'Consolas',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                    style: const TextStyle(
                      color: Colors.white54,
                      fontFamily: 'Consolas',
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 15,
                child: SliderTheme(
                  data: const SliderThemeData(
                    trackHeight: 3,
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: DjStudioTheme.syncActive,
                    inactiveTrackColor: Colors.white10,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value:
                        _dragPosition ??
                        (dur.inMilliseconds > 0
                            ? pos.inMilliseconds.toDouble().clamp(
                                0.0,
                                dur.inMilliseconds.toDouble(),
                              )
                            : 0.0),
                    min: 0.0,
                    max: dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1.0,
                    onChangeStart: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChanged: (val) {
                      setState(() {
                        _dragPosition = val;
                      });
                    },
                    onChangeEnd: (val) {
                      if (dur.inMilliseconds > 0) {
                        ref
                            .read(broadcastProvider.notifier)
                            .seek(Duration(milliseconds: val.toInt()));
                      }
                      setState(() {
                        _dragPosition = null;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: Icon(
                      state.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color:
                          state.queue.isEmpty && state.currentTrackPath == null
                          ? Colors.white24
                          : Colors.white,
                      size: 45,
                    ),
                    onPressed:
                        state.queue.isEmpty && state.currentTrackPath == null
                        ? null
                        : () => ref
                              .read(broadcastProvider.notifier)
                              .togglePlayPause(),
                  ),
                  const SizedBox(width: 20),
                  IconButton(
                    icon: Icon(
                      Icons.skip_next,
                      color: state.queue.isEmpty
                          ? Colors.white24
                          : Colors.white70,
                      size: 30,
                    ),
                    onPressed: state.queue.isEmpty
                        ? null
                        : () =>
                              ref.read(broadcastProvider.notifier).forceNext(),
                  ),
                ],
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          color: const Color(0xFF101215),
          child: Row(
            children: [
              Icon(Icons.memory, color: engineModeColor, size: 16),
              const SizedBox(width: 8),
              const Text(
                "SMART ROUTING ENGINE:",
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: DjStudioTheme.bgDark,
                    border: Border.all(
                      color: engineModeColor.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    engineModeStr,
                    style: TextStyle(
                      color: engineModeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),

        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF16181C),
            border: Border(
              top: BorderSide(color: Colors.white10),
              bottom: BorderSide(color: Colors.white10),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.shuffle, color: Colors.pinkAccent, size: 18),
              const SizedBox(width: 8),
              Text(
                "CARTRIDGE (${state.queue.length})",
                style: const TextStyle(
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(
                  Icons.delete_sweep,
                  color: Colors.redAccent,
                  size: 20,
                ),
                onPressed: state.queue.isEmpty
                    ? null
                    : () => ref.read(broadcastProvider.notifier).clearQueue(),
                tooltip: "Borrar Cola",
              ),
              IconButton(
                icon: const Icon(
                  Icons.save,
                  color: Colors.cyanAccent,
                  size: 20,
                ),
                onPressed: state.queue.isEmpty
                    ? null
                    : () => ref.read(broadcastProvider.notifier).savePlaylist(),
                tooltip: "Guardar Playlist",
              ),
              IconButton(
                icon: const Icon(
                  Icons.folder_open,
                  color: Colors.greenAccent,
                  size: 20,
                ),
                onPressed: () =>
                    ref.read(broadcastProvider.notifier).loadPlaylist(),
                tooltip: "Cargar Playlist",
              ),
            ],
          ),
        ),

        Expanded(
          child: state.queue.isEmpty
              ? const Center(
                  child: Text(
                    "CARTRIDGE VACÍO\nCola de emisión sin pistas.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: state.queue.length,
                  itemBuilder: (context, index) {
                    final file = state.queue[index];
                    final fileName = file.uri.pathSegments.last;

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: const Icon(
                          Icons.drag_handle,
                          color: Colors.white24,
                          size: 16,
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
                        onTap: () => ref
                            .read(broadcastProvider.notifier)
                            .playTrackFromQueue(index),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.redAccent,
                            size: 16,
                          ),
                          onPressed: () => ref
                              .read(broadcastProvider.notifier)
                              .removeTrack(file.path),
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
