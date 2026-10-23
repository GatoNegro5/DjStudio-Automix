import 'dart:io';
import 'dart:typed_data';

import '../core/id3_names.dart';

final Map<String, Future<Id3Names>> _cache = {};

/// TIT2 / TPE1 / TALB de un archivo, sin decodificar el audio y sin abrir un
/// reproductor. Igual en Windows, Android, macOS e iPhone: solo lee la
/// cabecera ID3v2. Sin etiqueta, cadenas vacías y el nombre de archivo manda.
Future<Id3Names> loadId3TitleArtist(String path) {
  final Future<Id3Names>? hit = _cache[path];
  if (hit != null) return hit;
  final Future<Id3Names> fut = _read(path);
  _cache[path] = fut;
  fut.then((Id3Names v) {
    if (v.title.isEmpty && v.artist.isEmpty) {
      Future<void>.delayed(const Duration(seconds: 45), () {
        if (identical(_cache[path], fut)) _cache.remove(path);
      });
    }
  });
  return fut;
}

Future<Id3Names> _read(String path) async {
  RandomAccessFile? raf;
  try {
    final File file = File(path);
    if (!await file.exists()) return const Id3Names();
    raf = await file.open();
    final List<int> head = await raf.read(10);
    if (head.length < 10 ||
        head[0] != 0x49 ||
        head[1] != 0x44 ||
        head[2] != 0x33) {
      return const Id3Names();
    }
    final int size =
        (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
    if (size <= 0 || size > 4 * 1024 * 1024) return const Id3Names();
    final List<int> body = await raf.read(size);
    final Uint8List bytes = Uint8List(10 + body.length);
    bytes.setRange(0, head.length, head);
    bytes.setRange(10, 10 + body.length, body);
    return parseId3Names(bytes);
  } catch (_) {
    return const Id3Names();
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}
