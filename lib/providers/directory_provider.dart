import 'dart:io';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

class DirectoryState {
  final String currentPath;
  final List<File> files;
  final bool isProcessing;
  final Set<String> expandedPaths; // 🛠️ NUEVO: Memoria visual del árbol

  DirectoryState({
    this.currentPath = '',
    this.files = const [],
    this.isProcessing = false,
    this.expandedPaths = const {},
  });

  DirectoryState copyWith({
    String? currentPath,
    List<File>? files,
    bool? isProcessing,
    Set<String>? expandedPaths,
  }) {
    return DirectoryState(
      currentPath: currentPath ?? this.currentPath,
      files: files ?? this.files,
      isProcessing: isProcessing ?? this.isProcessing,
      expandedPaths: expandedPaths ?? this.expandedPaths,
    );
  }
}

class DirectoryNotifier extends Notifier<DirectoryState> {
  @override
  DirectoryState build() {
    _initPersistence();
    return DirectoryState();
  }

  String _getSessionFilePath() {
    String baseDir = Platform.isWindows
        ? '${Platform.environment['USERPROFILE']}\\Music\\DjPlaylists'
        : '/storage/emulated/0/Music/DjPlaylists';
    final dir = Directory(baseDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}${Platform.pathSeparator}_explorer_session.json';
  }

  // 🛠️ LECTURA ATÓMICA: Recupera ruta y nodos expandidos
  Future<void> _initPersistence() async {
    try {
      final file = File(_getSessionFilePath());
      if (file.existsSync()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);

        final lastDir = data['currentPath'] as String?;
        final savedExpanded =
            (data['expandedPaths'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toSet() ??
            {};

        state = state.copyWith(expandedPaths: savedExpanded);

        if (lastDir != null && Directory(lastDir).existsSync()) {
          await scanPath(lastDir);
        }
      }
    } catch (_) {}
  }

  // 🛠️ ESCRITURA ATÓMICA: Consolida el estado total del explorador
  Future<void> _saveSnapshot() async {
    try {
      final file = File(_getSessionFilePath());
      final data = {
        'currentPath': state.currentPath,
        'expandedPaths': state.expandedPaths.toList(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  // 🛠️ CONTROL DE UI: Alterna y guarda el estado del árbol
  void toggleNode(String path, bool isExpanded) {
    final newExpanded = Set<String>.from(state.expandedPaths);
    if (isExpanded) {
      newExpanded.add(path);
    } else {
      newExpanded.remove(path);
    }
    state = state.copyWith(expandedPaths: newExpanded);
    _saveSnapshot();
  }

  Future<void> loadDirectory() async {
    if (state.isProcessing) return;
    final String? selectedDirectory = await getDirectoryPath();
    if (selectedDirectory != null) {
      await scanPath(selectedDirectory);
    }
  }

  Future<void> refreshCurrentPath() async {
    if (state.currentPath.isNotEmpty) {
      await scanPath(state.currentPath);
    }
  }

  Future<void> scanPath(String path) async {
    state = state.copyWith(isProcessing: true, currentPath: path);
    await _saveSnapshot(); // Guarda ruta seleccionada inmediatamente

    try {
      final dir = Directory(path);
      final List<File> targetFiles = [];
      final Set<String> validAudioBases = {};
      final List<File> lrcFiles = [];

      final stream = dir.list(recursive: true, followLinks: false).handleError((
        e,
      ) {
        debugPrint("⚠️ [I/O Ignorado en Scoped Storage]: $e");
      });

      await for (final entity in stream) {
        if (entity is File) {
          final lowerPath = entity.path.toLowerCase();
          if (lowerPath.endsWith('.mp3') ||
              lowerPath.endsWith('.webm') ||
              lowerPath.endsWith('.m4a') ||
              lowerPath.endsWith('.wav')) {
            targetFiles.add(entity);
            validAudioBases.add(
              entity.path.replaceAll(
                RegExp(r'\.mp3$|\.webm$|\.m4a$|\.wav$', caseSensitive: false),
                '',
              ),
            );
          } else if (lowerPath.endsWith('.lrc')) {
            lrcFiles.add(entity);
          }
        }
      }

      for (final lrc in lrcFiles) {
        final baseName = lrc.path.replaceAll(
          RegExp(r'\.lrc$', caseSensitive: false),
          '',
        );
        if (!validAudioBases.contains(baseName)) {
          try {
            await lrc.delete();
          } catch (_) {}
        }
      }

      targetFiles.sort(
        (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
      );
      state = state.copyWith(files: targetFiles, isProcessing: false);
    } catch (e) {
      debugPrint("🔴 [SCAN FATAL ERROR]: $e");
      state = state.copyWith(isProcessing: false, files: []);
    }
  }
}

final directoryProvider = NotifierProvider<DirectoryNotifier, DirectoryState>(
  DirectoryNotifier.new,
);
