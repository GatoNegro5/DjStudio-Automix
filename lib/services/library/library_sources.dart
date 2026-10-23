import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../../djiphone/iphone_library.dart';
import 'library_channel.dart';
import 'library_models.dart';
import 'library_store.dart';
import 'windows_music_folder.dart';

class _FolderRead {
  final bool readable;
  final List<DiscoveredTrack> tracks;

  const _FolderRead(this.readable, this.tracks);
}

/// Descubrimiento del primer arranque y refresco incremental.
class LibrarySources {
  static Future<List<DiscoveredTrack>> discover() async {
    if (Platform.isAndroid) return _androidTracks();
    if (Platform.isIOS) return _iosTracks();
    if (Platform.isMacOS) {
      final String? root = await _macMusicRoot();
      if (root == null) return const <DiscoveredTrack>[];
      return _scanTree(root);
    }
    if (Platform.isWindows) {
      final String? known = windowsKnownMusicFolder();
      final String root = (known == null || known.isEmpty)
          ? legacyWindowsMusicFolder()
          : known;
      return _scanTree(root);
    }
    final String? home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return const <DiscoveredTrack>[];
    return _scanTree('$home/Music');
  }

  /// No bloquea la UI: el arranque lo dispara sin await.
  /// No analiza BPM ni tonalidad.
  static Future<void> incremental() async {
    try {
      await restoreMacAccess();
      final LibrarySnapshot snapshot = await LibraryStore.instance.load();
      if (!snapshot.reviewed) return;
      final List<LibraryFolderRecord> accepted = snapshot.accepted;
      if (accepted.isEmpty) return;

      final Set<String> scoped = <String>{};
      final Map<String, DiscoveredTrack> current = <String, DiscoveredTrack>{};

      if (Platform.isAndroid) {
        List<DiscoveredTrack> found;
        try {
          found = await _androidTracks();
        } catch (e) {
          debugPrint('library incremental android: $e');
          return;
        }
        for (final LibraryFolderRecord folder in accepted) {
          if (!isFileSystemFolder(folder.path)) continue;
          scoped.add(folder.path);
        }
        _takeScoped(current, found, scoped);
      } else {
        for (final LibraryFolderRecord folder in accepted) {
          if (!isFileSystemFolder(folder.path)) continue;
          final _FolderRead read = await _readFolder(folder.path);
          if (!read.readable) continue;
          scoped.add(folder.path);
          _takeScoped(current, read.tracks, <String>{folder.path});
        }
        if (Platform.isIOS) {
          try {
            final List<DiscoveredTrack> songs = await _iosMediaTracks();
            for (final LibraryFolderRecord folder in accepted) {
              if (isFileSystemFolder(folder.path)) continue;
              scoped.add(folder.path);
            }
            for (final DiscoveredTrack song in songs) {
              if (scoped.any(
                (String folder) => sameFolder(folder, song.folder),
              )) {
                current[song.path] = song;
              }
            }
          } catch (e) {
            debugPrint('library incremental ios: $e');
          }
        }
      }

      if (scoped.isEmpty) return;
      final IndexDiff diff = diffIndex(
        previous: snapshot.index,
        current: current.values.toList(growable: false),
        acceptedFolders: scoped,
      );
      if (diff.changed.isEmpty && diff.removed.isEmpty) return;
      await LibraryStore.instance.applyDiff(diff);
    } catch (e) {
      debugPrint('library incremental: $e');
    }
  }

  static Future<void> indexFolder(String path) async {
    if (!isFileSystemFolder(path)) return;
    try {
      final _FolderRead read = await _readFolder(path);
      if (!read.readable) return;
      final LibrarySnapshot snapshot = await LibraryStore.instance.load();
      final IndexDiff diff = diffIndex(
        previous: snapshot.index,
        current: read.tracks
            .map((DiscoveredTrack track) => track.scopedTo(path))
            .toList(growable: false),
        acceptedFolders: <String>{path},
      );
      if (diff.changed.isEmpty && diff.removed.isEmpty) return;
      await LibraryStore.instance.applyDiff(diff);
    } catch (e) {
      debugPrint('library index: $e');
    }
  }

  static Future<void> restoreMacAccess() async {
    if (!Platform.isMacOS) return;
    final LibrarySnapshot snapshot = await LibraryStore.instance.load();
    final Map<String, String> refreshed = <String, String>{};
    for (final LibraryFolderRecord folder in snapshot.folders) {
      final String? bookmark = folder.bookmark;
      if (!folder.accepted || bookmark == null || bookmark.isEmpty) continue;
      try {
        final ResolvedBookmark? resolved = await LibraryChannel.resolveBookmark(
          bookmark,
        );
        final String? next = resolved?.bookmark;
        if (next != null && next.isNotEmpty && next != bookmark) {
          refreshed[folder.path] = next;
        }
      } catch (e) {
        debugPrint('library bookmark: $e');
      }
    }
    if (refreshed.isNotEmpty) {
      await LibraryStore.instance.replaceBookmarks(refreshed);
    }
  }

  /// El selector de documentos de iOS copia a la carpeta de la app.
  static Future<String?> importAudioFiles() async {
    const XTypeGroup group = XTypeGroup(
      label: 'audio',
      extensions: <String>['mp3', 'm4a', 'wav', 'webm'],
      uniformTypeIdentifiers: <String>[
        'public.mp3',
        'public.mpeg-4-audio',
        'com.microsoft.waveform-audio',
        'public.audio',
      ],
    );
    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[group],
    );
    if (files.isEmpty) return null;
    if (IphoneLibrary.musicRoot.isEmpty) {
      await IphoneLibrary.ensure();
    }
    final String root = IphoneLibrary.musicRoot;
    if (root.isEmpty) return null;
    final String destPath = '$root${Platform.pathSeparator}Importados';
    final Directory destDir = Directory(destPath);
    await destDir.create(recursive: true);
    var wrote = false;
    for (final XFile file in files) {
      final String name = file.name.replaceAll('\\', '/').split('/').last;
      if (name.isEmpty || name.contains('..')) continue;
      if (!isLibraryAudio(name)) continue;
      final File dest = File('$destPath${Platform.pathSeparator}$name');
      if (await dest.exists()) {
        wrote = true;
        continue;
      }
      try {
        await file.saveTo(dest.path);
        wrote = true;
      } catch (e) {
        debugPrint('library import: $e');
      }
    }
    if (!wrote) return null;
    return destPath;
  }

  static Future<List<DiscoveredTrack>> _androidTracks() async {
    final List<Map<String, Object?>> rows =
        await LibraryChannel.queryAndroidAudio();
    final List<DiscoveredTrack> tracks = <DiscoveredTrack>[];
    for (final Map<String, Object?> row in rows) {
      final Object? path = row['path'];
      if (path is! String || path.isEmpty || !isLibraryAudio(path)) continue;
      tracks.add(
        DiscoveredTrack.fromFile(
          path: path,
          modifiedMs: libraryInt(row['modifiedMs']),
          size: libraryInt(row['size']),
        ),
      );
    }
    return tracks;
  }

  static Future<List<DiscoveredTrack>> _iosTracks() async {
    final List<DiscoveredTrack> tracks = <DiscoveredTrack>[];
    if (IphoneLibrary.musicRoot.isEmpty) {
      try {
        await IphoneLibrary.ensure();
      } catch (e) {
        debugPrint('library ios documents: $e');
      }
    }
    if (IphoneLibrary.musicRoot.isNotEmpty) {
      tracks.addAll(await _scanTree(IphoneLibrary.musicRoot));
    }
    try {
      tracks.addAll(await _iosMediaTracks());
    } catch (e) {
      debugPrint('library ios media: $e');
    }
    return tracks;
  }

  static Future<List<DiscoveredTrack>> _iosMediaTracks() async {
    final List<Map<String, Object?>> rows =
        await LibraryChannel.queryIosSongs();
    final List<DiscoveredTrack> tracks = <DiscoveredTrack>[];
    for (final Map<String, Object?> row in rows) {
      final Object? path = row['path'];
      final Object? folder = row['folder'];
      if (path is! String || path.isEmpty) continue;
      if (folder is! String || folder.isEmpty) continue;
      final Object? label = row['label'];
      tracks.add(
        DiscoveredTrack(
          path: path,
          modifiedMs: libraryInt(row['modifiedMs']),
          size: libraryInt(row['size']),
          folder: folder,
          folderLabel: label is String && label.isNotEmpty
              ? label
              : 'Apple Music',
        ),
      );
    }
    return tracks;
  }

  static Future<String?> _macMusicRoot() async {
    try {
      final String? path = await LibraryChannel.macMusicFolder();
      if (path != null && path.isNotEmpty) return path;
    } catch (e) {
      debugPrint('library mac music folder: $e');
    }
    final String? home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/Music';
  }

  static Future<List<DiscoveredTrack>> _scanTree(String root) async {
    final _FolderRead read = await _readFolder(root);
    return read.tracks;
  }

  static Future<_FolderRead> _readFolder(String path) async {
    try {
      final Directory dir = Directory(path);
      if (!await dir.exists()) {
        return const _FolderRead(false, <DiscoveredTrack>[]);
      }
      final List<DiscoveredTrack> tracks = <DiscoveredTrack>[];
      final Stream<FileSystemEntity> stream = dir
          .list(recursive: true, followLinks: false)
          .handleError((Object e) {
            debugPrint('library scan: $e');
          });
      await for (final FileSystemEntity entity in stream) {
        if (entity is! File) continue;
        if (!isLibraryAudio(entity.path)) continue;
        final FileStat stat = await entity.stat();
        if (stat.type == FileSystemEntityType.notFound) continue;
        tracks.add(
          DiscoveredTrack.fromFile(
            path: entity.path,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            size: stat.size,
          ),
        );
      }
      return _FolderRead(true, tracks);
    } catch (e) {
      debugPrint('library folder: $e');
      return const _FolderRead(false, <DiscoveredTrack>[]);
    }
  }

  static void _takeScoped(
    Map<String, DiscoveredTrack> into,
    List<DiscoveredTrack> found,
    Set<String> accepted,
  ) {
    for (final DiscoveredTrack track in found) {
      final String? folder = catalogFolderFor(track.path, accepted);
      if (folder == null) continue;
      final DiscoveredTrack scoped = track.scopedTo(folder);
      final DiscoveredTrack? existing = into[scoped.path];
      if (existing == null ||
          folderIdentity(scoped.folder).length >
              folderIdentity(existing.folder).length) {
        into[scoped.path] = scoped;
      }
    }
  }
}
