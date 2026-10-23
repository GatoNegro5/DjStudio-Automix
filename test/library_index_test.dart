import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gatomix/services/library/library_models.dart';
import 'package:gatomix/services/library/windows_music_folder.dart';
import 'package:gatomix/ui/library/library_review_screen.dart';

DiscoveredTrack _track(String path, {int modifiedMs = 10, int size = 100}) {
  return DiscoveredTrack.fromFile(
    path: path,
    modifiedMs: modifiedMs,
    size: size,
  );
}

void main() {
  test('agrupa por la carpeta que contiene el archivo', () {
    final List<DiscoveredFolder> folders = groupTracks(<DiscoveredTrack>[
      _track(r'C:\Music\Cumbia\a.mp3'),
      _track(r'C:\Music\Cumbia\b.mp3', size: 50),
      _track(r'C:\Music\Salsa\c.m4a'),
    ]);
    expect(folders, hasLength(2));
    expect(folders.map((DiscoveredFolder f) => f.label), ['Cumbia', 'Salsa']);
    expect(folders.first.trackCount, 2);
    expect(folders.last.trackCount, 1);
  });

  test('solo cuenta mp3 m4a wav y webm', () {
    expect(isLibraryAudio(r'C:\Music\a.mp3'), isTrue);
    expect(isLibraryAudio('/music/a.M4A'), isTrue);
    expect(isLibraryAudio('/music/a.wav'), isTrue);
    expect(isLibraryAudio('/music/a.webm'), isTrue);
    expect(isLibraryAudio('/music/a.lrc'), isFalse);
    expect(isLibraryAudio('/music/a.jpg'), isFalse);
    expect(isLibraryAudio('ipod-library://item/item.mp3?id=9'), isTrue);
  });

  test('rock2 no queda dentro de rock', () {
    expect(pathUnder(r'C:\Music\rock2\a.mp3', r'C:\Music\rock'), isFalse);
    expect(pathUnder(r'C:\Music\rock\a.mp3', r'C:\Music\rock'), isTrue);
    expect(
      pathUnder(
        '/storage/emulated/0/Music/rock/live/a.mp3',
        '/storage/emulated/0/Music/rock',
      ),
      isTrue,
    );
  });

  test('la carpeta de catálogo más larga gana', () {
    expect(
      catalogFolderFor('/music/rock/live/a.mp3', <String>[
        '/music/rock',
        '/music/rock/live',
      ]),
      '/music/rock/live',
    );
    expect(
      catalogFolderFor('/music/rock2/a.mp3', <String>['/music/rock']),
      isNull,
    );
  });

  test('el índice solo toca carpetas legibles y aceptadas', () {
    final Map<String, TrackStamp> previous = <String, TrackStamp>{
      '/music/a/old.mp3': const TrackStamp(
        modifiedMs: 1,
        size: 10,
        folder: '/music/a',
      ),
      '/music/a/same.mp3': const TrackStamp(
        modifiedMs: 5,
        size: 20,
        folder: '/music/a',
      ),
      '/music/b/keep.mp3': const TrackStamp(
        modifiedMs: 3,
        size: 30,
        folder: '/music/b',
      ),
    };
    final IndexDiff diff = diffIndex(
      previous: previous,
      current: <DiscoveredTrack>[
        _track('/music/a/same.mp3', modifiedMs: 5, size: 20),
        _track('/music/a/new.mp3', modifiedMs: 9, size: 40),
        _track('/music/a/grown.mp3', modifiedMs: 1, size: 10),
      ],
      acceptedFolders: <String>{'/music/a'},
    );
    expect(diff.removed, ['/music/a/old.mp3']);
    expect(diff.changed.map((DiscoveredTrack t) => t.path), [
      '/music/a/new.mp3',
      '/music/a/grown.mp3',
    ]);
    final Map<String, TrackStamp> next = applyIndexDiff(previous, diff);
    expect(next.containsKey('/music/b/keep.mp3'), isTrue);
    expect(next.containsKey('/music/a/old.mp3'), isFalse);
    expect(next['/music/a/new.mp3']?.size, 40);
    expect(next['/music/a/same.mp3']?.modifiedMs, 5);
  });

  test('un archivo igual no entra en el diff', () {
    final DiscoveredTrack track = _track(
      '/music/a/same.mp3',
      modifiedMs: 5,
      size: 20,
    );
    final IndexDiff diff = diffIndex(
      previous: <String, TrackStamp>{
        track.path: TrackStamp(
          modifiedMs: track.modifiedMs,
          size: track.size,
          folder: track.folder,
        ),
      },
      current: <DiscoveredTrack>[track],
      acceptedFolders: <String>{track.folder},
    );
    expect(diff.changed, isEmpty);
    expect(diff.removed, isEmpty);
  });

  test('cambiar el tamaño o la fecha sí cuenta', () {
    final IndexDiff diff = diffIndex(
      previous: <String, TrackStamp>{
        '/music/a/t.mp3': const TrackStamp(
          modifiedMs: 5,
          size: 20,
          folder: '/music/a',
        ),
      },
      current: <DiscoveredTrack>[
        _track('/music/a/t.mp3', modifiedMs: 6, size: 20),
      ],
      acceptedFolders: <String>{'/music/a'},
    );
    expect(diff.changed, hasLength(1));
    expect(diff.removed, isEmpty);
  });

  test('alta y baja de carpetas no arrastra a la vecina', () {
    final List<LibraryFolderRecord> added = foldersWithAdded(
      const <LibraryFolderRecord>[
        LibraryFolderRecord(path: '/music/rock', label: 'rock', accepted: true),
      ],
      const LibraryFolderRecord(
        path: '/music/rock2',
        label: 'rock2',
        accepted: true,
      ),
    );
    expect(added, hasLength(2));
    final List<LibraryFolderRecord> again = foldersWithAdded(
      added,
      const LibraryFolderRecord(
        path: '/music/rock2',
        label: 'rock2',
        accepted: true,
        bookmark: 'bm',
      ),
    );
    expect(again, hasLength(2));
    expect(
      again
          .firstWhere((LibraryFolderRecord f) => f.path == '/music/rock2')
          .bookmark,
      'bm',
    );
    final List<LibraryFolderRecord> removed = foldersWithout(
      again,
      '/music/rock',
    );
    expect(removed.map((LibraryFolderRecord f) => f.path), ['/music/rock2']);
    final Map<String, TrackStamp> index =
        indexWithoutFolder(<String, TrackStamp>{
          '/music/rock/a.mp3': const TrackStamp(
            modifiedMs: 1,
            size: 1,
            folder: '/music/rock',
          ),
          '/music/rock2/b.mp3': const TrackStamp(
            modifiedMs: 1,
            size: 1,
            folder: '/music/rock2',
          ),
        }, '/music/rock');
    expect(index.keys, ['/music/rock2/b.mp3']);
  });

  test('la foto persiste reviewed, carpetas e índice', () {
    const LibrarySnapshot snapshot = LibrarySnapshot(
      reviewed: true,
      folders: <LibraryFolderRecord>[
        LibraryFolderRecord(
          path: '/music/a',
          label: 'a',
          accepted: true,
          bookmark: 'abc',
        ),
        LibraryFolderRecord(path: '/music/b', label: 'b', accepted: false),
      ],
      index: <String, TrackStamp>{
        '/music/a/t.mp3': TrackStamp(
          modifiedMs: 4,
          size: 8,
          folder: '/music/a',
        ),
      },
    );
    final LibrarySnapshot restored = LibrarySnapshot.fromJson(
      snapshot.toJson(),
    );
    expect(restored.reviewed, isTrue);
    expect(restored.accepted, hasLength(1));
    expect(restored.accepted.single.bookmark, 'abc');
    expect(restored.index['/music/a/t.mp3']?.size, 8);
    expect(LibrarySnapshot.fromJson('no').reviewed, isFalse);
  });

  test('la carpeta Música de Windows no se consulta fuera de Windows', () {
    expect(windowsKnownMusicFolder(), isNull);
    expect(legacyWindowsMusicFolder(), endsWith('Music'));
  });

  testWidgets('la revisión cabe en el celular apaisado', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryReviewScreen(
          folders: <DiscoveredFolder>[
            for (int i = 0; i < 12; i++)
              DiscoveredFolder(
                path: '/music/carpeta$i',
                label: 'Carpeta $i con un nombre largo de género',
                trackCount: i + 1,
              ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('LISTO'), findsOneWidget);
    expect(find.text('1 pista'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('12 pistas'), 80);
    await tester.pump();
    expect(find.text('12 pistas'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
