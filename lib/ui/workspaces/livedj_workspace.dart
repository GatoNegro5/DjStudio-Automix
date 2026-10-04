import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../providers/directory_provider.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import 'automix_workspace.dart';
import 'livedj_bpm_badge.dart';

class LiveDjWorkspace extends ConsumerWidget {
  const LiveDjWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      backgroundColor: DjStudioTheme.bgDark,
      body: Row(
        children: [
          // Explorador: columna izquierda a toda la altura, arranca arriba.
          Expanded(
            flex: 5,
            child: Material(
              color: DjStudioTheme.bgPanel,
              child: LibraryTreePanel(provider: liveDjDirectoryProvider),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white10),
          Expanded(
            flex: 19,
            child: Column(
              children: [
                Expanded(
                  flex: compact ? 4 : 5,
                  child: const LiveDjPlayerPanel(),
                ),
                const Divider(height: 1, color: Colors.white10),
                Expanded(
                  flex: compact ? 6 : 5,
                  child: const Row(
                    children: [
                      Expanded(flex: 4, child: LiveDjFolderPanel()),
                      VerticalDivider(width: 1, color: Colors.white10),
                      Expanded(flex: 5, child: LiveDjCartridgePanel()),
                    ],
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

class LiveDjFolderPanel extends ConsumerWidget {
  const LiveDjFolderPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(liveDjDirectoryProvider);
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
                    : () async {
                        final rawFiles = dirState.files
                            .whereType<File>()
                            .toList();
                        final notifier = ref.read(liveDjProvider.notifier);
                        notifier.addAllTracks(rawFiles);
                        if (ref.read(liveDjProvider).currentTrackPath ==
                            null) {
                          await notifier.togglePlayPause();
                        }
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
                        onTap: () async {
                          final notifier = ref.read(liveDjProvider.notifier);
                          notifier.addTrack(file);
                          if (ref.read(liveDjProvider).currentTrackPath ==
                              null) {
                            await notifier.togglePlayPause();
                          }
                        },
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: DjStudioTheme.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () =>
                              ref.read(liveDjProvider.notifier).addTrack(file),
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

class LiveDjPlayerPanel extends ConsumerStatefulWidget {
  const LiveDjPlayerPanel({super.key});

  @override
  ConsumerState<LiveDjPlayerPanel> createState() => _LiveDjPlayerPanelState();
}

class _LiveDjPlayerPanelState extends ConsumerState<LiveDjPlayerPanel> {
  double? _dragPosition;
  String? _stealthNextName;
  String? _stealthCacheKey;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveDjProvider);
    final pos = state.position;
    final dur = state.duration;
    final currentName = (state.currentTrackPath ??
            (state.queue.isNotEmpty ? state.queue.first.path : null))
        ?.replaceAll('\\', '/')
        .split('/')
        .last ??
        "SISTEMA EN ESPERA";
    final isPlayingNow = state.isPlaying;
    final canToggle =
        state.currentTrackPath != null || state.queue.isNotEmpty;

    final isMixBypass = state.currentMixMode == LiveDjMixMode.longBypass;
    final mixFormula = ref.watch(mixFormulaProvider);
    String? nextName;
    if (state.queue.isEmpty) {
      nextName = null;
      _stealthCacheKey = null;
    } else if (mixFormula == MixFormula.stealthGap &&
        state.currentTrackPath != null) {
      final String key =
          '${state.currentTrackPath}|${state.queue.map((f) => f.path).join('|')}';
      if (_stealthCacheKey != key) {
        _stealthCacheKey = key;
        final int i = pickStealthNextIndex(
          remaining: state.queue.map((f) => f.path).toList(),
          currentPath: state.currentTrackPath,
          bpmOf: (p) {
            final fileName = p.replaceAll('\\', '/').split('/').last;
            final match = RegExp(
              r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
              caseSensitive: false,
            ).firstMatch(fileName);
            return match != null ? double.parse(match.group(1)!) : 0.0;
          },
        );
        _stealthNextName =
            (i >= 0 ? state.queue[i].path : state.queue.first.path)
                .replaceAll('\\', '/')
                .split('/')
                .last;
      }
      nextName = _stealthNextName;
    } else if (state.currentTrackPath == null) {
      _stealthCacheKey = null;
      nextName = state.queue.length > 1
          ? state.queue[1].path.replaceAll('\\', '/').split('/').last
          : null;
    } else {
      _stealthCacheKey = null;
      nextName =
          state.queue.first.path.replaceAll('\\', '/').split('/').last;
    }
    final engineModeStr = isMixBypass
        ? "BYPASS (MEZCLA PROTEGIDA)"
        : (mixFormula == MixFormula.stealthGap
              ? "STEALTH 60% (SIN VOZ)"
              : (mixFormula == MixFormula.phraseGrid
                    ? "PHRASE 8 (GRID 4/4)"
                    : "ACTIVE BEATMATCHING (DNA DJ 60-80%)"));
    final engineModeColor = isMixBypass
        ? DjStudioTheme.cyanAccent
        : (mixFormula == MixFormula.stealthGap
              ? DjStudioTheme.deckB
              : (mixFormula == MixFormula.phraseGrid
                    ? DjStudioTheme.deckA
                    : DjStudioTheme.syncActive));

    final isShuffle = state.mixStrategy == LiveDjMixStrategy.random;
    final compact = Platform.isAndroid || Platform.isIOS;
    final bool menuOpen = compact ? ref.watch(mobileNavOpenProvider) : false;
    final gap = compact ? 4.0 : 10.0;
    final titleSize = compact ? 13.0 : 16.0;
    final timeSize = compact ? 14.0 : 18.0;

    final onAirBadge = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: DjStudioTheme.alertCritical.withValues(alpha: 0.1),
        border: Border.all(color: DjStudioTheme.alertCritical),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sensors, color: DjStudioTheme.alertCritical, size: 12),
          SizedBox(width: 5),
          Text(
            "ON AIR",
            style: TextStyle(
              color: DjStudioTheme.alertCritical,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );

    final studioTitle = Text(
      "STUDIO 1 - LIVEDJ ENGINE",
      style: TextStyle(
        color: Colors.white54,
        fontWeight: FontWeight.bold,
        fontSize: compact ? 10 : 12,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
    );

    final nowPlayingBody = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
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
                  SizedBox(height: compact ? 2 : 5),
                  Text(
                    currentName,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: titleSize,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (compact) ...[
              onAirBadge,
              const SizedBox(width: 8),
              Flexible(child: studioTitle),
            ],
          ],
        ),
        SizedBox(height: compact ? 4 : gap),
        if (compact)
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Text(
                  "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                  style: const TextStyle(
                    color: DjStudioTheme.cyanAccent,
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(
                      trackHeight: 3,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
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
                          ref.read(liveDjProvider.notifier).seek(
                            Duration(milliseconds: val.toInt()),
                          );
                        }
                        setState(() {
                          _dragPosition = null;
                        });
                      },
                    ),
                  ),
                ),
                Text(
                  "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                  style: const TextStyle(
                    color: Colors.white54,
                    fontFamily: 'Consolas',
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  tooltip: isShuffle
                      ? 'Modo: Aleatorio (Shuffle)'
                      : 'Modo: Secuencial',
                  onPressed: () {
                    ref.read(liveDjProvider.notifier).toggleMixStrategy();
                  },
                  icon: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (isShuffle
                              ? const Color(0xFFFF007F)
                              : const Color(0xFF00FFFF))
                          .withValues(alpha: 0.18),
                      border: Border.all(
                        color: isShuffle
                            ? const Color(0xFFFF007F)
                            : const Color(0xFF00FFFF),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      isShuffle
                          ? Icons.shuffle
                          : Icons.format_list_numbered,
                      size: 16,
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: canToggle
                      ? () =>
                          ref.read(liveDjProvider.notifier).togglePlayPause()
                      : null,
                  icon: Icon(
                    isPlayingNow
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: const Color(0xFF39FF14).withValues(
                      alpha: canToggle ? 1 : 0.28,
                    ),
                    size: 42,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: state.queue.isEmpty
                      ? null
                      : () => ref.read(liveDjProvider.notifier).forceNext(),
                  child: Icon(
                    Icons.skip_next,
                    size: 22,
                    color: state.queue.isEmpty
                        ? Colors.white24
                        : Colors.white70,
                  ),
                ),
              ],
            ),
          )
        else ...[
          Row(
            children: [
              Text(
                "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                style: TextStyle(
                  color: DjStudioTheme.cyanAccent,
                  fontFamily: 'Consolas',
                  fontSize: timeSize,
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
                    ref.read(liveDjProvider.notifier).seek(
                      Duration(milliseconds: val.toInt()),
                    );
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
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 52,
                  height: 52,
                ),
                tooltip: isShuffle
                    ? 'Modo: Aleatorio (Shuffle)'
                    : 'Modo: Secuencial',
                onPressed: () {
                  ref.read(liveDjProvider.notifier).toggleMixStrategy();
                },
                icon: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (isShuffle
                            ? const Color(0xFFFF007F)
                            : const Color(0xFF00FFFF))
                        .withValues(alpha: 0.18),
                    border: Border.all(
                      color: isShuffle
                          ? const Color(0xFFFF007F)
                          : const Color(0xFF00FFFF),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    isShuffle ? Icons.shuffle : Icons.format_list_numbered,
                    size: 26,
                    color: isShuffle
                        ? const Color(0xFFFF007F)
                        : const Color(0xFF00FFFF),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: canToggle
                    ? () =>
                        ref.read(liveDjProvider.notifier).togglePlayPause()
                    : null,
                icon: Icon(
                  isPlayingNow
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: const Color(0xFF39FF14).withValues(
                    alpha: canToggle ? 1 : 0.28,
                  ),
                  size: 45,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  Icons.skip_next,
                  color: state.queue.isEmpty ? Colors.white24 : Colors.white70,
                  size: 30,
                ),
                onPressed: state.queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).forceNext(),
              ),
            ],
          ),
        ],
        if (nextName != null) ...[
          SizedBox(height: compact ? 3 : 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            color: const Color(0xFF00FFFF).withValues(alpha: 0.14),
            child: Text(
              nextName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFF00FFFF),
                fontFamily: 'Consolas',
                fontSize: compact ? 9 : 11,
              ),
            ),
          ),
        ],
      ],
    );

    final songCard = Container(
      margin: EdgeInsets.all(compact ? 6 : 15),
      padding: EdgeInsets.all(compact ? 8 : 15),
      decoration: BoxDecoration(
        color: DjStudioTheme.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: nowPlayingBody,
    );

    final routingBar = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 15,
        vertical: compact ? 4 : 12,
      ),
      color: DjStudioTheme.bgDark,
      child: Row(
        children: [
          Icon(Icons.memory, color: engineModeColor, size: 16),
          const SizedBox(width: 8),
          const Flexible(
            child: Text(
              "TIPO DE MEZCLA:",
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: isMixBypass
                  ? null
                  : () {
                      final cur = ref.read(mixFormulaProvider);
                      ref.read(mixFormulaProvider.notifier).state =
                          cur == MixFormula.dnaEnergy
                          ? MixFormula.phraseGrid
                          : (cur == MixFormula.phraseGrid
                                ? MixFormula.stealthGap
                                : MixFormula.dnaEnergy);
                    },
              child: Tooltip(
                message:
                    '1 DNA 60-80%  ·  2 Phrase 8  ·  3 Stealth sin voz. Toca para cambiar.',
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
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        if (compact)
          ColoredBox(
            color: DjStudioTheme.bgDark,
            child: Row(
              children: [
                DjStudioMobileModeBar(
                  title: 'Live DJ',
                  accent: DjStudioTheme.syncActive,
                  open: menuOpen,
                  expand: false,
                  onTap: () => ref.read(mobileNavOpenProvider.notifier).state =
                      !menuOpen,
                ),
                Expanded(child: routingBar),
              ],
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
            decoration: const BoxDecoration(
              color: DjStudioTheme.bgDark,
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                onAirBadge,
                const SizedBox(width: 15),
                Expanded(child: studioTitle),
              ],
            ),
          ),
        Expanded(
          child: compact
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: DjStudioTheme.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                      child: LayoutBuilder(
                        builder: (context, c) {
                          return FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: c.maxWidth,
                              child: nowPlayingBody,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                )
              : SingleChildScrollView(child: songCard),
        ),
        if (!compact) routingBar,
      ],
    );
  }
}

class LiveDjCartridgePanel extends ConsumerWidget {
  const LiveDjCartridgePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(liveDjProvider.select((s) => s.queue));

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: DjStudioTheme.bgPanel,
            border: Border(
              top: BorderSide(color: Colors.white10),
              bottom: BorderSide(color: Colors.white10),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.shuffle, color: Colors.pinkAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "CARTRIDGE (${queue.length})",
                  style: const TextStyle(
                    color: Colors.pinkAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    letterSpacing: 1.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_sweep,
                  color: Colors.redAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                visualDensity: VisualDensity.compact,
                onPressed: queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).clearQueue(),
                tooltip: "Borrar Cola",
              ),
              IconButton(
                icon: const Icon(
                  Icons.save,
                  color: Colors.cyanAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                visualDensity: VisualDensity.compact,
                onPressed: queue.isEmpty
                    ? null
                    : () => ref.read(liveDjProvider.notifier).savePlaylist(),
                tooltip: "Guardar Playlist",
              ),
              IconButton(
                icon: const Icon(
                  Icons.folder_open,
                  color: Colors.greenAccent,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    ref.read(liveDjProvider.notifier).loadPlaylist(),
                tooltip: "Cargar Playlist",
              ),
            ],
          ),
        ),
        Expanded(
          child: queue.isEmpty
              ? const Center(
                  child: Text(
                    "CARTRIDGE VACÍO\nCola de emisión sin pistas.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white24, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: queue.length,
                  itemBuilder: (context, index) {
                    final file = queue[index];
                    final fileName = file.uri.pathSegments.last;

                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -4),
                        shape: const Border(
                          bottom: BorderSide(color: Colors.white10),
                        ),
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.drag_handle,
                              color: Colors.white24,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            LiveDjBpmBadge(path: file.path),
                          ],
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
                            .read(liveDjProvider.notifier)
                            .playTrackFromQueue(index),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.play_arrow,
                                color: Color(0xFF39FF14),
                                size: 18,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              tooltip: "Play",
                              onPressed: () => ref
                                  .read(liveDjProvider.notifier)
                                  .playTrackFromQueue(index),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.redAccent,
                                size: 16,
                              ),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => ref
                                  .read(liveDjProvider.notifier)
                                  .removeTrack(file.path),
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
