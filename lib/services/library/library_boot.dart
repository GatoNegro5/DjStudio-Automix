import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../providers/theme_provider.dart';
import '../../ui/library/library_review_screen.dart';
import 'library_channel.dart';
import 'library_models.dart';
import 'library_sources.dart';
import 'library_store.dart';

/// Primer arranque: explicación, permiso, escaneo, revisión.
/// Arranques siguientes: índice incremental en segundo plano.
class LibraryBoot {
  static Future<void> prepare(
    BuildContext context, {
    void Function(String status)? onStatus,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return;
    final LibrarySnapshot snapshot = await LibraryStore.instance.load();
    if (snapshot.reviewed) {
      unawaited(LibrarySources.incremental());
      return;
    }
    if (!context.mounted) return;
    await _explainAndRequest(context);
    if (!context.mounted) return;
    onStatus?.call('Buscando música...');
    List<DiscoveredTrack> tracks = const <DiscoveredTrack>[];
    try {
      tracks = await LibrarySources.discover();
    } catch (e) {
      debugPrint('library discover: $e');
    }
    if (!context.mounted) return;
    final List<DiscoveredFolder> folders = groupTracks(tracks);
    final Set<String>? chosen = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute<Set<String>>(
        fullscreenDialog: true,
        builder: (BuildContext context) =>
            LibraryReviewScreen(folders: folders),
      ),
    );
    final Set<String> accepted =
        chosen ?? folders.map((DiscoveredFolder f) => f.path).toSet();
    final Map<String, String?> bookmarks = await _bookmarks(folders, accepted);
    await LibraryStore.instance.commitReview(
      folders: folders,
      accepted: accepted,
      tracks: tracks,
      bookmarks: bookmarks,
    );
  }

  static Future<void> _explainAndRequest(BuildContext context) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: GatoMixTheme.bgPanel,
          title: const Text(
            'Música del dispositivo',
            style: TextStyle(color: GatoMixTheme.textMain, fontSize: 16),
          ),
          content: const Text(
            'GatoMix lee las canciones locales para armar la biblioteca. No las sube a internet.',
            style: TextStyle(color: GatoMixTheme.textMuted, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                'CONTINUAR',
                style: TextStyle(color: GatoMixTheme.syncActive),
              ),
            ),
          ],
        );
      },
    );
    await _requestPermission();
  }

  static Future<void> _requestPermission() async {
    if (Platform.isAndroid) {
      var sdk = 33;
      try {
        final int reported = await LibraryChannel.androidSdkInt();
        if (reported > 0) sdk = reported;
      } catch (_) {}
      if (sdk >= 33) {
        await Permission.audio.request();
      } else {
        await Permission.storage.request();
      }
      return;
    }
    if (Platform.isIOS) {
      await Permission.mediaLibrary.request();
    }
  }

  static Future<Map<String, String?>> _bookmarks(
    List<DiscoveredFolder> folders,
    Set<String> accepted,
  ) async {
    final Map<String, String?> bookmarks = <String, String?>{};
    if (!Platform.isMacOS) return bookmarks;
    for (final DiscoveredFolder folder in folders) {
      final bool keep = accepted.any(
        (String path) => sameFolder(path, folder.path),
      );
      if (!keep || !isFileSystemFolder(folder.path)) continue;
      try {
        bookmarks[folder.path] = await LibraryChannel.makeBookmark(folder.path);
      } catch (_) {
        bookmarks[folder.path] = null;
      }
    }
    return bookmarks;
  }
}
