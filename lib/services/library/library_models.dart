import 'dart:io';

/// Audio que el explorador ya sabe abrir. Misma lista que `DirectoryNotifier`.
const List<String> kLibraryAudioExtensions = <String>[
  '.mp3',
  '.m4a',
  '.wav',
  '.webm',
];

bool isLibraryAudio(String path) {
  final String bare = path.split('?').first.toLowerCase();
  for (final String ext in kLibraryAudioExtensions) {
    if (bare.endsWith(ext)) return true;
  }
  return false;
}

/// Carpeta de catálogo que no es un directorio del disco (álbum de iOS).
bool isFileSystemFolder(String path) {
  if (path.startsWith('album:')) return false;
  if (path.contains('://')) return false;
  return true;
}

String parentOf(String path) {
  final int slash = path.lastIndexOf('/');
  final int back = path.lastIndexOf('\\');
  final int index = slash > back ? slash : back;
  if (index <= 0) return path;
  return path.substring(0, index);
}

String baseName(String path) {
  final int slash = path.lastIndexOf('/');
  final int back = path.lastIndexOf('\\');
  final int index = slash > back ? slash : back;
  if (index < 0 || index >= path.length - 1) return path;
  return path.substring(index + 1);
}

/// Identidad estable de una carpeta. Las barras se unifican.
/// Windows y macOS no distinguen mayúsculas; Android e iOS sí.
String folderIdentity(String path) {
  var value = path.replaceAll('\\', '/');
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  if (Platform.isWindows || Platform.isMacOS) return value.toLowerCase();
  return value;
}

bool sameFolder(String a, String b) => folderIdentity(a) == folderIdentity(b);

/// `file` vive en `folder` o en un subdirectorio. `rock2` no cae dentro de `rock`.
bool pathUnder(String file, String folder) {
  final String f = folderIdentity(file);
  final String root = folderIdentity(folder);
  if (f == root) return true;
  return f.startsWith('$root/');
}

class DiscoveredTrack {
  final String path;
  final int modifiedMs;
  final int size;
  final String folder;
  final String? folderLabel;

  const DiscoveredTrack({
    required this.path,
    required this.modifiedMs,
    required this.size,
    required this.folder,
    this.folderLabel,
  });

  factory DiscoveredTrack.fromFile({
    required String path,
    required int modifiedMs,
    required int size,
  }) {
    final String folder = parentOf(path);
    return DiscoveredTrack(
      path: path,
      modifiedMs: modifiedMs,
      size: size,
      folder: folder,
      folderLabel: baseName(folder),
    );
  }

  DiscoveredTrack scopedTo(String folder) {
    return DiscoveredTrack(
      path: path,
      modifiedMs: modifiedMs,
      size: size,
      folder: folder,
      folderLabel: folderLabel,
    );
  }
}

class DiscoveredFolder {
  final String path;
  final String label;
  final int trackCount;

  const DiscoveredFolder({
    required this.path,
    required this.label,
    required this.trackCount,
  });
}

List<DiscoveredFolder> groupTracks(List<DiscoveredTrack> tracks) {
  final Map<String, List<DiscoveredTrack>> buckets = {};
  for (final DiscoveredTrack track in tracks) {
    buckets.putIfAbsent(track.folder, () => <DiscoveredTrack>[]).add(track);
  }
  final List<DiscoveredFolder> folders = <DiscoveredFolder>[];
  for (final MapEntry<String, List<DiscoveredTrack>> entry in buckets.entries) {
    final String? named = entry.value.first.folderLabel;
    final String label = (named == null || named.isEmpty)
        ? baseName(entry.key)
        : named;
    folders.add(
      DiscoveredFolder(
        path: entry.key,
        label: label,
        trackCount: entry.value.length,
      ),
    );
  }
  folders.sort(
    (DiscoveredFolder a, DiscoveredFolder b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );
  return folders;
}

class TrackStamp {
  final int modifiedMs;
  final int size;
  final String folder;

  const TrackStamp({
    required this.modifiedMs,
    required this.size,
    required this.folder,
  });

  TrackStamp copyWith({int? modifiedMs, int? size, String? folder}) {
    return TrackStamp(
      modifiedMs: modifiedMs ?? this.modifiedMs,
      size: size ?? this.size,
      folder: folder ?? this.folder,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'm': modifiedMs,
    's': size,
    'f': folder,
  };

  static TrackStamp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? modified = raw['m'];
    final Object? size = raw['s'];
    final Object? folder = raw['f'];
    if (folder is! String || folder.isEmpty) return null;
    return TrackStamp(
      modifiedMs: modified is num ? modified.toInt() : 0,
      size: size is num ? size.toInt() : 0,
      folder: folder,
    );
  }
}

class IndexDiff {
  final List<DiscoveredTrack> changed;
  final List<String> removed;

  const IndexDiff({required this.changed, required this.removed});
}

bool _folderIn(String folder, Set<String> accepted) {
  for (final String item in accepted) {
    if (sameFolder(item, folder)) return true;
  }
  return false;
}

/// Solo compara pistas cuyo `folder` está en [acceptedFolders].
/// Una carpeta ausente de ese conjunto no se borra del índice
/// (volumen desmontado o consulta fallida).
IndexDiff diffIndex({
  required Map<String, TrackStamp> previous,
  required List<DiscoveredTrack> current,
  required Set<String> acceptedFolders,
}) {
  final Map<String, DiscoveredTrack> seen = <String, DiscoveredTrack>{};
  final List<DiscoveredTrack> changed = <DiscoveredTrack>[];
  for (final DiscoveredTrack track in current) {
    if (!_folderIn(track.folder, acceptedFolders)) continue;
    final DiscoveredTrack? existing = seen[track.path];
    if (existing != null &&
        folderIdentity(existing.folder).length >=
            folderIdentity(track.folder).length) {
      continue;
    }
    seen[track.path] = track;
  }
  for (final DiscoveredTrack track in seen.values) {
    final TrackStamp? old = previous[track.path];
    if (old == null ||
        old.modifiedMs != track.modifiedMs ||
        old.size != track.size) {
      changed.add(track);
    }
  }
  final List<String> removed = <String>[];
  for (final MapEntry<String, TrackStamp> entry in previous.entries) {
    if (!_folderIn(entry.value.folder, acceptedFolders)) continue;
    if (!seen.containsKey(entry.key)) removed.add(entry.key);
  }
  return IndexDiff(changed: changed, removed: removed);
}

Map<String, TrackStamp> applyIndexDiff(
  Map<String, TrackStamp> previous,
  IndexDiff diff,
) {
  final Map<String, TrackStamp> next = Map<String, TrackStamp>.from(previous);
  for (final String path in diff.removed) {
    next.remove(path);
  }
  for (final DiscoveredTrack track in diff.changed) {
    next[track.path] = TrackStamp(
      modifiedMs: track.modifiedMs,
      size: track.size,
      folder: track.folder,
    );
  }
  return next;
}

/// Carpeta de catálogo más específica que contiene [filePath].
String? catalogFolderFor(String filePath, Iterable<String> accepted) {
  String? best;
  var bestLength = -1;
  for (final String folder in accepted) {
    if (!isFileSystemFolder(folder)) continue;
    if (!pathUnder(filePath, folder)) continue;
    final int length = folderIdentity(folder).length;
    if (length > bestLength) {
      best = folder;
      bestLength = length;
    }
  }
  return best;
}

class LibraryFolderRecord {
  final String path;
  final String label;
  final bool accepted;
  final String? bookmark;

  const LibraryFolderRecord({
    required this.path,
    required this.label,
    required this.accepted,
    this.bookmark,
  });

  LibraryFolderRecord copyWith({
    String? path,
    String? label,
    bool? accepted,
    String? bookmark,
    bool clearBookmark = false,
  }) {
    return LibraryFolderRecord(
      path: path ?? this.path,
      label: label ?? this.label,
      accepted: accepted ?? this.accepted,
      bookmark: clearBookmark ? null : (bookmark ?? this.bookmark),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'label': label,
    'accepted': accepted,
    'bookmark': bookmark,
  };

  static LibraryFolderRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final Object? label = raw['label'];
    final Object? bookmark = raw['bookmark'];
    return LibraryFolderRecord(
      path: path,
      label: label is String && label.isNotEmpty ? label : baseName(path),
      accepted: raw['accepted'] != false,
      bookmark: bookmark is String && bookmark.isNotEmpty ? bookmark : null,
    );
  }
}

List<LibraryFolderRecord> foldersWithAdded(
  List<LibraryFolderRecord> folders,
  LibraryFolderRecord incoming,
) {
  final List<LibraryFolderRecord> next = <LibraryFolderRecord>[];
  var replaced = false;
  for (final LibraryFolderRecord folder in folders) {
    if (sameFolder(folder.path, incoming.path)) {
      next.add(
        incoming.copyWith(
          bookmark: incoming.bookmark ?? folder.bookmark,
          label: incoming.label.isEmpty ? folder.label : incoming.label,
        ),
      );
      replaced = true;
    } else {
      next.add(folder);
    }
  }
  if (!replaced) next.add(incoming);
  next.sort(
    (LibraryFolderRecord a, LibraryFolderRecord b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );
  return next;
}

List<LibraryFolderRecord> foldersWithout(
  List<LibraryFolderRecord> folders,
  String path,
) {
  return folders
      .where((LibraryFolderRecord f) => !sameFolder(f.path, path))
      .toList();
}

Map<String, TrackStamp> indexWithoutFolder(
  Map<String, TrackStamp> index,
  String path,
) {
  final Map<String, TrackStamp> next = <String, TrackStamp>{};
  for (final MapEntry<String, TrackStamp> entry in index.entries) {
    final bool inFolder =
        sameFolder(entry.value.folder, path) || pathUnder(entry.key, path);
    if (!inFolder) next[entry.key] = entry.value;
  }
  return next;
}

class LibrarySnapshot {
  final bool reviewed;
  final List<LibraryFolderRecord> folders;
  final Map<String, TrackStamp> index;

  const LibrarySnapshot({
    required this.reviewed,
    required this.folders,
    required this.index,
  });

  static const LibrarySnapshot empty = LibrarySnapshot(
    reviewed: false,
    folders: <LibraryFolderRecord>[],
    index: <String, TrackStamp>{},
  );

  List<LibraryFolderRecord> get accepted => folders
      .where((LibraryFolderRecord folder) => folder.accepted)
      .toList(growable: false);

  LibrarySnapshot copyWith({
    bool? reviewed,
    List<LibraryFolderRecord>? folders,
    Map<String, TrackStamp>? index,
  }) {
    return LibrarySnapshot(
      reviewed: reviewed ?? this.reviewed,
      folders: folders ?? this.folders,
      index: index ?? this.index,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'reviewed': reviewed,
    'folders': folders.map((LibraryFolderRecord f) => f.toJson()).toList(),
    'index': index.map(
      (String path, TrackStamp stamp) => MapEntry(path, stamp.toJson()),
    ),
  };

  static LibrarySnapshot fromJson(Object? raw) {
    if (raw is! Map) return LibrarySnapshot.empty;
    final List<LibraryFolderRecord> folders = <LibraryFolderRecord>[];
    final Object? rawFolders = raw['folders'];
    if (rawFolders is List) {
      for (final Object? item in rawFolders) {
        final LibraryFolderRecord? folder = LibraryFolderRecord.fromJson(item);
        if (folder != null) folders.add(folder);
      }
    }
    final Map<String, TrackStamp> index = <String, TrackStamp>{};
    final Object? rawIndex = raw['index'];
    if (rawIndex is Map) {
      for (final MapEntry<Object?, Object?> entry in rawIndex.entries) {
        final Object? key = entry.key;
        if (key is! String || key.isEmpty) continue;
        final TrackStamp? stamp = TrackStamp.fromJson(entry.value);
        if (stamp != null) index[key] = stamp;
      }
    }
    return LibrarySnapshot(
      reviewed: raw['reviewed'] == true,
      folders: folders,
      index: index,
    );
  }
}
