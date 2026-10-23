import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/library/library_channel.dart';
import '../services/library/library_models.dart';
import '../services/library/library_sources.dart';
import '../services/library/library_store.dart';

/// Carpetas aceptadas. La comparten Automix y Live DJ.
class LibraryFoldersNotifier extends Notifier<List<LibraryFolderRecord>?> {
  int _epoch = 0;

  @override
  List<LibraryFolderRecord>? build() {
    unawaited(reload());
    return null;
  }

  Future<void> reload() async {
    final int ticket = ++_epoch;
    try {
      final List<LibraryFolderRecord> records = await LibraryStore.instance
          .acceptedFolders();
      if (ticket != _epoch) return;
      state = records;
    } catch (e) {
      debugPrint('library reload: $e');
      if (ticket != _epoch) return;
      try {
        state = const <LibraryFolderRecord>[];
      } catch (_) {}
    }
  }

  Future<void> add(String path, {String? label}) async {
    if (path.isEmpty) return;
    try {
      String? bookmark;
      if (Platform.isMacOS && isFileSystemFolder(path)) {
        try {
          bookmark = await LibraryChannel.makeBookmark(path);
        } catch (e) {
          debugPrint('library bookmark: $e');
        }
      }
      await LibraryStore.instance.addFolder(
        path,
        label: label,
        bookmark: bookmark,
      );
      unawaited(LibrarySources.indexFolder(path));
      await reload();
    } catch (e) {
      debugPrint('library add: $e');
    }
  }

  Future<void> remove(String path) async {
    if (path.isEmpty) return;
    try {
      await LibraryStore.instance.removeFolder(path);
      await reload();
    } catch (e) {
      debugPrint('library remove: $e');
    }
  }
}

final libraryFoldersProvider =
    NotifierProvider<LibraryFoldersNotifier, List<LibraryFolderRecord>?>(
      LibraryFoldersNotifier.new,
    );
