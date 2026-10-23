import 'package:flutter/services.dart';

class ResolvedBookmark {
  final String path;
  final String? bookmark;

  const ResolvedBookmark({required this.path, this.bookmark});
}

/// Canal nativo: MediaStore, MPMediaLibrary, carpeta Música y bookmarks.
class LibraryChannel {
  static const MethodChannel _channel = MethodChannel(
    'com.gatonegro5.gatomix/library',
  );

  static Future<int> androidSdkInt() async {
    final int? value = await _channel.invokeMethod<int>('sdkInt');
    return value ?? 0;
  }

  static Future<List<Map<String, Object?>>> queryAndroidAudio() async {
    final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>(
      'queryAudio',
    );
    return _rows(raw);
  }

  static Future<List<Map<String, Object?>>> queryIosSongs() async {
    final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>(
      'queryLocalSongs',
    );
    return _rows(raw);
  }

  static Future<String?> macMusicFolder() {
    return _channel.invokeMethod<String>('musicFolder');
  }

  static Future<String?> makeBookmark(String path) {
    return _channel.invokeMethod<String>('bookmark', path);
  }

  static Future<ResolvedBookmark?> resolveBookmark(String bookmark) async {
    final Map<dynamic, dynamic>? raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('resolveBookmark', bookmark);
    if (raw == null) return null;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final Object? refreshed = raw['bookmark'];
    return ResolvedBookmark(
      path: path,
      bookmark: refreshed is String && refreshed.isNotEmpty ? refreshed : null,
    );
  }

  static List<Map<String, Object?>> _rows(List<dynamic>? raw) {
    if (raw == null) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    for (final dynamic row in raw) {
      if (row is Map) rows.add(Map<String, Object?>.from(row));
    }
    return rows;
  }
}

int libraryInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}
