/// Nombre visible de una pista de Live DJ, sin leer el archivo.
///
/// Prioridad de quien llama: si hay ID3, TIT2/TPE1 mandan; si no, este parseo.
/// Un prefijo que es solo un BPM (40–250) no es artista ni título:
/// `112 - Artista - Título`, `Artista - Título`, `112 - Título`.
class TrackFileName {
  final String artist;
  final String title;

  /// El archivo era `BPM - un solo nombre` (no había `Artista - Título`).
  final bool bpmSingle;

  const TrackFileName({
    this.artist = '',
    this.title = '',
    this.bpmSingle = false,
  });
}

class TrackDisplay {
  /// Línea grande: artista si existe; si no, el título.
  final String headline;

  /// Subtítulo: título de la canción cuando también hay artista.
  final String subtitle;

  /// Artista para la carátula. Vacío si el nombre no trae artista.
  final String artist;

  const TrackDisplay({
    required this.headline,
    required this.subtitle,
    required this.artist,
  });
}

final RegExp _bpmToken = RegExp(r'^\d{2,3}(?:\.\d+)?$');

bool _isBpmPrefix(String token) {
  if (!_bpmToken.hasMatch(token)) return false;
  final double? v = double.tryParse(token);
  return v != null && v >= 40 && v <= 250;
}

/// Artista y título a partir de la ruta. No toca disco ni etiquetas.
TrackFileName parseTrackFileName(String path) {
  var name = path.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.trim();
  if (name.isEmpty) return const TrackFileName();

  final List<String> parts = name
      .split(' - ')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
  if (parts.isEmpty) return TrackFileName(title: name);

  final bool bpm = _isBpmPrefix(parts.first);
  final List<String> rest = bpm ? parts.sublist(1) : parts;
  if (rest.isEmpty) return TrackFileName(title: name);
  if (rest.length == 1) {
    return TrackFileName(title: rest.first, bpmSingle: bpm);
  }
  return TrackFileName(artist: rest.first, title: rest.sublist(1).join(' - '));
}

/// Junta el parseo del nombre con TIT2/TPE1. Una etiqueta no vacía gana
/// a su campo. Si el archivo es `BPM - Nombre` y el ID3 trae título pero
/// no artista, [Nombre] se queda como artista (línea grande) y TIT2 baja
/// al subtítulo: es el caso en que el nombre guardó al artista y el
/// título solo está en la etiqueta.
TrackDisplay resolveTrackDisplay({
  required TrackFileName file,
  String id3Artist = '',
  String id3Title = '',
}) {
  final String tagArtist = id3Artist.trim();
  final String tagTitle = id3Title.trim();
  String artist = tagArtist.isNotEmpty ? tagArtist : file.artist;
  String title = tagTitle.isNotEmpty ? tagTitle : file.title;
  if (file.bpmSingle &&
      tagArtist.isEmpty &&
      tagTitle.isNotEmpty &&
      tagTitle != file.title &&
      file.title.isNotEmpty) {
    artist = file.title;
    title = tagTitle;
  }
  if (artist.isNotEmpty) {
    final String subtitle = (title.isNotEmpty && title != artist) ? title : '';
    return TrackDisplay(headline: artist, subtitle: subtitle, artist: artist);
  }
  return TrackDisplay(headline: title, subtitle: '', artist: '');
}
