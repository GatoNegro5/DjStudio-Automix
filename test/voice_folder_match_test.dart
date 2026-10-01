import 'dart:io';

import 'package:djstudio_player/services/voice_folder_match.dart';
import 'package:flutter_test/flutter_test.dart';

FolderCandidate _folder(String name, {int depth = 0, String? path}) {
  return FolderCandidate(
    path: path ?? '/storage/emulated/0/Music/$name',
    name: name,
    depth: depth,
  );
}

void main() {
  test('exact folder ignores case and accents', () {
    final folders = [_folder('Salsa'), _folder('Balada')];
    final decision = decideSpokenFolder(folders, 'SALSA');
    expect(decision.plays, isTrue);
    expect(decision.folder!.name, 'Salsa');

    final accented = decideSpokenFolder([
      _folder('Merengue'),
      _folder('Salsa Romántica'),
    ], 'salsa romantica');
    expect(accented.folder!.name, 'Salsa Romántica');
  });

  test('one-edit mishear maps to the only close folder', () {
    final decision = decideSpokenFolder([
      _folder('Salsa'),
      _folder('Balada'),
      _folder('Rock'),
    ], 'sarsa');
    expect(decision.plays, isTrue);
    expect(decision.folder!.name, 'Salsa');
  });

  test('a distant phrase does not select another genre', () {
    final decision = decideSpokenFolder([
      _folder('Salsa'),
      _folder('Merengue'),
      _folder('Cumbia'),
    ], 'balada');
    expect(decision.plays, isFalse);
    expect(decision.miss, VoiceMiss.noMatch);
  });

  test('a tie between different names does not play', () {
    final decision = decideSpokenFolder([
      _folder('House'),
      _folder('Mouse'),
    ], 'rouse');
    expect(decision.plays, isFalse);
    expect(decision.miss, VoiceMiss.ambiguous);
  });

  test('a leading article still hits the genre token', () {
    final decision = decideSpokenFolder([
      _folder('Salsa'),
      _folder('Rock'),
    ], 'la salsa');
    expect(decision.folder!.name, 'Salsa');
  });

  test('silence is not a folder', () {
    final decision = decideSpokenFolder([_folder('Salsa')], '   ...  ');
    expect(decision.miss, VoiceMiss.unheard);
  });

  test('two identical names keep the shallower folder', () {
    final decision = decideSpokenFolder([
      _folder('Salsa', depth: 2, path: '/Music/Tropical/Salsa'),
      _folder('Salsa', depth: 0, path: '/Music/Salsa'),
    ], 'salsa');
    expect(decision.folder!.path, '/Music/Salsa');
  });

  test('library walk stops at explorer depth and skips dot dirs', () async {
    final root = await Directory.systemTemp.createTemp('djstudio_voice_');
    try {
      await Directory('${root.path}/Salsa').create(recursive: true);
      await Directory('${root.path}/Tropical/Cumbia').create(recursive: true);
      await Directory(
        '${root.path}/Tropical/Cumbia/Nieto/Bisnieto',
      ).create(recursive: true);
      await Directory('${root.path}/.priv').create(recursive: true);
      await File('${root.path}/Salsa/a.mp3').create();
      await File('${root.path}/Salsa/note.txt').create();
      await File('${root.path}/Salsa/b.wav').create();

      final folders = await listLibraryFolders(root.path);
      final names = folders.map((folder) => folder.name).toList();
      expect(names, containsAll(['Salsa', 'Tropical', 'Cumbia', 'Nieto']));
      expect(names, isNot(contains('Bisnieto')));
      expect(names, isNot(contains('.priv')));

      final audio = await listLibraryAudio('${root.path}/Salsa');
      expect(
        audio.map((file) => folderBaseName(file.path)).toList(),
        ['a.mp3', 'b.wav'],
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
