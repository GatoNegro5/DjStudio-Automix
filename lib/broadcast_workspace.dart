import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/broadcast_provider.dart';
import 'providers/directory_provider.dart';
import 'providers/theme_provider.dart';
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
          // 🛠️ PANEL IZQUIERDO: Explorador de Archivos
          Container(
            color: DjStudioTheme.bgPanel,
            width: isMobile ? 220 : 280,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.drive_folder_upload,
                        color: DjStudioTheme.cyanAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "Directorio Local",
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.sync,
                          color: Colors.white54,
                          size: 18,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: "Escanear Directorio",
                        onPressed: () => ref
                            .read(directoryProvider.notifier)
                            .loadDirectory(),
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
                            "Sin archivos de audio.",
                            style: TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: dirState.files.length,
                        itemBuilder: (context, index) {
                          final file = dirState.files[index];
                          final fileName = file.uri.pathSegments.last;
                          return ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -4),
                            leading: const Icon(
                              Icons.audio_file,
                              color: Colors.white24,
                              size: 16,
                            ),
                            title: Text(
                              fileName,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontFamily: 'Consolas',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.add_circle,
                                color: DjStudioTheme.cyanAccent,
                                size: 18,
                              ),
                              onPressed: () => ref
                                  .read(broadcastProvider.notifier)
                                  .addTrack(file),
                              tooltip: "Añadir al Cartridge",
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
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFF15181C),
                    border: Border(top: BorderSide(color: Colors.white10)),
                  ),
                  child: ElevatedButton.icon(
                    onPressed: () {
                      try {
                        // 🛠️ FIX ARQUITECTURA: Filtro estricto para evitar colapso de Riverpod
                        final rawFiles = ref.read(directoryProvider).files;
                        final files = rawFiles.whereType<File>().toList();
                        ref
                            .read(broadcastProvider.notifier)
                            .addAllTracks(files);
                      } catch (e) {
                        debugPrint("🔴 ERROR AL AÑADIR CARPETA: $e");
                      }
                    },
                    icon: const Icon(Icons.playlist_add_check, size: 18),
                    label: const Text(
                      "CARGAR CARPETA",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 40),
                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                      foregroundColor: DjStudioTheme.cyanAccent,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: BorderSide(
                          color: DjStudioTheme.cyanAccent.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white10),

          // 🛠️ PANEL DERECHO: Consola Broadcast Profesional
          Expanded(
            child: Column(
              children: [
                // 1. CABECERA: STATUS ON AIR Y GRABACIÓN
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 25,
                    vertical: 15,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF101215),
                    border: Border(bottom: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: DjStudioTheme.alertCritical.withValues(
                            alpha: 0.1,
                          ),
                          border: Border.all(
                            color: DjStudioTheme.alertCritical,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.sensors,
                              color: DjStudioTheme.alertCritical,
                              size: 14,
                            ),
                            SizedBox(width: 8),
                            Text(
                              "ON AIR",
                              style: TextStyle(
                                color: DjStudioTheme.alertCritical,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 15),
                      const Text(
                        "STUDIO 1 - LIVE BROADCAST",
                        style: TextStyle(
                          color: Colors.white54,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const Spacer(),
                      Consumer(
                        builder: (context, ref, _) {
                          final isRecording = ref.watch(wasapiRecordProvider);
                          return ElevatedButton.icon(
                            icon: Icon(
                              isRecording
                                  ? Icons.stop_circle
                                  : Icons.fiber_manual_record,
                              size: 16,
                            ),
                            label: Text(
                              isRecording ? "DETENER MASTER" : "GRABAR MASTER",
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isRecording
                                  ? DjStudioTheme.alertCritical
                                  : DjStudioTheme.bgPanel,
                              foregroundColor: isRecording
                                  ? Colors.white
                                  : DjStudioTheme.alertCritical,
                              side: BorderSide(
                                color: isRecording
                                    ? Colors.transparent
                                    : DjStudioTheme.alertCritical.withValues(
                                        alpha: 0.5,
                                      ),
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

                // 2. REPRODUCTOR PRINCIPAL (CARTRIDGE DECK)
                Consumer(
                  builder: (context, ref, _) {
                    final state = ref.watch(broadcastProvider);
                    final pos = state.position;
                    final dur = state.duration;
                    final currentName =
                        state.currentIndex >= 0 &&
                            state.currentIndex < state.queue.length
                        ? state.queue[state.currentIndex].uri.pathSegments.last
                        : "SISTEMA EN ESPERA - COLA VACÍA";

                    return Container(
                      margin: const EdgeInsets.all(20),
                      padding: const EdgeInsets.all(25),
                      decoration: BoxDecoration(
                        color: DjStudioTheme.bgPanel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.5),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 80,
                                height: 80,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF101215),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: DjStudioTheme.syncActive.withValues(
                                      alpha: 0.3,
                                    ),
                                  ),
                                ),
                                child: Icon(
                                  state.isPlaying
                                      ? Icons.graphic_eq
                                      : Icons.album,
                                  color: state.isPlaying
                                      ? DjStudioTheme.syncActive
                                      : Colors.white24,
                                  size: 40,
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      "NOW PLAYING",
                                      style: TextStyle(
                                        color: DjStudioTheme.syncActive,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      currentName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 22,
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
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontFamily: 'Consolas',
                                            fontSize: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 15),
                          SizedBox(
                            height: 20,
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 8,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 16,
                                ),
                                activeTrackColor: DjStudioTheme.syncActive,
                                inactiveTrackColor: Colors.white10,
                                thumbColor: Colors.white,
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
                                  if (dur.inMilliseconds > 0) {
                                    ref
                                        .read(broadcastProvider.notifier)
                                        .seek(
                                          Duration(milliseconds: val.toInt()),
                                        );
                                  }
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 15),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: Icon(
                                  state.isPlaying
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_fill,
                                  color: state.queue.isEmpty
                                      ? Colors.white24
                                      : Colors.white,
                                  size: 60,
                                ),
                                onPressed: state.queue.isEmpty
                                    ? null
                                    : () => ref
                                          .read(broadcastProvider.notifier)
                                          .togglePlayPause(),
                              ),
                              const SizedBox(width: 30),
                              IconButton(
                                icon: Icon(
                                  Icons.skip_next,
                                  color: state.queue.isEmpty
                                      ? Colors.white24
                                      : Colors.white70,
                                  size: 40,
                                ),
                                onPressed: state.queue.isEmpty
                                    ? null
                                    : () => ref
                                          .read(broadcastProvider.notifier)
                                          .forceNext(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),

                // 3. RACK DE EFECTOS Y ESTRATEGIA (HARDWARE BUTTONS)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 25,
                    vertical: 10,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFF101215),
                    border: Border.symmetric(
                      horizontal: BorderSide(color: Colors.white10),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.memory,
                        color: DjStudioTheme.masterPeak,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        "DSP FX BUS:",
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: Consumer(
                          builder: (context, ref, _) {
                            final activeStyles = ref.watch(
                              broadcastProvider.select(
                                (s) => s.activeMixStyles,
                              ),
                            );
                            return Wrap(
                              spacing: 10,
                              children: BroadcastMixStyle.values.map((style) {
                                final isActive = activeStyles.contains(style);
                                String label = "";
                                switch (style) {
                                  case BroadcastMixStyle.smooth:
                                    label = "SMOOTH";
                                    break;
                                  case BroadcastMixStyle.vinylBrake:
                                    label = "BRAKE";
                                    break;
                                  case BroadcastMixStyle.echoOut:
                                    label = "ECHO";
                                    break;
                                  case BroadcastMixStyle.slamCut:
                                    label = "SLAM";
                                    break;
                                }
                                return FilterChip(
                                  label: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? Colors.black
                                          : Colors.white54,
                                    ),
                                  ),
                                  selected: isActive,
                                  selectedColor: DjStudioTheme.masterPeak,
                                  backgroundColor: DjStudioTheme.bgDark,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                    side: BorderSide(
                                      color: isActive
                                          ? DjStudioTheme.masterPeak
                                          : Colors.white10,
                                    ),
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
                          return Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: DjStudioTheme.bgDark,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: DropdownButton<BroadcastMixStrategy>(
                              value: strat,
                              dropdownColor: DjStudioTheme.bgDark,
                              underline: const SizedBox(),
                              icon: const Icon(
                                Icons.swap_calls,
                                color: Colors.white54,
                                size: 16,
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: BroadcastMixStrategy.sequential,
                                  child: Text(" MODO: SECUENCIAL "),
                                ),
                                DropdownMenuItem(
                                  value: BroadcastMixStrategy.random,
                                  child: Text(" MODO: ALEATORIO "),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null)
                                  ref
                                      .read(broadcastProvider.notifier)
                                      .setMixStrategy(val);
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // 4. COLA DE REPRODUCCIÓN (CART SLOTS)
                Expanded(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final state = ref.watch(broadcastProvider);
                      if (state.queue.isEmpty) {
                        return const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.inbox,
                                color: Colors.white10,
                                size: 50,
                              ),
                              SizedBox(height: 10),
                              Text(
                                "EL CARTRIDGE ESTÁ VACÍO",
                                style: TextStyle(
                                  color: Colors.white24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: const EdgeInsets.all(15),
                        physics: const BouncingScrollPhysics(),
                        itemCount: state.queue.length,
                        itemBuilder: (context, index) {
                          final file = state.queue[index];
                          final isPlayingThis = index == state.currentIndex;
                          final fileName = file.uri.pathSegments.last;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isPlayingThis
                                  ? DjStudioTheme.syncActive.withValues(
                                      alpha: 0.1,
                                    )
                                  : DjStudioTheme.bgPanel,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isPlayingThis
                                    ? DjStudioTheme.syncActive.withValues(
                                        alpha: 0.5,
                                      )
                                    : Colors.white10,
                              ),
                            ),
                            child: ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 2,
                              ),
                              leading: isPlayingThis
                                  ? const Icon(
                                      Icons.graphic_eq,
                                      color: DjStudioTheme.syncActive,
                                      size: 18,
                                    )
                                  : Text(
                                      (index + 1).toString().padLeft(2, '0'),
                                      style: const TextStyle(
                                        color: Colors.white24,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                              title: Text(
                                fileName,
                                style: TextStyle(
                                  color: isPlayingThis
                                      ? Colors.white
                                      : Colors.white70,
                                  fontWeight: isPlayingThis
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  fontSize: 13,
                                ),
                              ),
                              trailing: isPlayingThis
                                  ? const Text(
                                      "ON AIR",
                                      style: TextStyle(
                                        color: DjStudioTheme.syncActive,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                        size: 18,
                                      ),
                                      onPressed: () => ref
                                          .read(broadcastProvider.notifier)
                                          .removeTrack(file.path),
                                      tooltip: "Eliminar pista",
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
