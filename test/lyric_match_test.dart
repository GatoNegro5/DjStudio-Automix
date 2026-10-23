import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/core/id3_names.dart';
import 'package:gatomix/core/lyric_match.dart';

void main() {
  test('ID3 manda y el nombre de archivo solo rellena lo que falta', () {
    final LyricIdentity diana = lyricIdentity(
      path: r'C:\music\Diana Ross.mp3',
      id3Artist: 'Diana Ross',
      id3Title: 'Upside Down',
      id3Album: 'diana',
      durationSec: 254,
    );
    expect(diana.artist, 'Diana Ross');
    expect(diana.title, 'Upside Down');
    expect(diana.album, 'diana');
    expect(diana.remixOrExtended, isFalse);

    final LyricIdentity soloNombre = lyricIdentity(
      path: 'Diana Ross.mp3',
      durationSec: 254,
    );
    expect(soloNombre.title, 'Diana Ross');
    expect(soloNombre.artist, isEmpty);

    final LyricIdentity toma = lyricIdentity(
      path: '85 Bpm - a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    expect(toma.artist, 'a-ha');
    expect(toma.title, 'Take On Me');

    final Uri get = lrclibGetUri(diana);
    expect(get.path, '/api/get');
    expect(get.queryParameters['artist_name'], 'Diana Ross');
    expect(get.queryParameters['track_name'], 'Upside Down');
    expect(get.queryParameters['album_name'], 'diana');
    expect(get.queryParameters['duration'], '254');
    expect(lrclibSearchUri(diana).queryParameters.containsKey('q'), isFalse);
  });

  test('TALB se lee junto con el título y el artista', () {
    final Id3Names names = parseId3Names(
      _id3v23(title: 'Upside Down', artist: 'Diana Ross', album: 'diana'),
    );
    expect(names.title, 'Upside Down');
    expect(names.artist, 'Diana Ross');
    expect(names.album, 'diana');
  });

  test('Diana Ross no se queda con Thank You', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Diana Ross.mp3',
      id3Artist: 'Diana Ross',
      id3Title: 'Upside Down',
      id3Album: 'diana',
      durationSec: 254,
    );
    final LyricChoice soloMal = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Diana Ross',
        title: 'Thank You',
        duration: 254,
        synced: _lrc(<(int, String)>[(11, 'Thank You'), (219, 'Thank You')]),
      )],
    );
    expect(soloMal.kind, LyricKind.none);

    final LyricChoice conLaBuena = chooseLrclibLyric(
      id,
      searched: [
        _hit(
          artist: 'Diana Ross',
          title: 'Thank You',
          duration: 254,
          synced: _lrc(<(int, String)>[(11, 'Thank You'), (219, 'Thank You')]),
        ),
        _hit(
          artist: 'Diana Ross',
          title: 'Upside Down',
          duration: 254,
          synced: _lrc(<(int, String)>[(17, 'Upside Down'), (240, 'Upside Down')]),
        ),
      ],
    );
    expect(conLaBuena.kind, LyricKind.synced);
    expect(conLaBuena.body, contains('Upside Down'));
    expect(conLaBuena.body, isNot(contains('Thank You')));
  });

  test('Samantha Fox no se queda con Forever', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Samantha Fox.mp3',
      id3Artist: 'Samantha Fox',
      id3Title: 'Touch Me',
      durationSec: 226,
    );
    final String forever = _stamp(30, 'Forever') + _stamp(263, 'Forever');
    final LyricChoice mal = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Samantha Fox',
        title: 'Forever feat Samantha Fox',
        duration: 263,
        synced: forever,
      )],
    );
    expect(mal.kind, LyricKind.none);
    expect(mal.body, isNot(contains('Forever')));

    final LyricChoice bien = chooseLrclibLyric(
      id,
      searched: [
        _hit(
          artist: 'Samantha Fox',
          title: 'Forever feat Samantha Fox',
          duration: 263,
          synced: forever,
        ),
        _hit(
          artist: 'Samantha Fox',
          title: 'Touch Me (I Want Your Body)',
          duration: 226,
          synced: _lrc(<(int, String)>[(2, 'Touch Me'), (220, 'Touch Me')]),
        ),
      ],
    );
    expect(bien.kind, LyricKind.synced);
    expect(bien.body, contains('Touch Me'));
    expect(bien.fileText, isNot(contains('Forever')));
  });

  test('el remix de Blondie no hereda la edición de radio', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Blondie - Call Me (Remix).mp3',
      durationSec: 469,
    );
    expect(id.remixOrExtended, isTrue);
    expect(id.title, 'Call Me (Remix)');
    final String radio = _stamp(15, 'Call me') + _stamp(206, 'RADIO');
    final LyricChoice soloRadio = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Blondie',
        title: 'Call Me',
        duration: 208,
        synced: radio,
        plain: 'Call me on the line',
      )],
    );
    expect(soloRadio.kind, isNot(LyricKind.synced));
    expect(soloRadio.fileText, isNot(contains('RADIO')));
    expect(soloRadio.fileText, isNot(contains('[03:')));
    expect(soloRadio.kind, LyricKind.plain);

    final LyricChoice sinPlana = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Blondie',
        title: 'Call Me',
        duration: 208,
        synced: radio,
      )],
    );
    expect(sinPlana.kind, LyricKind.none);
  });

  test('Glenn no hereda la edición de radio', () {
    final LyricIdentity id = lyricIdentity(
      path: 'Glenn Frey - The Heat Is On.mp3',
      durationSec: 363,
    );
    expect(id.remixOrExtended, isFalse);
    final String radio = _stamp(21, 'The heat') + _stamp(220, 'RADIO');
    final LyricChoice honesta = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Glenn Frey',
        title: 'The Heat Is On',
        duration: 220,
        synced: radio,
        plain: 'The heat is on',
      )],
    );
    expect(honesta.kind, LyricKind.none);

    final LyricChoice duracionMiente = chooseLrclibLyric(
      id,
      searched: [_hit(
        artist: 'Glenn Frey',
        title: 'The Heat Is On',
        duration: 363,
        synced: radio,
      )],
    );
    expect(duracionMiente.kind, LyricKind.none);
    expect(duracionMiente.body, isNot(contains('RADIO')));
  });

  test('Hello y Take On Me coinciden', () {
    final LyricIdentity hello = lyricIdentity(
      path: 'Lionel Richie - Hello.mp3',
      durationSec: 242,
    );
    final LyricChoice helloHit = chooseLrclibLyric(
      hello,
      direct: _hit(
        artist: 'Lionel Richie',
        title: 'Hello',
        album: 'Can\'t Slow Down',
        duration: 242,
        synced: _stamp(16, 'Hello') + _stamp(224, 'Hello'),
      ),
    );
    expect(helloHit.kind, LyricKind.synced);
    expect(helloHit.body, contains('Hello'));

    final LyricIdentity toma = lyricIdentity(
      path: 'a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    final LyricChoice tomaHit = chooseLrclibLyric(
      toma,
      searched: [_hit(
        artist: 'a-ha',
        title: 'Take On Me',
        duration: 223,
        synced: _stamp(34, 'Take on me') + _stamp(220, 'Take on me'),
      )],
    );
    expect(tomaHit.kind, LyricKind.synced);
    expect(tomaHit.body, contains('Take on me'));
  });

  test('duración ±2 s y la última línea a ≤ 20 s del final', () {
    final LyricIdentity id = lyricIdentity(
      path: 'a-ha - Take On Me.mp3',
      durationSec: 223,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 225,
          synced: _stamp(30, 'a') + _stamp(221, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 226,
          synced: _stamp(30, 'a') + _stamp(221, 'b'),
        ),
      ).kind,
      LyricKind.none,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 223,
          synced: _stamp(30, 'a') + _stamp(203, 'b'),
        ),
      ).kind,
      LyricKind.synced,
    );
    expect(
      chooseLrclibLyric(
        id,
        direct: _hit(
          artist: 'a-ha',
          title: 'Take On Me',
          duration: 223,
          synced: _stamp(30, 'a') + _stamp(202, 'b'),
        ),
      ).kind,
      LyricKind.none,
    );
    expect(
      lrcEndsWithAudio(_stamp(30, 'a') + _stamp(263, 'b'), 226),
      isFalse,
    );
  });

  test('un .lrc que ya existe no se vuelve a bajar', () {
    expect(lyricMayDownload(lrcExists: true), isFalse);
    expect(lyricMayDownload(lrcExists: false), isTrue);
  });
}

Map<String, dynamic> _hit({
  required String artist,
  required String title,
  required int duration,
  String synced = '',
  String plain = '',
  String album = '',
}) {
  return <String, dynamic>{
    'artistName': artist,
    'trackName': title,
    'albumName': album,
    'duration': duration,
    'syncedLyrics': synced,
    'plainLyrics': plain,
  };
}

String _stamp(int sec, String text) {
  final String m = (sec ~/ 60).toString().padLeft(2, '0');
  final String s = (sec % 60).toString().padLeft(2, '0');
  return '[$m:$s.00]$text\n';
}

String _lrc(List<(int, String)> lines) =>
    lines.map(((int, String) e) => _stamp(e.$1, e.$2)).join();

List<int> _syncsafe(int n) => <int>[
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
];

List<int> _frame(String id, String text) {
  final List<int> payload = <int>[0x03, ...text.codeUnits];
  final int size = payload.length;
  return <int>[
    ...id.codeUnits,
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    0,
    0,
    ...payload,
  ];
}

List<int> _id3v23({
  required String title,
  required String artist,
  required String album,
}) {
  final List<int> frames = <int>[
    ..._frame('TIT2', title),
    ..._frame('TPE1', artist),
    ..._frame('TALB', album),
  ];
  return <int>[
    0x49,
    0x44,
    0x33,
    0x03,
    0x00,
    0x00,
    ..._syncsafe(frames.length),
    ...frames,
  ];
}
