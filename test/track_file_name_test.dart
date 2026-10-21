import 'package:djstudio_player/core/id3_names.dart';
import 'package:djstudio_player/core/track_file_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('112 - Artista - Título ignora el BPM', () {
    final TrackFileName n = parseTrackFileName(
      r'C:\music\112 - Earth, Wind & Fire, Indeep - September.mp3',
    );
    expect(n.artist, 'Earth, Wind & Fire, Indeep');
    expect(n.title, 'September');
    final TrackDisplay d = resolveTrackDisplay(file: n);
    expect(d.headline, 'Earth, Wind & Fire, Indeep');
    expect(d.subtitle, 'September');
    expect(d.subtitle, isNot('112'));
  });

  test('Artista - Título', () {
    final TrackDisplay d = resolveTrackDisplay(
      file: parseTrackFileName('Dj Bobo - Chihuahua.mp3'),
    );
    expect(d.headline, 'Dj Bobo');
    expect(d.subtitle, 'Chihuahua');
  });

  test('112 - Título no muestra el prefijo', () {
    final TrackFileName n = parseTrackFileName('100 - Chihuahua.m4a');
    expect(n.artist, isEmpty);
    expect(n.title, 'Chihuahua');
    expect(n.bpmSingle, isTrue);
    final TrackDisplay d = resolveTrackDisplay(file: n);
    expect(d.headline, 'Chihuahua');
    expect(d.subtitle, isEmpty);
  });

  test('un número fuera de 40–250 no es BPM', () {
    final TrackDisplay d = resolveTrackDisplay(
      file: parseTrackFileName('1979 - The Smashing Pumpkins - 1979.mp3'),
    );
    expect(d.headline, '1979');
    expect(d.subtitle, 'The Smashing Pumpkins - 1979');
  });

  test('sin separador el nombre entero es el título', () {
    final TrackDisplay d = resolveTrackDisplay(
      file: parseTrackFileName('White Wedding.mp3'),
    );
    expect(d.artist, isEmpty);
    expect(d.headline, 'White Wedding');
    expect(d.subtitle, isEmpty);
  });

  test('TIT2 y TPE1 pisan al nombre de archivo', () {
    final TrackDisplay d = resolveTrackDisplay(
      file: parseTrackFileName(
        '112 - Earth, Wind & Fire, Indeep - September.mp3',
      ),
      id3Artist: 'Earth, Wind & Fire',
      id3Title: "Let's Groove",
    );
    expect(d.headline, 'Earth, Wind & Fire');
    expect(d.subtitle, "Let's Groove");
    expect(d.artist, 'Earth, Wind & Fire');
  });

  test(
    'BPM - Nombre con solo TIT2 deja el nombre arriba y el título abajo',
    () {
      final TrackDisplay d = resolveTrackDisplay(
        file: parseTrackFileName('112 - Earth, Wind & Fire, Indeep.mp3'),
        id3Title: 'September',
      );
      expect(d.headline, 'Earth, Wind & Fire, Indeep');
      expect(d.subtitle, 'September');
      expect(d.subtitle, isNot('112'));
    },
  );

  test('ID3v2 TIT2 y TPE1 se leen del bloque', () {
    final List<int> tag = _id3v23(
      title: "Let's Groove",
      artist: 'Earth, Wind & Fire',
    );
    final Id3Names names = parseId3Names(tag);
    expect(names.title, "Let's Groove");
    expect(names.artist, 'Earth, Wind & Fire');
  });

  test('ID3v2.2 TT2 y TP1 equivalen a título y artista', () {
    final Id3Names names = parseId3Names(
      _id3v22(title: 'Chihuahua', artist: 'Dj Bobo'),
    );
    expect(names.title, 'Chihuahua');
    expect(names.artist, 'Dj Bobo');
  });

  test('bytes que no son ID3 no inventan un título', () {
    final Id3Names names = parseId3Names(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(names.title, isEmpty);
    expect(names.artist, isEmpty);
  });
}

List<int> _syncsafe(int n) => <int>[
  (n >> 21) & 0x7f,
  (n >> 14) & 0x7f,
  (n >> 7) & 0x7f,
  n & 0x7f,
];

List<int> _frameV23(String id, String text) {
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

List<int> _id3v23({required String title, required String artist}) {
  final List<int> frames = <int>[
    ..._frameV23('TIT2', title),
    ..._frameV23('TPE1', artist),
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

List<int> _frameV22(String id, String text) {
  final List<int> payload = <int>[0x00, ...text.codeUnits];
  final int size = payload.length;
  return <int>[
    ...id.codeUnits,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...payload,
  ];
}

List<int> _id3v22({required String title, required String artist}) {
  final List<int> frames = <int>[
    ..._frameV22('TT2', title),
    ..._frameV22('TP1', artist),
  ];
  return <int>[
    0x49,
    0x44,
    0x33,
    0x02,
    0x00,
    0x00,
    ..._syncsafe(frames.length),
    ...frames,
  ];
}
