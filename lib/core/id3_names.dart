import 'dart:convert';

/// TIT2 (título), TPE1 (artista) y TALB (álbum) de un bloque ID3v2 ya leído.
/// ID3v2.2 usa TT2 / TP1 / TAL, el mismo dato con el id corto.
class Id3Names {
  final String title;
  final String artist;
  final String album;

  const Id3Names({this.title = '', this.artist = '', this.album = ''});
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

List<int> _deunsync(List<int> src) {
  final List<int> out = <int>[];
  for (int i = 0; i < src.length; i++) {
    out.add(src[i]);
    if (src[i] == 0xFF && i + 1 < src.length && src[i + 1] == 0x00) {
      i++;
    }
  }
  return out;
}

String _latin1UntilNull(List<int> data) {
  final int end = data.indexOf(0);
  final List<int> slice = end >= 0 ? data.sublist(0, end) : data;
  return latin1.decode(slice, allowInvalid: true);
}

String _utf8UntilNull(List<int> data) {
  final int end = data.indexOf(0);
  final List<int> slice = end >= 0 ? data.sublist(0, end) : data;
  return utf8.decode(slice, allowMalformed: true);
}

String _utf16UntilNull(
  List<int> data, {
  required bool withBom,
  bool bigEndian = false,
}) {
  if (data.length < 2) return '';
  var i = 0;
  var be = bigEndian;
  if (withBom) {
    if (data[0] == 0xFE && data[1] == 0xFF) {
      be = true;
      i = 2;
    } else if (data[0] == 0xFF && data[1] == 0xFE) {
      be = false;
      i = 2;
    }
  }
  final List<int> units = <int>[];
  while (i + 1 < data.length) {
    final int hi = be ? data[i] : data[i + 1];
    final int lo = be ? data[i + 1] : data[i];
    final int cu = (hi << 8) | lo;
    if (cu == 0) break;
    units.add(cu);
    i += 2;
  }
  return String.fromCharCodes(units);
}

String _decodeTextFrame(List<int> data) {
  if (data.isEmpty) return '';
  final int enc = data[0];
  final List<int> raw = data.sublist(1);
  final String text;
  switch (enc) {
    case 0:
      text = _latin1UntilNull(raw);
    case 1:
      text = _utf16UntilNull(raw, withBom: true);
    case 2:
      text = _utf16UntilNull(raw, withBom: false, bigEndian: true);
    case 3:
      text = _utf8UntilNull(raw);
    default:
      return '';
  }
  return text.trim();
}

/// Lee TIT2, TPE1 y TALB de los bytes de la etiqueta (cabecera incluida).
/// No decodifica audio. Si el bloque no es ID3v2, devuelve cadenas vacías.
Id3Names parseId3Names(List<int> bytes) {
  if (bytes.length < 10) return const Id3Names();
  if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
    return const Id3Names();
  }
  final int ver = bytes[3];
  if (ver < 2 || ver > 4) return const Id3Names();
  final int flags = bytes[5];
  final int declared = _syncsafe(bytes, 6);
  final int available = bytes.length - 10;
  final int size = declared < available ? declared : available;
  if (size <= 0) return const Id3Names();
  List<int> body = bytes.sublist(10, 10 + size);
  if ((flags & 0x80) != 0) body = _deunsync(body);

  var pos = 0;
  if (ver >= 3 && (flags & 0x40) != 0 && body.length >= 4) {
    if (ver == 4) {
      pos = _syncsafe(body, 0);
    } else {
      final int ext =
          (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
      pos = 4 + ext;
    }
    if (pos < 0 || pos > body.length) return const Id3Names();
  }

  String title = '';
  String artist = '';
  String album = '';
  final int hdrLen = ver == 2 ? 6 : 10;
  while (pos + hdrLen <= body.length &&
      (title.isEmpty || artist.isEmpty || album.isEmpty)) {
    if (body[pos] == 0) break;
    final int idLen = ver == 2 ? 3 : 4;
    final String id = latin1.decode(
      body.sublist(pos, pos + idLen),
      allowInvalid: true,
    );
    if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id)) break;

    final int frameSize;
    final int dataStart;
    var flagB = 0;
    if (ver == 2) {
      frameSize = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5];
      dataStart = pos + 6;
    } else {
      frameSize = ver == 4
          ? _syncsafe(body, pos + 4)
          : (body[pos + 4] << 24) |
                (body[pos + 5] << 16) |
                (body[pos + 6] << 8) |
                body[pos + 7];
      flagB = body[pos + 9];
      dataStart = pos + 10;
    }
    if (frameSize < 0 || dataStart + frameSize > body.length) break;

    final bool isTitle = id == 'TIT2' || id == 'TT2';
    final bool isArtist = id == 'TPE1' || id == 'TP1';
    final bool isAlbum = id == 'TALB' || id == 'TAL';
    if (isTitle || isArtist || isAlbum) {
      var skip = 0;
      var compressed = false;
      var encrypted = false;
      if (ver == 3) {
        compressed = (flagB & 0x80) != 0;
        encrypted = (flagB & 0x40) != 0;
        if ((flagB & 0x20) != 0) skip += 1;
      } else if (ver == 4) {
        compressed = (flagB & 0x08) != 0;
        encrypted = (flagB & 0x04) != 0;
        if ((flagB & 0x40) != 0) skip += 1;
        if ((flagB & 0x01) != 0) skip += 4;
      }
      if (!compressed && !encrypted && frameSize > skip) {
        List<int> data = body.sublist(dataStart + skip, dataStart + frameSize);
        if (ver == 4 && (flagB & 0x02) != 0) data = _deunsync(data);
        final String text = _decodeTextFrame(data);
        if (text.isNotEmpty) {
          if (isTitle && title.isEmpty) title = text;
          if (isArtist && artist.isEmpty) artist = text;
          if (isAlbum && album.isEmpty) album = text;
        }
      }
    }
    pos = dataStart + frameSize;
  }
  return Id3Names(title: title, artist: artist, album: album);
}
