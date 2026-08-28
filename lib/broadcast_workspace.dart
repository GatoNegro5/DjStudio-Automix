import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/broadcast_provider.dart';
import 'providers/directory_provider.dart';
import 'playerDj.dart'; // Para reutilizar WasapiRecordNotifier

class BroadcastWorkspace extends ConsumerWidget {
  const BroadcastWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 800;

    final leftPanel = Container(
      color: const Color(0xFF0A0A0A),
      width: isMobile ? 200 : 250,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.black,
            child: Row(
              children: [
                const Icon(Icons.folder, color: Color(0xFF00FFFF), size: 18),
                const SizedBox(width: 10),
                const Text(
                  "Archivos Locales",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.drive_folder_upload,
                    color: Colors.white54,
                    size: 18,
                  ),
                  onPadding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () =>
                      ref.read(directoryProvider.notifier).loadDirectory(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Consumer(
              builder: (context, ref, _) {
                final dirState = ref.watch(directoryProvider);
                if (dirState.files.isEmpty) {
                  return const Center(
                    child: Text(
                      "Carpeta Vacía",
                      style: TextStyle(color: Colors.white24),
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: dirState.files.length,
                  itemBuilder: (context, index) {
                    final file = dirState.files[index];
                    final fileName = file.uri.pathSegments.last;
                    return ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -4),
                      leading: const Icon(
                        Icons.music_note,
                        color: Colors.white24,
                        size: 16,
                      ),
                      title: Text(
                        fileName,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.add_circle,
                          color: Color(0xFF00FFFF),
                          size: 18,
                        ),
                        onPressed: () =>
                            ref.read(broadcastProvider.notifier).addTrack(file),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.black,
            child: ElevatedButton.icon(
              onPressed: () {
                final files = ref.read(directoryProvider).files;
                ref.read(broadcastProvider.notifier).addAllTracks(files);
              },
              icon: const Icon(Icons.playlist_add, size: 16),
              label: const Text("Añadir Toda la Carpeta"),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 36),
                backgroundColor: const Color(0xFF181818),
                foregroundColor: const Color(0xFF00FFFF),
                side: const BorderSide(color: Color(0xFF00FFFF)),
              ),
            ),
          ),
        ],
      ),
    );

    final rightPanel = Expanded(
      child: Column(
        children: [
          // CABECERA (TRANSPORTE Y GRABACIÓN)
          Container(
            padding: const EdgeInsets.all(15),
            color: const Color(0xFF141414),
            child: Row(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    final state = ref.watch(broadcastProvider);
                    return IconButton(
                      icon: Icon(
                        state.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: const Color(0xFF39FF14),
                        size: 45,
                      ),
                      onPressed: () => ref
                          .read(broadcastProvider.notifier)
                          .togglePlayPause(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    );
                  },
                ),
                const SizedBox(width: 15),
                Consumer(
                  builder: (context, ref, _) {
                    final state = ref.watch(broadcastProvider);
                    return IconButton(
                      icon: const Icon(
                        Icons.skip_next,
                        color: Colors.white70,
                        size: 30,
                      ),
                      onPressed: state.queue.isEmpty
                          ? null
                          : () => ref
                                .read(broadcastProvider.notifier)
                                .forceNext(),
                    );
                  },
                ),
                const Spacer(),
                Consumer(
                  builder: (context, ref, _) {
                    final isRecording = ref.watch(wasapiRecordProvider);
                    return ElevatedButton.icon(
                      icon: Icon(
                        isRecording ? Icons.stop : Icons.fiber_manual_record,
                        size: 18,
                      ),
                      label: Text(
                        isRecording ? "DETENER GRABACIÓN" : "GRABAR MASTER",
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isRecording
                            ? Colors.redAccent
                            : const Color(0xFF1A1A1A),
                        foregroundColor: isRecording
                            ? Colors.white
                            : Colors.redAccent,
                        side: BorderSide(
                          color: Colors.redAccent.withValues(alpha: 0.5),
                        ),
                      ),
                      onPressed: () => ref
                          .read(wasapiRecordProvider.notifier)
                          .toggleRecording(context),
                    );
                  },
                ),
              ],
            ),
          ),

          // BARRA DE ESTADO Y FX
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            color: Colors.black,
            child: Row(
              children: [
                const Icon(Icons.tune, color: Color(0xFFFF007F), size: 18),
                const SizedBox(width: 10),
                const Text(
                  "Pro-FX Activos:",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final activeStyles = ref.watch(
                        broadcastProvider.select((s) => s.activeMixStyles),
                      );
                      return Wrap(
                        spacing: 10,
                        children: BroadcastMixStyle.values.map((style) {
                          final isActive = activeStyles.contains(style);
                          String label = "";
                          switch (style) {
                            case BroadcastMixStyle.smooth:
                              label = "Smooth Fade";
                              break;
                            case BroadcastMixStyle.vinylBrake:
                              label = "Vinyl Brake";
                              break;
                            case BroadcastMixStyle.echoOut:
                              label = "Echo Out";
                              break;
                            case BroadcastMixStyle.slamCut:
                              label = "Slam Cut";
                              break;
                          }
                          return FilterChip(
                            label: Text(
                              label,
                              style: TextStyle(
                                fontSize: 10,
                                color: isActive ? Colors.black : Colors.white70,
                              ),
                            ),
                            selected: isActive,
                            selectedColor: const Color(0xFFFF007F),
                            backgroundColor: const Color(0xFF1A1A1A),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            onSelected: (_) => ref
                                .read(broadcastProvider.notifier)
                                .toggleMixStyle(style),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ),
                Consumer(
                  builder: (context, ref, _) {
                    final strat = ref.watch(
                      broadcastProvider.select((s) => s.mixStrategy),
                    );
                    return DropdownButton<BroadcastMixStrategy>(
                      value: strat,
                      dropdownColor: Colors.black,
                      underline: const SizedBox(),
                      style: const TextStyle(
                        color: Color(0xFF39FF14),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: BroadcastMixStrategy.sequential,
                          child: Text("Secuencial"),
                        ),
                        DropdownMenuItem(
                          value: BroadcastMixStrategy.random,
                          child: Text("Aleatorio"),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null)
                          ref
                              .read(broadcastProvider.notifier)
                              .setMixStrategy(val);
                      },
                    );
                  },
                ),
              ],
            ),
          ),

          // COLA DE REPRODUCCIÓN (PLAYLIST)
          Expanded(
            child: Consumer(
              builder: (context, ref, _) {
                final state = ref.watch(broadcastProvider);
                if (state.queue.isEmpty) {
                  return const Center(
                    child: Text(
                      "La cola está vacía. Añade pistas desde el explorador.",
                      style: TextStyle(color: Colors.white24),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: state.queue.length,
                  itemBuilder: (context, index) {
                    final file = state.queue[index];
                    final isPlayingThis = index == state.currentIndex;
                    final fileName = file.uri.pathSegments.last;

                    return Container(
                      decoration: BoxDecoration(
                        color: isPlayingThis
                            ? const Color(0xFF1F000F)
                            : Colors.transparent,
                        border: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: isPlayingThis
                            ? const Icon(
                                Icons.volume_up,
                                color: Color(0xFFFF007F),
                              )
                            : Text(
                                "${index + 1}",
                                style: const TextStyle(
                                  color: Colors.white24,
                                  fontSize: 12,
                                ),
                              ),
                        title: Text(
                          fileName,
                          style: TextStyle(
                            color: isPlayingThis
                                ? const Color(0xFFFF007F)
                                : Colors.white70,
                            fontWeight: isPlayingThis
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 13,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isPlayingThis)
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.redAccent,
                                  size: 16,
                                ),
                                onPressed: () => ref
                                    .read(broadcastProvider.notifier)
                                    .removeTrack(file.path),
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          if (!isPlayingThis)
                            ref
                                .read(broadcastProvider.notifier)
                                .loadAndPlay(index);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // SLIDER Y ESTADO DE TRACK ACTUAL
          Container(
            padding: const EdgeInsets.all(15),
            color: const Color(0xFF181818),
            child: Consumer(
              builder: (context, ref, _) {
                final state = ref.watch(broadcastProvider);
                final pos = state.position;
                final dur = state.duration;
                final currentName =
                    state.currentIndex >= 0 &&
                        state.currentIndex < state.queue.length
                    ? state.queue[state.currentIndex].uri.pathSegments.last
                    : "Esperando...";

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      currentName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          "${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                          style: const TextStyle(
                            color: Color(0xFF39FF14),
                            fontFamily: 'Consolas',
                            fontSize: 12,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              activeTrackColor: const Color(0xFFFF007F),
                              inactiveTrackColor: Colors.white10,
                              thumbColor: const Color(0xFFFF007F),
                            ),
                            child: Slider(
                              value: dur.inMilliseconds > 0
                                  ? pos.inMilliseconds.toDouble().clamp(
                                      0.0,
                                      dur.inMilliseconds.toDouble(),
                                    )
                                  : 0.0,
                              min: 0.0,
                              max: dur.inMilliseconds > 0
                                  ? dur.inMilliseconds.toDouble()
                                  : 1.0,
                              onChanged: (val) {
                                if (dur.inMilliseconds > 0)
                                  ref
                                      .read(broadcastProvider.notifier)
                                      .seek(
                                        Duration(milliseconds: val.toInt()),
                                      );
                              },
                            ),
                          ),
                        ),
                        Text(
                          "-${(dur - pos).inMinutes}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontFamily: 'Consolas',
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Row(
        children: [
          leftPanel,
          const VerticalDivider(width: 1, color: Colors.white10),
          rightPanel,
        ],
      ),
    );
  }
}
