import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Carpeta de música de DjIphone.
///
/// Vive en Documentos de la app. Con uso compartido de archivos, el iPhone
/// la muestra en Archivos → En mi iPhone → DjIphone → Music.
/// No es la biblioteca de Apple Music.
class IphoneLibrary {
  static String musicRoot = '';
  static String playlistsDir = '';

  static Future<void> ensure() async {
    final docs = await getApplicationDocumentsDirectory();
    final sep = Platform.pathSeparator;
    musicRoot = '${docs.path}${sep}Music';
    playlistsDir = '$musicRoot${sep}DjPlaylists';
    await Directory(playlistsDir).create(recursive: true);
  }
}
