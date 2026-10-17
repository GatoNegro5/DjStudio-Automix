import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/artist_info.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';
import 'livedj_bpm_badge.dart';

/// Pantalla grande de la canción que está sonando. No usa la carpeta
/// marcada en el Explorador: sigue `currentTrackPath`.
class LiveDjFolderPlaylist extends ConsumerStatefulWidget {
  const LiveDjFolderPlaylist({super.key});

  @override
  ConsumerState<LiveDjFolderPlaylist> createState() =>
      _LiveDjFolderPlaylistState();
}

class _LiveDjFolderPlaylistState extends ConsumerState<LiveDjFolderPlaylist> {
  String? _dir;
  List<File> _files = const [];
  double? _dragPosition;
  String? _stealthNextName;
  String? _stealthCacheKey;

  static String _norm(String p) => p.replaceAll('\\', '/').toLowerCase();

  void _syncFolder(String? track) {
    final parent = (track == null || track.isEmpty)
        ? ''
        : File(track).parent.path;
    if (parent == _dir) return;
    _dir = parent;
    if (parent.isEmpty) {
      setState(() => _files = const []);
      return;
    }
    _load(parent);
  }

  Future<void> _load(String dir) async {
    final out = <File>[];
    try {
      await for (final entity in Directory(dir).list(followLinks: false)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('.mp3') ||
            lower.endsWith('.m4a') ||
            lower.endsWith('.wav') ||
            lower.endsWith('.webm')) {
          out.add(entity);
        }
      }
    } catch (_) {}
    out.sort(
      (a, b) => a.uri.pathSegments.last.toLowerCase().compareTo(
        b.uri.pathSegments.last.toLowerCase(),
      ),
    );
    if (!mounted || _dir != dir) return;
    setState(() => _files = out);
  }

  String _songTitle(String path) {
    var name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    final artist = artistFromPath(path);
    final split = name.indexOf(' - ');
    if (artist.isNotEmpty && split > 0) {
      return name.substring(split + 3).trim();
    }
    return name;
  }

  String? _nextName(LiveDjState state, MixFormula mixFormula) {
    if (state.radioOn) {
      final rn = state.radioNextPath;
      return rn == null
          ? 'RADIO ▸ eligiendo…'
          : 'RADIO ▸ ${rn.replaceAll('\\', '/').split('/').last}';
    }
    if (state.queue.isEmpty) {
      _stealthCacheKey = null;
      return null;
    }
    if (mixFormula == MixFormula.stealthGap && state.currentTrackPath != null) {
      final key =
          '${state.currentTrackPath}|${state.queue.map((f) => f.path).join('|')}';
      if (_stealthCacheKey != key) {
        _stealthCacheKey = key;
        final i = pickStealthNextIndex(
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
        _stealthNextName = (i >= 0 ? state.queue[i].path : state.queue.first.path)
            .replaceAll('\\', '/')
            .split('/')
            .last;
      }
      return _stealthNextName;
    }
    _stealthCacheKey = null;
    if (state.currentTrackPath == null) {
      return state.queue.length > 1
          ? state.queue[1].path.replaceAll('\\', '/').split('/').last
          : null;
    }
    return state.queue.first.path.replaceAll('\\', '/').split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveDjProvider);
    final mixFormula = ref.watch(mixFormulaProvider);
    final track = state.currentTrackPath;
    final parent = (track == null || track.isEmpty)
        ? ''
        : File(track).parent.path;
    if (parent != _dir) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncFolder(track);
      });
    }
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final artist = track == null ? '' : artistFromPath(track);
    final title = track == null ? 'Nada sonando' : _songTitle(track);
    final side = wide ? 180.0 : 96.0;
    final pos = state.position;
    final dur = state.duration;
    final nextName = _nextName(state, mixFormula);
    final isShuffle = state.mixStrategy == LiveDjMixStrategy.random;
    final canToggle = track != null || state.queue.isNotEmpty;
    final canSkip = state.queue.isNotEmpty || state.radioOn;

    return ColoredBox(
      color: DjStudioTheme.bgDark,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(
              wide ? 24 : 12,
              wide ? 16 : 8,
              wide ? 72 : 64,
              wide ? 8 : 4,
            ),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B3A4B), DjStudioTheme.bgDark],
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _NowCover(artist: artist, side: side),
                SizedBox(width: wide ? 20 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: wide ? 36 : 22,
                          height: 1.05,
                        ),
                      ),
                      if (artist.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: wide ? 16 : 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          LiveDjBpmChip(path: track, fontSize: wide ? 12 : 10),
                          const SizedBox(width: 8),
                          _OnAirBadge(compact: !wide),
                        ],
                      ),
                      if (state.radioOn)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _RadioChips(compact: !wide),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 0, wide ? 24 : 12, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      "${pos.inMinutes.toString().padLeft(2, '0')}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}",
                      style: TextStyle(
                        color: DjStudioTheme.cyanAccent,
                        fontFamily: 'Consolas',
                        fontSize: wide ? 16 : 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      "-${(dur - pos).inMinutes.toString().padLeft(2, '0')}:${((dur - pos).inSeconds % 60).toString().padLeft(2, '0')}",
                      style: TextStyle(
                        color: Colors.white54,
                        fontFamily: 'Consolas',
                        fontSize: wide ? 14 : 12,
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  height: 28,
                  child: SliderTheme(
                    data: const SliderThemeData(
                      trackHeight: 3,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: DjStudioTheme.syncActive,
                      inactiveTrackColor: Colors.white10,
                      thumbColor: Colors.white,
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Slider(
                          value: _dragPosition ??
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
                          onChangeStart: (v) =>
                              setState(() => _dragPosition = v),
                          onChanged: (v) => setState(() => _dragPosition = v),
                          onChangeEnd: (v) {
                            if (dur.inMilliseconds > 0) {
                              ref.read(liveDjProvider.notifier).seek(
                                Duration(milliseconds: v.toInt()),
                              );
                            }
                            setState(() => _dragPosition = null);
                          },
                        ),
                        _mixMarker(
                          12,
                          state.customMixOutMs,
                          dur.inMilliseconds,
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: isShuffle
                          ? 'Modo: Aleatorio (Shuffle)'
                          : 'Modo: Secuencial',
                      onPressed: () => ref
                          .read(liveDjProvider.notifier)
                          .toggleMixStrategy(),
                      icon: Icon(
                        isShuffle ? Icons.shuffle : Icons.format_list_numbered,
                        color: isShuffle
                            ? const Color(0xFFFF007F)
                            : const Color(0xFF00FFFF),
                        size: wide ? 26 : 22,
                      ),
                    ),
                    IconButton(
                      onPressed: canToggle
                          ? () => ref
                                .read(liveDjProvider.notifier)
                                .togglePlayPause()
                          : null,
                      icon: Icon(
                        state.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: const Color(0xFF39FF14).withValues(
                          alpha: canToggle ? 1 : 0.28,
                        ),
                        size: wide ? 46 : 40,
                      ),
                    ),
                    IconButton(
                      onPressed: canSkip
                          ? () => ref.read(liveDjProvider.notifier).forceNext()
                          : null,
                      icon: Icon(
                        Icons.skip_next,
                        color: canSkip ? Colors.white70 : Colors.white24,
                        size: wide ? 30 : 26,
                      ),
                    ),
                  ],
                ),
                if (nextName != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    color: const Color(0xFF00FFFF).withValues(alpha: 0.14),
                    child: Text(
                      nextName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF00FFFF),
                        fontFamily: 'Consolas',
                        fontSize: wide ? 12 : 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 2, wide ? 24 : 8, 2),
            child: Row(
              children: [
                const SizedBox(
                  width: 36,
                  child: Text(
                    '#',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                const Expanded(
                  child: Text(
                    'Título',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                if (_files.isNotEmpty)
                  TextButton.icon(
                    onPressed: () async {
                      final notifier = ref.read(liveDjProvider.notifier);
                      notifier.addAllTracks(_files);
                      if (ref.read(liveDjProvider).currentTrackPath == null) {
                        await notifier.togglePlayPause();
                      }
                    },
                    icon: const Icon(Icons.playlist_add_check, size: 16),
                    label: const Text(
                      'Cargar Carpeta',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: DjStudioTheme.cyanAccent,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: track == null
                ? const Center(
                    child: Text(
                      'Nada sonando',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : _files.isEmpty
                ? const Center(
                    child: Text(
                      'Carpeta vacía o sin MP3.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: _files.length,
                    itemBuilder: (context, index) {
                      final file = _files[index];
                      final playing =
                          track.isNotEmpty && _norm(track) == _norm(file.path);
                      return _SongRow(
                        index: index + 1,
                        file: file,
                        playing: playing,
                        onOpen: () async {
                          final notifier = ref.read(liveDjProvider.notifier);
                          notifier.addTrack(file);
                          if (ref.read(liveDjProvider).currentTrackPath ==
                              null) {
                            await notifier.togglePlayPause();
                          }
                        },
                        onAdd: () =>
                            ref.read(liveDjProvider.notifier).addTrack(file),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Widget _mixMarker(double inset, int mixMs, int durMs) {
  if (mixMs <= 0 || durMs <= 0 || mixMs >= durMs) {
    return const SizedBox.shrink();
  }
  return Positioned.fill(
    child: IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth - inset * 2;
          final x = inset + w * (mixMs / durMs).clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned(
                left: x - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.redAccent),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _OnAirBadge extends ConsumerWidget {
  final bool compact;
  const _OnAirBadge({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final radioOn = ref.watch(liveDjProvider.select((s) => s.radioOn));
    final color = radioOn
        ? DjStudioTheme.alertCritical
        : const Color(0xFF7A2E3E);
    return GestureDetector(
      onTap: () => ref.read(liveDjProvider.notifier).toggleRadio(),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10,
          vertical: compact ? 2 : 4,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: radioOn ? 0.1 : 0.05),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sensors, color: color, size: 12),
            const SizedBox(width: 5),
            Text(
              'ON AIR Radio',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadioChips extends ConsumerWidget {
  final bool compact;
  const _RadioChips({required this.compact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(liveDjProvider);
    Widget chip(String label, bool selected, VoidCallback onTap, {bool enabled = true}) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Opacity(
          opacity: enabled ? 1 : 0.3,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 2 : 4,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? DjStudioTheme.syncActive.withValues(alpha: 0.18)
                    : Colors.transparent,
                border: Border.all(
                  color: selected ? DjStudioTheme.syncActive : Colors.white24,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? DjStudioTheme.syncActive : Colors.white54,
                  fontWeight: FontWeight.bold,
                  fontSize: compact ? 10 : 11,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final notifier = ref.read(liveDjProvider.notifier);
    return SizedBox(
      height: compact ? 24 : 28,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip(
            'Todo',
            state.radioGenres.isEmpty,
            notifier.clearRadioGenres,
          ),
          for (final id in kRadioGenreIds)
            chip(
              kRadioGenreLabels[id]!,
              state.radioGenres.contains(id),
              () => notifier.toggleRadioGenre(id),
              enabled: state.radioGenresAvailable.contains(id),
            ),
        ],
      ),
    );
  }
}

class _NowCover extends StatelessWidget {
  final String artist;
  final double side;
  const _NowCover({required this.artist, required this.side});

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF1B4F72),
      child: Icon(Icons.music_note, color: Colors.white24, size: side * 0.4),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: side,
        height: side,
        child: artist.isEmpty
            ? fallback
            : FutureBuilder<ArtistInfo?>(
                future: loadArtistInfo(artist),
                builder: (context, snap) {
                  final photo = snap.data?.photoPath;
                  if (photo != null && File(photo).existsSync()) {
                    return Image.file(File(photo), fit: BoxFit.cover);
                  }
                  return fallback;
                },
              ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  final int index;
  final File file;
  final bool playing;
  final VoidCallback onOpen;
  final VoidCallback onAdd;

  const _SongRow({
    required this.index,
    required this.file,
    required this.playing,
    required this.onOpen,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final raw = file.uri.pathSegments.last;
    var name = raw;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    final artist = artistFromPath(file.path);
    final split = name.indexOf(' - ');
    final title = (artist.isNotEmpty && split > 0)
        ? name.substring(split + 3).trim()
        : name;

    return Material(
      color: playing
          ? DjStudioTheme.syncActive.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '$index',
                  style: TextStyle(
                    color: playing ? DjStudioTheme.syncActive : Colors.white38,
                    fontSize: 13,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: playing ? DjStudioTheme.syncActive : Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    if (artist.isNotEmpty)
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.add_circle_outline,
                  color: DjStudioTheme.cyanAccent,
                  size: 20,
                ),
                onPressed: onAdd,
                tooltip: 'Añadir a la Cola',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
