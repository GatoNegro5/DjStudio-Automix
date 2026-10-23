import 'track_name_clean.dart';

/// Tolerancia de duración contra LRCLIB, en segundos.
const int kLyricDurationTolSec = 2;

/// La última línea sincronizada tiene que quedar a esta distancia del final.
const int kLyricEndSlackMs = 20000;

enum LyricKind { none, synced, plain }

/// Qué se puede guardar. [body] de una plana no trae tiempos.
class LyricChoice {
  final LyricKind kind;
  final String body;

  /// El servidor no contestó y no hubo un candidato utilizable.
  final bool serverDown;

  const LyricChoice({
    required this.kind,
    this.body = '',
    this.serverDown = false,
  });

  const LyricChoice.none() : this(kind: LyricKind.none);

  const LyricChoice.down()
    : this(kind: LyricKind.none, serverDown: true);

  bool get hasText => kind != LyricKind.none && body.trim().isNotEmpty;

  /// Texto que se escribe en el `.lrc`. La plana lleva la marca y cero sellos.
  String get fileText {
    if (kind == LyricKind.plain) {
      final String bare = body.replaceAll(_lrcStamp, '').trim();
      return '[gmx_plain:1]\n$bare';
    }
    return body;
  }
}

/// Artista, título y álbum con los que se pide la letra, y la duración medida.
class LyricIdentity {
  final String artist;
  final String title;
  final String album;
  final int durationSec;
  final bool remixOrExtended;

  const LyricIdentity({
    required this.artist,
    required this.title,
    this.album = '',
    required this.durationSec,
    this.remixOrExtended = false,
  });
}

const Map<String, String> _accents = {
  'á': 'a',
  'é': 'e',
  'í': 'i',
  'ó': 'o',
  'ú': 'u',
  'ü': 'u',
  'ñ': 'n',
  'à': 'a',
  'è': 'e',
  'ì': 'i',
  'ò': 'o',
  'ù': 'u',
};

/// Minúsculas, sin acentos, sin paréntesis y sin el feat. del final.
String lyricNorm(String s) {
  var t = s.toLowerCase();
  _accents.forEach((String k, String v) => t = t.replaceAll(k, v));
  t = t.replaceAll(RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
  t = t.replaceAll(RegExp(r'\b(feat|ft|featuring)\b.*$'), ' ');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  return t;
}

bool lyricNamesEqual(String a, String b) {
  final String na = lyricNorm(a);
  final String nb = lyricNorm(b);
  return na.isNotEmpty && na == nb;
}

final RegExp _remixMark = RegExp(
  r'remix|extended|extendid|versi[oó]n larga',
  caseSensitive: false,
);

bool lyricLooksRemixOrExtended(String raw) => _remixMark.hasMatch(raw);

final RegExp _audioExt = RegExp(
  r'\.(mp3|m4a|webm|flac|wav|ogg|aac)$',
  caseSensitive: false,
);

/// ID3 primero. El nombre del archivo solo rellena el artista o el título
/// que la etiqueta no trae, pasando por [cleanTrackFileName].
LyricIdentity lyricIdentity({
  required String path,
  String id3Artist = '',
  String id3Title = '',
  String id3Album = '',
  required int durationSec,
}) {
  final String stem = _stem(path);
  final CleanTrackName file = cleanTrackFileName(
    stem,
    id3Artist: id3Artist,
    id3Title: id3Title,
  );
  final String artist = id3Artist.trim().isNotEmpty
      ? id3Artist.trim()
      : file.artist;
  final String title = id3Title.trim().isNotEmpty
      ? id3Title.trim()
      : file.title;
  final bool remix = lyricLooksRemixOrExtended('$stem $id3Title $id3Album');
  return LyricIdentity(
    artist: artist,
    title: title,
    album: id3Album.trim(),
    durationSec: durationSec,
    remixOrExtended: remix,
  );
}

String _stem(String path) {
  var name = path.trim().replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  return name.replaceAll(_audioExt, '');
}

/// `GET /api/get` con la firma que usan los reproductores.
Uri lrclibGetUri(LyricIdentity id) {
  return Uri.https('lrclib.net', '/api/get', {
    'artist_name': id.artist,
    'track_name': id.title,
    'album_name': id.album,
    'duration': '${id.durationSec}',
  });
}

/// `GET /api/search` solo con artista y título. El filtro lo hace el matcher.
Uri lrclibSearchUri(LyricIdentity id) {
  return Uri.https('lrclib.net', '/api/search', {
    'artist_name': id.artist,
    'track_name': id.title,
  });
}

final RegExp _lrcStamp = RegExp(r'\[(\d{1,3}):(\d{2})\.(\d{2,3})\]');

int? lastLrcStampMs(String lrc) {
  int? last;
  for (final Match m in _lrcStamp.allMatches(lrc)) {
    final int min = int.parse(m.group(1)!);
    final int sec = int.parse(m.group(2)!);
    int ms = int.parse(m.group(3)!);
    if (m.group(3)!.length == 2) ms *= 10;
    last = (min * 60000) + (sec * 1000) + ms;
  }
  return last;
}

/// La última línea es ≤ la duración y queda a ≤ ~20 s del final.
bool lrcEndsWithAudio(String lrc, int durationSec) {
  final int? last = lastLrcStampMs(lrc);
  if (last == null || durationSec <= 0) return false;
  final int durMs = durationSec * 1000;
  if (last > durMs) return false;
  return durMs - last <= kLyricEndSlackMs;
}

bool lyricDurationClose(int apiSec, int localSec) {
  if (apiSec <= 0 || localSec <= 0) return false;
  return (apiSec - localSec).abs() <= kLyricDurationTolSec;
}

/// Un `.lrc` que ya existe no se vuelve a bajar.
bool lyricMayDownload({required bool lrcExists}) => !lrcExists;

/// Elige como mucho un resultado. Artista y título normalizados tienen que
/// ser iguales y la duración caer en ±2 s. La sincronizada, además, tiene
/// que terminar con el audio. Un remix o extended sin esa edición no se
/// lleva la sincronizada de otra: como mucho la plana, sin tiempos.
LyricChoice chooseLrclibLyric(
  LyricIdentity id, {
  Map<String, dynamic>? direct,
  List<dynamic> searched = const [],
}) {
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
  if (direct != null) rows.add(direct);
  for (final dynamic raw in searched) {
    if (raw is Map) rows.add(Map<String, dynamic>.from(raw));
  }

  Map<String, dynamic>? synced;
  Map<String, dynamic>? plainSame;
  Map<String, dynamic>? plainRemix;
  for (final Map<String, dynamic> raw in rows) {
    final String apiArtist = raw['artistName']?.toString() ?? '';
    final String apiTitle = raw['trackName']?.toString() ?? '';
    if (!lyricNamesEqual(id.artist, apiArtist)) continue;
    if (!lyricNamesEqual(id.title, apiTitle)) continue;
    final int apiDur = (raw['duration'] as num?)?.round() ?? 0;
    final bool durOk = lyricDurationClose(apiDur, id.durationSec);
    final String syncedText = raw['syncedLyrics']?.toString() ?? '';
    final String plainText = raw['plainLyrics']?.toString() ?? '';
    if (durOk &&
        syncedText.trim().isNotEmpty &&
        lrcEndsWithAudio(syncedText, id.durationSec) &&
        synced == null) {
      synced = raw;
    }
    if (durOk && plainText.trim().isNotEmpty && plainSame == null) {
      plainSame = raw;
    }
    if (id.remixOrExtended &&
        plainText.trim().isNotEmpty &&
        plainRemix == null) {
      plainRemix = raw;
    }
  }

  if (synced != null) {
    return LyricChoice(
      kind: LyricKind.synced,
      body: synced['syncedLyrics'].toString(),
    );
  }
  final Map<String, dynamic>? plain = plainSame ?? plainRemix;
  if (plain != null) {
    return LyricChoice(
      kind: LyricKind.plain,
      body: plain['plainLyrics'].toString(),
    );
  }
  return const LyricChoice.none();
}
