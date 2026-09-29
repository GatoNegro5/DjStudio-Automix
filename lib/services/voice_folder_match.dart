import 'dart:io';

/// Carpeta visible en el explorador de Music (profundidad 0..2, igual que
/// `LibraryTreePanel`).
class FolderCandidate {
  final String path;
  final String name;
  final int depth;

  const FolderCandidate({
    required this.path,
    required this.name,
    required this.depth,
  });
}

enum VoiceMiss { unheard, noMatch, ambiguous }

class VoiceDecision {
  final FolderCandidate? folder;
  final VoiceMiss? miss;

  const VoiceDecision.play(FolderCandidate this.folder) : miss = null;

  const VoiceDecision.miss(VoiceMiss this.miss) : folder = null;

  bool get plays => folder != null;
}

const Set<String> _functionWords = {
  'la',
  'el',
  'los',
  'las',
  'un',
  'una',
  'unos',
  'unas',
  'de',
  'del',
  'y',
  'e',
  'o',
  'u',
  'en',
  'al',
  'lo',
  'me',
  'te',
  'se',
  'por',
  'para',
  'con',
  'que',
};

const List<String> libraryAudioExtensions = ['.mp3', '.webm', '.m4a', '.wav'];

/// Misma raíz que `LibraryTreePanel._initializeRoot`.
String musicLibraryRoot() {
  if (Platform.isWindows) {
    final userProfile = Platform.environment['USERPROFILE'];
    return userProfile != null ? '$userProfile\\Music' : r'C:\Music';
  }
  if (Platform.isAndroid) {
    return '/storage/emulated/0/Music';
  }
  if (Platform.isMacOS || Platform.isLinux) {
    final home = Platform.environment['HOME'];
    return home != null ? '$home/Music' : '/';
  }
  return '/';
}

String normalizeSpoken(String input) {
  final folded = StringBuffer();
  for (final rune in input.toLowerCase().trim().runes) {
    folded.write(_foldRune(rune));
  }
  return folded
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9\s]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _foldRune(int rune) {
  const fold = {
    0x00E1: 'a',
    0x00E0: 'a',
    0x00E4: 'a',
    0x00E2: 'a',
    0x00E9: 'e',
    0x00E8: 'e',
    0x00EB: 'e',
    0x00EA: 'e',
    0x00ED: 'i',
    0x00EC: 'i',
    0x00EF: 'i',
    0x00EE: 'i',
    0x00F3: 'o',
    0x00F2: 'o',
    0x00F6: 'o',
    0x00F4: 'o',
    0x00FA: 'u',
    0x00F9: 'u',
    0x00FC: 'u',
    0x00FB: 'u',
    0x00F1: 'n',
  };
  return fold[rune] ?? String.fromCharCode(rune);
}

int _maxEdit(int length) {
  if (length <= 3) return 0;
  if (length <= 6) return 1;
  return 2;
}

int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final prev = List<int>.generate(b.length + 1, (i) => i);
  final curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    final ac = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ac == b.codeUnitAt(j - 1) ? 0 : 1;
      final insert = curr[j - 1] + 1;
      final delete = prev[j] + 1;
      final replace = prev[j - 1] + cost;
      var best = insert < delete ? insert : delete;
      if (replace < best) best = replace;
      curr[j] = best;
    }
    for (var j = 0; j < prev.length; j++) {
      prev[j] = curr[j];
    }
  }
  return prev[b.length];
}

class _Hit {
  final FolderCandidate folder;
  final int distance;
  final int rank;

  const _Hit(this.folder, this.distance, this.rank);
}

/// Una frase, un folder. Empate entre nombres distintos = no hay match.
VoiceDecision decideSpokenFolder(List<FolderCandidate> folders, String heard) {
  final phrase = normalizeSpoken(heard);
  if (phrase.isEmpty) {
    return const VoiceDecision.miss(VoiceMiss.unheard);
  }

  final tokens = phrase
      .split(' ')
      .where((token) => token.length >= 2 && !_functionWords.contains(token))
      .toList();

  final hits = <_Hit>[];
  for (final folder in folders) {
    final name = normalizeSpoken(folder.name);
    if (name.isEmpty) continue;
    final cap = _maxEdit(name.length);
    if (phrase == name) {
      hits.add(_Hit(folder, 0, 0));
      continue;
    }

    var bestDist = 1 << 30;
    var bestRank = 99;
    if (tokens.contains(name)) {
      bestDist = 0;
      bestRank = 1;
    }

    final phraseDist = levenshtein(phrase, name);
    if (phraseDist <= cap && phraseDist < bestDist) {
      bestDist = phraseDist;
      bestRank = 2;
    }

    for (final token in tokens) {
      if (token == name) continue;
      final tokenDist = levenshtein(token, name);
      if (tokenDist <= cap && tokenDist < bestDist) {
        bestDist = tokenDist;
        bestRank = 3;
      }
    }

    if (bestRank < 99) {
      hits.add(_Hit(folder, bestDist, bestRank));
    }
  }

  if (hits.isEmpty) {
    return const VoiceDecision.miss(VoiceMiss.noMatch);
  }

  hits.sort((a, b) {
    final byDist = a.distance.compareTo(b.distance);
    if (byDist != 0) return byDist;
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    final byDepth = a.folder.depth.compareTo(b.folder.depth);
    if (byDepth != 0) return byDepth;
    return a.folder.path.compareTo(b.folder.path);
  });

  final best = hits.first;
  final rivals = hits
      .where((hit) => hit.distance == best.distance && hit.rank == best.rank)
      .toList();
  if (rivals.length == 1) {
    return VoiceDecision.play(best.folder);
  }

  final names = rivals.map((hit) => normalizeSpoken(hit.folder.name)).toSet();
  if (names.length > 1) {
    return const VoiceDecision.miss(VoiceMiss.ambiguous);
  }

  rivals.sort((a, b) {
    final byDepth = a.folder.depth.compareTo(b.folder.depth);
    if (byDepth != 0) return byDepth;
    return a.folder.path.compareTo(b.folder.path);
  });
  return VoiceDecision.play(rivals.first.folder);
}

String folderBaseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty);
  if (parts.isEmpty) return path;
  return parts.last;
}

/// Carpetas que el explorador puede mostrar bajo [root]. No bloquea con
/// `listSync`: el listado es el stream de `Directory.list`.
Future<List<FolderCandidate>> listLibraryFolders(String root) async {
  final rootDir = Directory(root);
  if (!await rootDir.exists()) return const [];
  final out = <FolderCandidate>[];
  await _walkFolders(rootDir, 0, out);
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

Future<void> _walkFolders(
  Directory dir,
  int depth,
  List<FolderCandidate> out,
) async {
  if (depth > 2) return;
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = folderBaseName(entity.path);
      if (name.startsWith('.')) continue;
      out.add(FolderCandidate(path: entity.path, name: name, depth: depth));
      await _walkFolders(entity, depth + 1, out);
    }
  } catch (_) {}
}

/// Mismas extensiones que `DirectoryNotifier.scanPath`.
Future<List<File>> listLibraryAudio(String directoryPath) async {
  final dir = Directory(directoryPath);
  if (!await dir.exists()) return const [];
  final files = <File>[];
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      final isAudio = libraryAudioExtensions.any(lower.endsWith);
      if (isAudio) files.add(entity);
    }
  } catch (_) {}
  files.sort(
    (a, b) => folderBaseName(
      a.path,
    ).toLowerCase().compareTo(folderBaseName(b.path).toLowerCase()),
  );
  return files;
}
