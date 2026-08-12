import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';

class StaticCache {
  // Ubicación nativa en Windows (AppData/Local)
  static File get _file {
    final dir = Platform.isWindows
        ? Platform.environment['LOCALAPPDATA']!
        : Platform.environment['HOME']!;
    return File('$dir${Platform.pathSeparator}djstudio_state.json');
  }

  static Future<Map<String, dynamic>> load() async {
    try {
      if (_file.existsSync()) {
        final content = await _file.readAsString();
        return jsonDecode(content);
      }
    } catch (e) {
      debugPrint("🔴 [JSON CACHE READ ERROR]: $e");
    }
    return {};
  }

  static Future<void> save({
    String? directory,
    List<String>? playlist,
    int? trackIndex,
    int? positionMs,
  }) async {
    try {
      Map<String, dynamic> data = await load();
      if (directory != null) data['directory'] = directory;
      if (playlist != null) data['playlist'] = playlist;
      if (trackIndex != null) data['trackIndex'] = trackIndex;
      if (positionMs != null) data['positionMs'] = positionMs;

      // Escritura atómica para evitar corrupción de Kernel
      final tempFile = File('${_file.path}.tmp');
      await tempFile.writeAsString(jsonEncode(data));
      if (_file.existsSync()) await _file.delete();
      await tempFile.rename(_file.path);
    } catch (e) {
      debugPrint("🔴 [JSON CACHE WRITE ERROR]: $e");
    }
  }
}
