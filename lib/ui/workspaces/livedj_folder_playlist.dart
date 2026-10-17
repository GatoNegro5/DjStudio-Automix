import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/artist_info.dart';
import '../../providers/directory_provider.dart';
import '../../providers/livedj_provider.dart';
import '../../providers/theme_provider.dart';

/// Carpeta abierta a lo ancho: carátula, nombre grande y lista.
/// El Explorador y el Cartridge siguen en el código; esta vista solo los tapa.
class LiveDjFolderPlaylist extends ConsumerWidget {
  const LiveDjFolderPlaylist({super.key});

  Future<void> _loadFolder(WidgetRef ref, List<File> files) async {
    final notifier = ref.read(liveDjProvider.notifier);
    notifier.addAllTracks(files);
    if (ref.read(liveDjProvider).currentTrackPath == null) {
      await notifier.togglePlayPause();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dirState = ref.watch(liveDjDirectoryProvider);
    final current = ref.watch(
      liveDjProvider.select((s) => s.currentTrackPath),
    );
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final files = dirState.files.whereType<File>().toList();
    final folder = dirState.currentPath.isEmpty
        ? 'Selecciona carpeta...'
        : dirState.currentPath.replaceAll('\\', '/').split('/').last;
    final side = wide ? 200.0 : 112.0;

    return ColoredBox(
      color: DjStudioTheme.bgDark,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, wide ? 20 : 10, wide ? 24 : 12, wide ? 16 : 10),
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
                _FolderCover(files: files, side: side),
                SizedBox(width: wide ? 20 : 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: wide ? 40 : 26,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        files.isEmpty
                            ? 'Carpeta vacía o sin MP3.'
                            : '${files.length} canciones',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: wide ? 14 : 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        onPressed: files.isEmpty
                            ? null
                            : () => _loadFolder(ref, files),
                        icon: Icon(Icons.playlist_add_check, size: wide ? 16 : 14),
                        label: Text(
                          'Cargar Carpeta',
                          style: TextStyle(fontSize: wide ? 12 : 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white10,
                          foregroundColor: DjStudioTheme.cyanAccent,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: Size(0, wide ? 32 : 26),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 4, wide ? 24 : 8, 4),
            child: const Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    '#',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Título',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: files.isEmpty
                ? const Center(
                    child: Text(
                      'Carpeta vacía o sin MP3.',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      final playing = current != null && current == file.path;
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

class _FolderCover extends StatelessWidget {
  final List<File> files;
  final double side;
  const _FolderCover({required this.files, required this.side});

  @override
  Widget build(BuildContext context) {
    final artists = <String>[];
    for (final f in files) {
      final a = artistFromPath(f.path);
      final key = a.isEmpty ? f.path : a;
      if (artists.contains(key)) continue;
      artists.add(key);
      if (artists.length == 4) break;
    }
    while (artists.length < 4) {
      artists.add('');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: side,
        height: side,
        child: Column(
          children: [
            for (var r = 0; r < 2; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < 2; c++)
                      Expanded(child: _CoverTile(artist: artists[r * 2 + c])),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

const List<Color> _coverColors = [
  Color(0xFF1B4F72),
  Color(0xFF6C3483),
  Color(0xFF1A5276),
  Color(0xFF0E6655),
];

class _CoverTile extends StatelessWidget {
  final String artist;
  const _CoverTile({required this.artist});

  @override
  Widget build(BuildContext context) {
    final color = _coverColors[artist.hashCode.abs() % _coverColors.length];
    final name = artist.contains('/') || artist.contains('\\')
        ? artistFromPath(artist)
        : artist;
    if (name.isEmpty) {
      return ColoredBox(
        color: color,
        child: const Icon(Icons.music_note, color: Colors.white24, size: 22),
      );
    }
    return FutureBuilder<ArtistInfo?>(
      future: loadArtistInfo(name),
      builder: (context, snap) {
        final photo = snap.data?.photoPath;
        if (photo != null && File(photo).existsSync()) {
          return Image.file(
            File(photo),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => ColoredBox(
              color: color,
              child: const Icon(Icons.music_note, color: Colors.white24),
            ),
          );
        }
        return ColoredBox(
          color: color,
          child: const Icon(Icons.music_note, color: Colors.white24, size: 22),
        );
      },
    );
  }
}
