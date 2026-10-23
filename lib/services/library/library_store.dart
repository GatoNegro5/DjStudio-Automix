import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'library_models.dart';

/// Lista aceptada y huellas (fecha + tamaño). Una sola cola de escritura.
class LibraryStore {
  static const String prefsKey = 'gatomix.library.v1';

  static final LibraryStore instance = LibraryStore();

  Future<void> _chain = Future<void>.value();

  Future<T> _sync<T>(Future<T> Function() action) {
    final Future<T> result = _chain.then((_) => action());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<LibrarySnapshot> load() => _sync(_read);

  Future<LibrarySnapshot> _read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return LibrarySnapshot.empty;
      return LibrarySnapshot.fromJson(jsonDecode(raw));
    } catch (_) {
      return LibrarySnapshot.empty;
    }
  }

  Future<void> _write(LibrarySnapshot snapshot) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(prefsKey, jsonEncode(snapshot.toJson()));
    } catch (_) {
      final LibrarySnapshot slim = snapshot.copyWith(
        index: const <String, TrackStamp>{},
      );
      await prefs.setString(prefsKey, jsonEncode(slim.toJson()));
    }
  }

  Future<void> save(LibrarySnapshot snapshot) => _sync(() => _write(snapshot));

  Future<List<LibraryFolderRecord>> acceptedFolders() async {
    final LibrarySnapshot snapshot = await load();
    final List<LibraryFolderRecord> accepted = snapshot.accepted;
    accepted.sort(
      (LibraryFolderRecord a, LibraryFolderRecord b) =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return accepted;
  }

  Future<void> addFolder(String path, {String? label, String? bookmark}) {
    return _sync(() async {
      final LibrarySnapshot snapshot = await _read();
      final LibraryFolderRecord incoming = LibraryFolderRecord(
        path: path,
        label: (label == null || label.isEmpty) ? baseName(path) : label,
        accepted: true,
        bookmark: bookmark,
      );
      await _write(
        snapshot.copyWith(
          reviewed: true,
          folders: foldersWithAdded(snapshot.folders, incoming),
        ),
      );
    });
  }

  Future<void> removeFolder(String path) {
    return _sync(() async {
      final LibrarySnapshot snapshot = await _read();
      await _write(
        snapshot.copyWith(
          folders: foldersWithout(snapshot.folders, path),
          index: indexWithoutFolder(snapshot.index, path),
        ),
      );
    });
  }

  Future<void> commitReview({
    required List<DiscoveredFolder> folders,
    required Set<String> accepted,
    required List<DiscoveredTrack> tracks,
    Map<String, String?> bookmarks = const <String, String?>{},
  }) {
    return _sync(() async {
      final List<LibraryFolderRecord> records = <LibraryFolderRecord>[];
      final Map<String, TrackStamp> index = <String, TrackStamp>{};
      for (final DiscoveredFolder folder in folders) {
        final bool keep = accepted.any(
          (String path) => sameFolder(path, folder.path),
        );
        String? bookmark;
        for (final MapEntry<String, String?> entry in bookmarks.entries) {
          if (sameFolder(entry.key, folder.path)) {
            bookmark = entry.value;
            break;
          }
        }
        records.add(
          LibraryFolderRecord(
            path: folder.path,
            label: folder.label,
            accepted: keep,
            bookmark: bookmark,
          ),
        );
      }
      for (final DiscoveredTrack track in tracks) {
        if (!accepted.any((String path) => sameFolder(path, track.folder))) {
          continue;
        }
        index[track.path] = TrackStamp(
          modifiedMs: track.modifiedMs,
          size: track.size,
          folder: track.folder,
        );
      }
      records.sort(
        (LibraryFolderRecord a, LibraryFolderRecord b) =>
            a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      await _write(
        LibrarySnapshot(reviewed: true, folders: records, index: index),
      );
    });
  }

  Future<void> applyDiff(IndexDiff diff) {
    return _sync(() async {
      final LibrarySnapshot snapshot = await _read();
      await _write(
        snapshot.copyWith(index: applyIndexDiff(snapshot.index, diff)),
      );
    });
  }

  Future<void> replaceBookmarks(Map<String, String> updates) {
    if (updates.isEmpty) return Future<void>.value();
    return _sync(() async {
      final LibrarySnapshot snapshot = await _read();
      final List<LibraryFolderRecord> folders = <LibraryFolderRecord>[];
      for (final LibraryFolderRecord folder in snapshot.folders) {
        String? next;
        for (final MapEntry<String, String> entry in updates.entries) {
          if (sameFolder(entry.key, folder.path)) {
            next = entry.value;
            break;
          }
        }
        folders.add(next == null ? folder : folder.copyWith(bookmark: next));
      }
      await _write(snapshot.copyWith(folders: folders));
    });
  }
}
