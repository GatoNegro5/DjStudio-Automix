import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/player_provider.dart';

class LabWorkspace extends ConsumerStatefulWidget {
  const LabWorkspace({super.key});

  @override
  ConsumerState<LabWorkspace> createState() => _LabWorkspaceState();
}

class _LabWorkspaceState extends ConsumerState<LabWorkspace> {
  String _labPath = '';
  Map<String, dynamic> _registry = {};
  bool _isLoading = true;

  // Controladores del Editor LRC y Búsqueda
  String? _selectedFileForEdit;
  final TextEditingController _lrcController = TextEditingController();
  final TextEditingController _searchQueryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initLabEnvironment();
  }

  @override
  void dispose() {
    _lrcController.dispose();
    _searchQueryController.dispose();
    super.dispose();
  }

  void _initLabEnvironment() {
    String baseMusicPath = '';
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      baseMusicPath = userProfile != null ? '$userProfile\\Music' : 'C:\\Music';
    } else if (Platform.isMacOS || Platform.isLinux) {
      baseMusicPath = '${Platform.environment['HOME']}/Music';
    } else {
      baseMusicPath = '/storage/emulated/0/Music';
    }

    final labDir = Directory(
      '$baseMusicPath${Platform.pathSeparator}DjStudio_LAB',
    );
    if (!labDir.existsSync()) {
      labDir.createSync(recursive: true);
    }

    _labPath = labDir.path;
    _loadRegistry();
  }

  void _loadRegistry() {
    final registryFile = File(
      '$_labPath${Platform.pathSeparator}quarantine_registry.json',
    );
    if (registryFile.existsSync()) {
      try {
        _registry = jsonDecode(registryFile.readAsStringSync());
      } catch (_) {
        _registry = {};
      }
    } else {
      _registry = {};
    }

    final labDir = Directory(_labPath);
    final physicalFiles = labDir
        .listSync()
        .whereType<File>()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    _registry.removeWhere((key, value) => !physicalFiles.contains(key));

    if (registryFile.existsSync()) {
      registryFile.writeAsStringSync(jsonEncode(_registry));
    }

    setState(() => _isLoading = false);
  }

  void _loadLrcForEdit(String fileName) {
    final lrcFile = File(
      '$_labPath${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
    );
    if (lrcFile.existsSync()) {
      _lrcController.text = lrcFile.readAsStringSync();
    } else {
      _lrcController.text = "";
    }

    _searchQueryController.text = fileName
        .replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '')
        .trim();

    setState(() {
      _selectedFileForEdit = fileName;
    });
  }

  void _saveLrc() {
    if (_selectedFileForEdit == null) return;
    final lrcFile = File(
      '$_labPath${Platform.pathSeparator}${_selectedFileForEdit!.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
    );
    lrcFile.writeAsStringSync(_lrcController.text);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("✅ Letra sincronizada (.lrc) guardada en disco."),
        backgroundColor: Color(0xFF39FF14),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _restoreFile(String fileName, String originalPath) async {
    try {
      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) {
        final targetDir = Directory(File(originalPath).parent.path);
        if (!targetDir.existsSync()) targetDir.createSync(recursive: true);

        file.renameSync(originalPath); // Restauración física atómica

        final lrcFile = File(
          '$_labPath${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
        );
        if (lrcFile.existsSync()) {
          final originalLrcPath = originalPath.replaceAll(
            RegExp(r'\.mp3$|\.webm$', caseSensitive: false),
            '.lrc',
          );
          lrcFile.renameSync(originalLrcPath);
        }

        _registry.remove(fileName);
        final registryFile = File(
          '$_labPath${Platform.pathSeparator}quarantine_registry.json',
        );
        registryFile.writeAsStringSync(jsonEncode(_registry));

        if (_selectedFileForEdit == fileName) {
          _selectedFileForEdit = null;
          _lrcController.clear();
          _searchQueryController.clear();
        }

        _loadRegistry();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("✅ Restaurado: $fileName a su origen."),
              backgroundColor: const Color(0xFF39FF14),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("🔴 Error de I/O restaurando: $e");
    }
  }

  void _deleteFile(String fileName) {
    try {
      final file = File('$_labPath${Platform.pathSeparator}$fileName');
      if (file.existsSync()) file.deleteSync();

      final lrcFile = File(
        '$_labPath${Platform.pathSeparator}${fileName.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}',
      );
      if (lrcFile.existsSync()) lrcFile.deleteSync();

      _registry.remove(fileName);
      final registryFile = File(
        '$_labPath${Platform.pathSeparator}quarantine_registry.json',
      );
      registryFile.writeAsStringSync(jsonEncode(_registry));

      if (_selectedFileForEdit == fileName) {
        _selectedFileForEdit = null;
        _lrcController.clear();
        _searchQueryController.clear();
      }

      _loadRegistry();
    } catch (e) {
      debugPrint("🔴 Error de I/O eliminando: $e");
    }
  }

  void _openWebBrowser(String url) {
    if (Platform.isWindows) {
      Process.run('start', [url], runInShell: true);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [url]);
    }
  }

  Future<void> _searchInternalLrclib() async {
    final query = _searchQueryController.text.trim();
    if (query.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: Colors.orangeAccent),
      ),
    );

    try {
      final results = await ref
          .read(playerProvider.notifier)
          .searchLyrics(query);
      if (!mounted) return;
      Navigator.pop(context);

      final syncedResults = results
          .where(
            (r) =>
                r['syncedLyrics'] != null &&
                r['syncedLyrics'].toString().isNotEmpty,
          )
          .toList();

      showDialog(
        context: context,
        builder: (ctx) {
          final isMobile = MediaQuery.of(ctx).size.width < 600;
          return AlertDialog(
            backgroundColor: const Color(0xFF121212),
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: Colors.orangeAccent),
              borderRadius: BorderRadius.circular(8),
            ),
            title: const Text(
              "Resultados Internos (LRCLIB)",
              style: TextStyle(color: Colors.orangeAccent, fontSize: 14),
            ),
            content: SizedBox(
              width: isMobile ? MediaQuery.of(ctx).size.width * 0.9 : 500,
              height: isMobile ? MediaQuery.of(ctx).size.height * 0.7 : 400,
              child: syncedResults.isEmpty
                  ? const Center(
                      child: Text(
                        "No se encontraron letras sincronizadas en el API.",
                        style: TextStyle(color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: syncedResults.length,
                      itemBuilder: (context, index) {
                        final track = syncedResults[index];
                        final int durationSec =
                            (track['duration'] as num?)?.toInt() ?? 0;
                        final durMin = (durationSec ~/ 60).toString().padLeft(
                          2,
                          '0',
                        );
                        final durSec = (durationSec % 60).toString().padLeft(
                          2,
                          '0',
                        );

                        return ListTile(
                          contentPadding: isMobile
                              ? EdgeInsets.zero
                              : const EdgeInsets.symmetric(horizontal: 16),
                          leading: const Icon(
                            Icons.check_circle,
                            color: Color(0xFF39FF14),
                          ),
                          title: Text(
                            "${track['artistName']} - ${track['trackName']}",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: isMobile ? 12 : 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            "Álbum: ${track['albumName']} • Duración: $durMin:$durSec",
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: isMobile ? 10 : 11,
                            ),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white10,
                              foregroundColor: Colors.orangeAccent,
                              padding: isMobile
                                  ? const EdgeInsets.symmetric(horizontal: 8)
                                  : null,
                            ),
                            child: Text(
                              "IMPORTAR",
                              style: TextStyle(fontSize: isMobile ? 10 : 12),
                            ),
                            onPressed: () {
                              setState(() {
                                _lrcController.text = track['syncedLyrics'];
                              });
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "Letra importada al editor. No olvides Guardar.",
                                  ),
                                  backgroundColor: Colors.orangeAccent,
                                ),
                              );
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text(
                  "Cerrar",
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

  // ==========================================
  // WIDGETS DE RENDERIZADO MODULAR
  // ==========================================
  Widget _buildLeftPanel(
    List<MapEntry<String, dynamic>> entries,
    bool isMobile,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final fileName = entries[index].key;
          final originalPath = entries[index].value.toString();
          final isSelected = _selectedFileForEdit == fileName;

          return Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.orangeAccent.withValues(alpha: 0.1)
                  : Colors.transparent,
              border: const Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: ListTile(
              onTap: () => _loadLrcForEdit(fileName),
              leading: Icon(
                Icons.audio_file,
                color: isSelected ? Colors.orangeAccent : Colors.white38,
              ),
              title: Text(
                fileName,
                style: TextStyle(
                  color: isSelected ? Colors.orangeAccent : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: isMobile ? 12 : 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                "Origen: ${originalPath.split(Platform.pathSeparator).reversed.skip(1).take(2).toList().reversed.join('/')}",
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: isMobile ? 9 : 10,
                  fontFamily: 'Consolas',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: const Color(0xFF1A1A1A),
                onSelected: (value) {
                  if (value == 'restore') _restoreFile(fileName, originalPath);
                  if (value == 'delete') _deleteFile(fileName);
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(Icons.restore, color: Color(0xFF39FF14), size: 18),
                        SizedBox(width: 10),
                        Text(
                          'Restaurar a Origen',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_forever,
                          color: Colors.redAccent,
                          size: 18,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Destruir Archivos',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRightPanel(bool isMobile) {
    if (_selectedFileForEdit == null) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          border: Border.all(color: Colors.white10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          "Selecciona una pista para abrir el instrumental del Laboratorio.",
          style: TextStyle(color: Colors.white38),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      children: [
        // BARRA DE HERRAMIENTAS DE BÚSQUEDA Y EXTRACCIÓN
        Container(
          padding: EdgeInsets.all(isMobile ? 10 : 15),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(
              color: Colors.orangeAccent.withValues(alpha: 0.5),
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Arsenal de Búsqueda y Sincronización",
                style: TextStyle(
                  color: Colors.orangeAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: isMobile ? 11 : 12,
                ),
              ),
              const SizedBox(height: 10),

              // 🛠️ MOTOR FLEXIBLE PARA BUSCADOR Y BOTONES NATIVOS
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: isMobile ? double.infinity : 250,
                    child: TextField(
                      controller: _searchQueryController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: Colors.black,
                        hintText: "Artista y Canción...",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _searchInternalLrclib,
                    icon: const Icon(Icons.api, size: 16),
                    label: const Text("LRCLIB (Nativo)"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00FFFF),
                      foregroundColor: Colors.black,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        '${_searchQueryController.text} official audio',
                      );
                      _openWebBrowser(
                        'https://www.youtube.com/results?search_query=$q',
                      );
                    },
                    icon: const Icon(Icons.video_library, size: 16),
                    label: const Text("YouTube MP3"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 10),

              // 🛠️ HERRAMIENTAS PESADAS PARA .LRC (AUTO-AJUSTABLES)
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser('https://genius.com/search?q=$q');
                    },
                    icon: const Icon(
                      Icons.text_snippet,
                      color: Colors.yellowAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "Genius (Letra Plana)",
                      style: TextStyle(
                        color: Colors.yellowAccent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      _openWebBrowser('https://downsub.com/');
                    },
                    icon: const Icon(
                      Icons.subtitles,
                      color: Colors.lightBlueAccent,
                      size: 14,
                    ),
                    label: const Text(
                      "DownSub (Extraer de YT)",
                      style: TextStyle(
                        color: Colors.lightBlueAccent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      _openWebBrowser('https://lrc-maker.github.io/');
                    },
                    icon: const Icon(
                      Icons.tap_and_play,
                      color: Color(0xFF39FF14),
                      size: 14,
                    ),
                    label: const Text(
                      "LRC Maker (Sincronizar Manual)",
                      style: TextStyle(color: Color(0xFF39FF14), fontSize: 11),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      final q = Uri.encodeComponent(
                        _searchQueryController.text,
                      );
                      _openWebBrowser(
                        'https://www.megalobiz.com/search/all?qry=$q',
                      );
                    },
                    icon: const Icon(
                      Icons.public,
                      color: Colors.white70,
                      size: 14,
                    ),
                    label: const Text(
                      "Megalobiz",
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                "💡 Workflow Sincronización Manual: Busca en Genius la letra plana -> Entra a 'LRC Maker' -> Pega la letra plana -> Dale Play a tu MP3 -> Toca Espacio para sincronizar -> Copia el resultado y pégalo abajo.",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        // EDITOR LRC
        Expanded(
          child: Container(
            padding: EdgeInsets.all(isMobile ? 10 : 20),
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              border: Border(
                left: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                right: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
                bottom: BorderSide(
                  color: Colors.orangeAccent.withValues(alpha: 0.5),
                ),
              ),
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (isMobile) // Botón de Volver exclusivo para móviles
                      IconButton(
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.orangeAccent,
                        ),
                        onPressed: () =>
                            setState(() => _selectedFileForEdit = null),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    if (isMobile) const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Editando LRC: ${_selectedFileForEdit!.replaceAll(RegExp(r'\.mp3$|\.webm$', caseSensitive: false), '.lrc')}",
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Consolas',
                          fontSize: isMobile ? 11 : 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: _saveLrc,
                      icon: Icon(Icons.save, size: isMobile ? 14 : 18),
                      label: Text(
                        isMobile ? "Guardar" : "Guardar en Disco",
                        style: TextStyle(fontSize: isMobile ? 10 : 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.black,
                        padding: isMobile
                            ? const EdgeInsets.symmetric(horizontal: 8)
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Expanded(
                  child: TextField(
                    controller: _lrcController,
                    maxLines: null,
                    expands: true,
                    style: TextStyle(
                      color: Colors.white,
                      fontFamily: 'Consolas',
                      fontSize: isMobile ? 11 : 13,
                    ),
                    decoration: InputDecoration(
                      hintText:
                          "Pega aquí la letra sincronizada (.lrc)...\n\n[00:15.30] Una morena me dijo\n[00:18.45] que la llevara a Jamapa",
                      hintStyle: const TextStyle(color: Colors.white24),
                      filled: true,
                      fillColor: const Color(0xFF0A0A0A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _registry.entries.toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        // 🛠️ DETECTOR DE HARDWARE (Móvil/Tablet/PC)
        final bool isMobile = constraints.maxWidth < 850;

        return Padding(
          padding: EdgeInsets.all(isMobile ? 15.0 : 30.0), // Padding dinámico
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.science,
                    color: Colors.orangeAccent,
                    size: isMobile ? 24 : 30,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      "Laboratorio de Cuarentena (DLQ)",
                      style: TextStyle(
                        fontSize: isMobile ? 18 : 24, // Letra dinámica
                        fontWeight: FontWeight.bold,
                        color: Colors.orangeAccent,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                "Entorno de aislamiento y manipulación cruda. Extrae, sincroniza o reemplaza audios/letras defectuosas antes de reinyectarlos.",
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: isMobile ? 11 : 13,
                ),
              ),
              const SizedBox(height: 20),

              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.orangeAccent),
                )
              else if (entries.isEmpty)
                Container(
                  padding: const EdgeInsets.all(40),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Text(
                    "✅ Cuarentena limpia. No hay archivos defectuosos.",
                    style: TextStyle(color: Color(0xFF39FF14), fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Expanded(
                  child: isMobile
                      // 🛠️ MODO MASTER-DETAIL (MÓVILES): Muestra un panel a la vez
                      ? (_selectedFileForEdit == null
                            ? _buildLeftPanel(entries, isMobile)
                            : _buildRightPanel(isMobile))
                      // 🛠️ MODO ESCRITORIO (PC/TABLET): Muestra ambos paneles contiguos
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 1,
                              child: _buildLeftPanel(entries, isMobile),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              flex: 2,
                              child: _buildRightPanel(isMobile),
                            ),
                          ],
                        ),
                ),
            ],
          ),
        );
      },
    );
  }
}
