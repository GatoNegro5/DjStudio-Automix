import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class LanSyncWorkspace extends ConsumerStatefulWidget {
  const LanSyncWorkspace({super.key});

  @override
  ConsumerState<LanSyncWorkspace> createState() => _LanSyncWorkspaceState();
}

class _LanSyncWorkspaceState extends ConsumerState<LanSyncWorkspace>
    with SingleTickerProviderStateMixin {
  String _localIp = "Buscando red...";
  final int _restPort = 55055;

  HttpServer? _server;
  bool _isSweeping = true;
  bool _isManualSweeping = false; // 🛠️ INYECCIÓN: Estado de escaneo manual

  final Map<String, String> _discoveredDevices = {};
  String? _selectedDeviceIp;
  String? _selectedDeviceName;

  List<String> _localFolderPaths = [];
  final Set<String> _expandedLocalPaths = {};
  String? _selectedLocalPath;
  List<File> _currentLocalFiles = [];
  final Set<String> _selectedFilesToTransfer = {};

  List<String> _remoteFolderPaths = [];
  final Set<String> _expandedRemotePaths = {};
  String? _selectedRemotePath;
  List<String> _currentRemoteFiles = [];

  bool _isTransferring = false;
  bool _cancelRequested = false;
  bool _overwriteExisting = false;
  bool _isPushMode = true;
  double _transferProgress = 0.0;
  String _currentLog = "Iniciando protocolos de seguridad y red...";
  int _totalFiles = 0;
  int _currentFileIndex = 0;
  int _successfulTransfers = 0;
  int _skippedTransfers = 0;

  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _bootSequence();
  }

  @override
  void dispose() {
    _radarController.dispose();
    _isSweeping = false;
    _server?.close(force: true);
    super.dispose();
  }

  String _getBaseMusicPath() {
    return Platform.isWindows
        ? '${Platform.environment['USERPROFILE']}\\Music'
        : (Platform.isAndroid
              ? '/storage/emulated/0/Music'
              : '${Platform.environment['HOME']}/Music');
  }

  Future<void> _bootSequence() async {
    await _ensurePermissionsAndFirewall();
    _scanLocalMusicFolders();
    await _bootRestServer();
    _startNetworkSweeper();
  }

  Future<void> _ensurePermissionsAndFirewall() async {
    if (Platform.isAndroid) {
      setState(() => _currentLog = "⚙️ Solicitando permisos de Android...");
      await Permission.audio.request();
      await Permission.storage.request();
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    }

    if (Platform.isWindows) {
      try {
        setState(() => _currentLog = "⚙️ Auditando Windows Defender...");
        final checkCmd = await Process.run('powershell', [
          '-Command',
          'Get-NetFirewallRule -DisplayName "DjStudio REST Server" -ErrorAction SilentlyContinue',
        ]);

        if (!checkCmd.stdout.toString().contains("DjStudio REST Server")) {
          setState(
            () => _currentLog = "⚠️ Escalando privilegios (Acepte el UAC)...",
          );
          final addCmd =
              '''
          Start-Process powershell -Verb runAs -WindowStyle Hidden -ArgumentList "-Command New-NetFirewallRule -DisplayName 'DjStudio REST Server' -Direction Inbound -LocalPort $_restPort -Protocol TCP -Action Allow"
          ''';
          await Process.run('powershell', ['-Command', addCmd]);
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (_) {}
    }
    setState(() => _currentLog = "✅ Permisos nativos asegurados.");
  }

  List<String> _crawlFolders(Directory dir, int currentDepth, int maxDepth) {
    if (currentDepth > maxDepth) return [];
    List<String> paths = [];
    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (var e in entities) {
        if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.') && !name.startsWith('\$')) {
            paths.add(e.path);
            paths.addAll(_crawlFolders(e, currentDepth + 1, maxDepth));
          }
        }
      }
    } catch (_) {}
    return paths;
  }

  void _scanLocalMusicFolders() {
    final baseDir = Directory(_getBaseMusicPath());
    if (baseDir.existsSync()) {
      final paths = _crawlFolders(baseDir, 0, 4);
      paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() => _localFolderPaths = paths);
    }
  }

  void _loadFilesInFolder(String path) {
    setState(() {
      _selectedLocalPath = path;
      try {
        _currentLocalFiles = Directory(path)
            .listSync(recursive: false, followLinks: false)
            .whereType<File>()
            .where((f) {
              final ext = f.path.toLowerCase();
              return ext.endsWith('.mp3') ||
                  ext.endsWith('.lrc') ||
                  ext.endsWith('.txt');
            })
            .toList();
        _currentLocalFiles.sort(
          (a, b) => a.uri.pathSegments.last.toLowerCase().compareTo(
            b.uri.pathSegments.last.toLowerCase(),
          ),
        );
      } catch (_) {
        _currentLocalFiles = [];
      }
      _selectedFilesToTransfer.clear();
    });
  }

  List<File> _getFilesRecursively(Directory dir, [int depth = 0]) {
    if (depth > 5) return [];
    List<File> result = [];
    try {
      final entities = dir.listSync(recursive: false, followLinks: false);
      for (var e in entities) {
        if (e is File) {
          final ext = e.path.toLowerCase();
          if (ext.endsWith('.mp3') ||
              ext.endsWith('.lrc') ||
              ext.endsWith('.txt')) {
            result.add(e);
          }
        } else if (e is Directory) {
          final name = e.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('.') && !name.startsWith('\$')) {
            result.addAll(_getFilesRecursively(e, depth + 1));
          }
        }
      }
    } catch (_) {}
    return result;
  }

  void _toggleSelectAllFiles() {
    setState(() {
      if (_selectedFilesToTransfer.length == _currentLocalFiles.length) {
        _selectedFilesToTransfer.clear();
      } else {
        _selectedFilesToTransfer.addAll(_currentLocalFiles.map((f) => f.path));
      }
    });
  }

  Future<void> _bootRestServer() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (var interface in interfaces) {
        if (!interface.name.toLowerCase().contains('virtual') &&
            interface.name != 'lo') {
          _localIp = interface.addresses.first.address;
          break;
        }
      }

      _server = await HttpServer.bind(InternetAddress.anyIPv4, _restPort);
      _server!.listen(_handleRestRequests);
      setState(
        () => _currentLog = "✅ Servidor REST activo en $_localIp:$_restPort",
      );
    } catch (e) {
      setState(() => _currentLog = "🔴 Error bind puerto $_restPort: $e");
    }
  }

  String _resolvePath(String relativePath) {
    String base = _getBaseMusicPath();
    if (relativePath.isEmpty || relativePath == 'ROOT') return base;
    if (relativePath.startsWith('ROOT/')) {
      relativePath = relativePath.substring(5);
    }
    return '$base${Platform.pathSeparator}${relativePath.replaceAll('/', Platform.pathSeparator)}';
  }

  void _handleRestRequests(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;

    try {
      if (request.method == 'GET' && path == '/api/whoami') {
        final osInfo = Platform.operatingSystem.toUpperCase();
        final hostInfo = Platform.localHostname;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({"name": "$osInfo - $hostInfo"}))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/tree') {
        final baseMusicPath = _getBaseMusicPath();
        final folderNames = _localFolderPaths.map((p) {
          String rel = p.replaceFirst(baseMusicPath, '');
          if (rel.startsWith(Platform.pathSeparator)) rel = rel.substring(1);
          return rel.replaceAll('\\', '/');
        }).toList();
        folderNames.removeWhere((n) => n.isEmpty);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(folderNames))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/files') {
        final targetPath = _resolvePath(query['dir'] ?? 'ROOT');
        List<String> files = [];
        final dir = Directory(targetPath);
        if (dir.existsSync()) {
          for (var f in dir.listSync(recursive: false).whereType<File>()) {
            final ext = f.path.toLowerCase();
            if (ext.endsWith('.mp3') ||
                ext.endsWith('.lrc') ||
                ext.endsWith('.txt')) {
              files.add(f.uri.pathSegments.last);
            }
          }
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(files))
          ..close();
        return;
      }

      if (request.method == 'GET' && path == '/api/download') {
        final targetPath = _resolvePath(query['file'] ?? '');
        final file = File(targetPath);
        if (file.existsSync()) {
          final isAudio = targetPath.toLowerCase().endsWith('.mp3');
          request.response
            ..headers.contentType = isAudio
                ? ContentType('audio', 'mpeg')
                : ContentType('text', 'plain')
            ..headers.add('content-length', file.lengthSync().toString())
            ..addStream(file.openRead()).then((_) => request.response.close());
        } else {
          request.response
            ..statusCode = 404
            ..close();
        }
        return;
      }

      if (request.method == 'POST' && path == '/api/upload') {
        final targetDir = _resolvePath(query['dir'] ?? 'ROOT');
        final dir = Directory(targetDir);
        if (!dir.existsSync()) dir.createSync(recursive: true);

        final boundary = request.headers.contentType?.parameters['boundary'];
        if (boundary != null) {
          final transformer = MimeMultipartTransformer(boundary);
          final bodyStream = request.cast<List<int>>().transform(transformer);

          await for (final part in bodyStream) {
            final contentDisposition = part.headers['content-disposition'];
            if (contentDisposition != null &&
                contentDisposition.contains('filename=')) {
              final match = RegExp(
                r'filename="([^"]+)"',
              ).firstMatch(contentDisposition);
              if (match != null) {
                final savePath =
                    '${dir.path}${Platform.pathSeparator}${match.group(1)}';
                final sink = File(savePath).openWrite();
                await part.pipe(sink);
                await sink.close();
              }
            }
          }
          request.response
            ..statusCode = 200
            ..write("OK")
            ..close();
          _scanLocalMusicFolders();
          if (_selectedLocalPath != null) {
            _loadFilesInFolder(_selectedLocalPath!);
          }
          return;
        }
      }

      request.response
        ..statusCode = 404
        ..close();
    } catch (e) {
      request.response
        ..statusCode = 500
        ..close();
    }
  }

  Future<void> _startNetworkSweeper() async {
    final subnetParts = _localIp.split('.');
    if (subnetParts.length != 4) return;
    final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';

    while (mounted && _isSweeping) {
      for (int i = 1; i <= 254; i += 20) {
        if (!mounted) break;
        List<Future> batch = [];
        for (int j = 0; j < 20; j++) {
          int lastOctet = i + j;
          if (lastOctet > 254) break;
          final targetIp = '$subnet.$lastOctet';
          if (targetIp == _localIp) continue;
          batch.add(_probeDeviceHttp(targetIp));
        }
        await Future.wait(batch);
      }
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  // 🛠️ INYECCIÓN: Radar concurrente para barrido en 600ms exactos
  // 🛠️ INYECCIÓN: Radar concurrente por lotes (Evita Socket Exhaustion)
  Future<void> _forceNetworkSweep() async {
    if (_isManualSweeping) return;
    setState(() {
      _isManualSweeping = true;
      _currentLog = "📡 Disparando escaneo de radar (Batches de 50 nodos)...";
    });

    final subnetParts = _localIp.split('.');
    if (subnetParts.length == 4) {
      final subnet = '${subnetParts[0]}.${subnetParts[1]}.${subnetParts[2]}';

      // 🛠️ FIX ARQUITECTÓNICO: Escaneo en bloques de 50 para no colapsar la tabla de descriptores de red del OS
      for (int i = 1; i <= 254; i += 50) {
        if (!mounted) break;
        List<Future<void>> batch = [];

        for (int j = 0; j < 50; j++) {
          int target = i + j;
          if (target > 254) break;
          final targetIp = '$subnet.$target';
          if (targetIp == _localIp) continue;
          batch.add(_probeDeviceHttp(targetIp));
        }

        await Future.wait(batch);
      }
    }

    if (mounted) {
      setState(() {
        _isManualSweeping = false;
        _currentLog =
            "✅ Barrido de radar completado. Nodos activos: ${_discoveredDevices.length}";
      });
    }
  }

  Future<void> _probeDeviceHttp(String targetIp) async {
    try {
      final response = await http
          .get(Uri.parse('http://$targetIp:$_restPort/api/whoami'))
          // 🛠️ FIX: 1500ms para tolerar el Wake-up de la antena Wi-Fi del celular
          .timeout(const Duration(milliseconds: 1500));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted && _discoveredDevices[targetIp] != data['name']) {
          setState(() => _discoveredDevices[targetIp] = data['name']);
        }
      }
    } catch (
      _
    ) {} // Los fallos por timeout son esperados y se ignoran en silencio
  }

  void _promptManualConnection() {
    final ipController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFF00FFFF)),
          borderRadius: BorderRadius.circular(8),
        ),
        title: const Text(
          "Conexión Manual REST",
          style: TextStyle(color: Color(0xFF00FFFF)),
        ),
        content: TextField(
          controller: ipController,
          style: const TextStyle(color: Colors.white, fontFamily: 'Consolas'),
          decoration: const InputDecoration(
            hintText: "Ej: 192.168.1.8",
            hintStyle: TextStyle(color: Colors.white24),
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              final ip = ipController.text.trim();
              if (ip.isNotEmpty) {
                Navigator.pop(ctx);
                setState(() {
                  _discoveredDevices[ip] = "Dispositivo Manual";
                  _selectedDeviceIp = ip;
                  _selectedDeviceName = "Dispositivo Manual";
                });
                _fetchRemoteDirectoryTree(ip);
                _probeDeviceHttp(ip);
              }
            },
            child: const Text("ENLAZAR"),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchRemoteDirectoryTree(String targetIp) async {
    setState(
      () => _currentLog = "📡 Solicitando árbol de directorios a $targetIp...",
    );
    try {
      final response = await http
          .get(Uri.parse('http://$targetIp:$_restPort/api/tree'))
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        final folders = jsonList.map((e) => e.toString()).toList();
        if (mounted) {
          setState(() {
            folders.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            _remoteFolderPaths = folders;
            _currentLog =
                "✅ Árbol remoto obtenido: ${folders.length} carpetas.";
            if (_selectedRemotePath == null && folders.isNotEmpty) {
              _selectedRemotePath = folders.first;
              _fetchRemoteFiles(targetIp, _selectedRemotePath!);
            } else if (folders.isEmpty) {
              _currentLog =
                  "⚠️ HTTP 200 OK: La app remota respondió, pero su carpeta Music está VACÍA o no diste permiso en pantalla.";
            }
          });
        }
      } else {
        setState(
          () => _currentLog =
              "🔴 ERROR HTTP ${response.statusCode}: ${response.body}",
        );
      }
    } catch (e) {
      setState(() {
        _remoteFolderPaths = [];
        _selectedRemotePath = null;
        _currentLog = "🔴 TRACKER EXCEPTION (Tree): $e";
      });
    }
  }

  Future<void> _fetchRemoteFiles(String targetIp, String remotePath) async {
    setState(() {
      _currentRemoteFiles = [];
      _currentLog = "📡 Solicitando archivos de $remotePath...";
    });
    try {
      final response = await http
          .get(
            Uri.parse(
              'http://$targetIp:$_restPort/api/files?dir=${Uri.encodeComponent(remotePath)}',
            ),
          )
          .timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        final files = jsonList.map((e) => e.toString()).toList();
        if (mounted) {
          setState(() {
            files.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            _currentRemoteFiles = files;
            _currentLog =
                "✅ ${files.length} archivos obtenidos de $remotePath.";
          });
        }
      } else {
        setState(() => _currentLog = "🔴 ERROR HTTP ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _currentLog = "🔴 TRACKER EXCEPTION (Files): $e");
    }
  }

  void _promptTransferConfirmation() {
    if (_selectedDeviceIp == null ||
        _selectedRemotePath == null ||
        _selectedLocalPath == null) {
      return;
    }

    bool isDirectoryClone = _selectedFilesToTransfer.isEmpty;
    int targetFilesCount = _isPushMode
        ? (isDirectoryClone
              ? _getFilesRecursively(Directory(_selectedLocalPath!)).length
              : _selectedFilesToTransfer.length)
        : _currentRemoteFiles.length;

    if (targetFilesCount == 0) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: _isPushMode
                ? const Color(0xFF39FF14)
                : const Color(0xFF00FFFF),
          ),
        ),
        title: Text(
          _isPushMode ? "INICIAR PUSH" : "INICIAR PULL",
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          "Procesando ~$targetFilesCount pistas vía API REST.\nHost: $_selectedDeviceName",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _isPushMode
                  ? const Color(0xFF39FF14)
                  : const Color(0xFF00FFFF),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _executeTransferJob(isDirectoryClone);
            },
            child: const Text("AUTORIZAR"),
          ),
        ],
      ),
    );
  }

  Future<void> _executeTransferJob(bool isDirectoryClone) async {
    setState(() {
      _isTransferring = true;
      _cancelRequested = false;
      _transferProgress = 0.0;
      _currentFileIndex = 0;
      _successfulTransfers = 0;
      _skippedTransfers = 0;
      _currentLog = "Iniciando Job REST (Evaluando metadatos y colisiones)...";
    });

    if (_isPushMode) {
      Set<String> pushQueue = {};
      if (isDirectoryClone) {
        pushQueue.addAll(
          _getFilesRecursively(
            Directory(_selectedLocalPath!),
          ).map((f) => f.path),
        );
      } else {
        for (String path in _selectedFilesToTransfer) {
          pushQueue.add(path);
          if (path.toLowerCase().endsWith('.mp3')) {
            final lrcPath = '${path.substring(0, path.length - 4)}.lrc';
            final txtPath = '${path.substring(0, path.length - 4)}.txt';
            if (File(lrcPath).existsSync()) pushQueue.add(lrcPath);
            if (File(txtPath).existsSync()) pushQueue.add(txtPath);
          }
        }
      }

      final files = pushQueue.map((p) => File(p)).toList();
      setState(() => _totalFiles = files.length);

      for (int i = 0; i < files.length; i++) {
        if (_cancelRequested) break;
        final file = files[i];
        final fileName = file.uri.pathSegments.last;

        setState(() {
          _currentFileIndex = i + 1;
          _transferProgress = (_currentFileIndex - 1) / _totalFiles;
        });

        if (_currentRemoteFiles.contains(fileName)) {
          if (!_overwriteExisting) {
            setState(() => _currentLog = "⏩ SALTADO (Ya existe): $fileName");
            _skippedTransfers++;
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬆️ ENVIANDO: $fileName");
        }

        try {
          final request = http.MultipartRequest(
            'POST',
            Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/upload?dir=${Uri.encodeComponent(_selectedRemotePath ?? "ROOT")}',
            ),
          );
          request.files.add(
            await http.MultipartFile.fromPath('file', file.path),
          );
          final response = await request.send();
          if (response.statusCode == 200) {
            _successfulTransfers++;
          } else {
            _skippedTransfers++;
          }
        } catch (_) {
          _skippedTransfers++;
        }
      }
    } else {
      final files = _currentRemoteFiles;
      setState(() => _totalFiles = files.length);

      final localDir = Directory(_selectedLocalPath!);
      for (int i = 0; i < files.length; i++) {
        if (_cancelRequested) break;
        final fileName = files[i];

        setState(() {
          _currentFileIndex = i + 1;
          _transferProgress = (_currentFileIndex - 1) / _totalFiles;
        });

        final saveFile = File(
          '${localDir.path}${Platform.pathSeparator}$fileName',
        );

        if (saveFile.existsSync()) {
          if (!_overwriteExisting) {
            setState(() => _currentLog = "⏩ SALTADO (Ya existe): $fileName");
            _skippedTransfers++;
            continue;
          } else {
            setState(() => _currentLog = "🔄 REEMPLAZANDO: $fileName");
          }
        } else {
          setState(() => _currentLog = "⬇️ EXTRAYENDO: $fileName");
        }

        try {
          final client = HttpClient();
          final request = await client.getUrl(
            Uri.parse(
              'http://$_selectedDeviceIp:$_restPort/api/download?file=${Uri.encodeComponent("$_selectedRemotePath/$fileName")}',
            ),
          );
          final response = await request.close();
          if (response.statusCode == 200) {
            await response.pipe(saveFile.openWrite());
            _successfulTransfers++;
          } else {
            _skippedTransfers++;
          }
          client.close();
        } catch (_) {
          _skippedTransfers++;
        }
      }
      _scanLocalMusicFolders();
      _loadFilesInFolder(_selectedLocalPath!);
    }

    setState(() {
      _transferProgress = 1.0;
      _isTransferring = false;
      _currentLog =
          "✅ Job Finalizado. Éxito: $_successfulTransfers | Saltados/Fallos: $_skippedTransfers";
      _selectedFilesToTransfer.clear();
    });

    if (_selectedDeviceIp != null && _selectedRemotePath != null) {
      _fetchRemoteFiles(_selectedDeviceIp!, _selectedRemotePath!);
    }
  }

  Widget _buildTransferOverlay() {
    if (!_isTransferring &&
        _transferProgress == 0.0 &&
        _successfulTransfers == 0 &&
        _skippedTransfers == 0) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.90),
        child: Center(
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(25),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A),
              border: Border.all(
                color: _isPushMode
                    ? const Color(0xFF39FF14)
                    : const Color(0xFF00FFFF),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _isTransferring
                      ? "REST I/O EN PROGRESO"
                      : "OPERACIÓN FINALIZADA",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _currentLog,
                  style: TextStyle(
                    color: _isPushMode
                        ? const Color(0xFF39FF14)
                        : const Color(0xFF00FFFF),
                    fontFamily: 'Consolas',
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: _transferProgress,
                  color: _isPushMode
                      ? const Color(0xFF39FF14)
                      : const Color(0xFF00FFFF),
                ),
                const SizedBox(height: 25),
                if (_isTransferring)
                  ElevatedButton(
                    onPressed: () => setState(() => _cancelRequested = true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    child: const Text("KILL SWITCH"),
                  )
                else
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _transferProgress = 0.0;
                      _successfulTransfers = 0;
                      _skippedTransfers = 0;
                    }),
                    child: const Text("CERRAR TERMINAL"),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalTree(List<String> visibleLocalPaths, String basePath) {
    return Material(
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            color: Colors.black,
            child: const Text(
              "ORIGEN (Local)",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visibleLocalPaths.length,
              itemBuilder: (context, index) {
                final path = visibleLocalPaths[index];
                final isSelected = _selectedLocalPath == path;
                String rel = path.replaceFirst(basePath, '');
                if (rel.startsWith(Platform.pathSeparator)) {
                  rel = rel.substring(1);
                }
                final depth = rel.isEmpty
                    ? 0
                    : rel.split(Platform.pathSeparator).length - 1;
                final hasChildren = _localFolderPaths.any(
                  (p) =>
                      p.startsWith(path + Platform.pathSeparator) && p != path,
                );
                final isExpanded = _expandedLocalPaths.contains(path);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -4),
                  contentPadding: EdgeInsets.only(
                    left: 10.0 + (depth * 15.0),
                    right: 10.0,
                  ),
                  tileColor: isSelected
                      ? const Color(0xFF00FFFF).withValues(alpha: 0.1)
                      : null,
                  leading: Icon(
                    hasChildren
                        ? (isExpanded ? Icons.folder_open : Icons.folder)
                        : Icons.folder,
                    color: isSelected
                        ? const Color(0xFF00FFFF)
                        : Colors.white38,
                    size: 18,
                  ),
                  title: Text(
                    path.split(Platform.pathSeparator).last,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                  ),
                  onTap: () {
                    setState(() {
                      if (hasChildren) {
                        isExpanded
                            ? _expandedLocalPaths.remove(path)
                            : _expandedLocalPaths.add(path);
                      }
                      _loadFilesInFolder(path);
                    });
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalFiles() {
    return Material(
      color: const Color(0xFF101010),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            color: const Color(0xFF1A1A1A),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "${_selectedFilesToTransfer.length} seleccionados",
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 10,
                  ),
                ),
                TextButton(
                  onPressed: _toggleSelectAllFiles,
                  child: const Text(
                    "Marcar Todo",
                    style: TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _currentLocalFiles.length,
              itemBuilder: (context, index) {
                final file = _currentLocalFiles[index];
                final isSelected = _selectedFilesToTransfer.contains(file.path);
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -4),
                  leading: Checkbox(
                    value: isSelected,
                    activeColor: const Color(0xFF00FFFF),
                    onChanged: (v) => setState(
                      () => v == true
                          ? _selectedFilesToTransfer.add(file.path)
                          : _selectedFilesToTransfer.remove(file.path),
                    ),
                  ),
                  title: Text(
                    file.uri.pathSegments.last,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white54,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                  ),
                  onTap: () => setState(
                    () => isSelected
                        ? _selectedFilesToTransfer.remove(file.path)
                        : _selectedFilesToTransfer.add(file.path),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteTree(List<String> visibleRemotePaths) {
    if (_selectedDeviceIp == null) {
      return Material(
        color: const Color(0xFF0A0A0A),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: Colors.black,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "NODOS REST",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isManualSweeping)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            color: Color(0xFF39FF14),
                            strokeWidth: 2,
                          ),
                        )
                      else
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(
                            Icons.search,
                            color: Color(0xFF39FF14),
                            size: 18,
                          ),
                          tooltip: "Radar: Escaneo Rápido de Red",
                          onPressed: _forceNetworkSweep,
                        ),
                      const SizedBox(width: 12),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(
                          Icons.add_link,
                          color: Color(0xFF00FFFF),
                          size: 18,
                        ),
                        tooltip: "Conexión Manual",
                        onPressed: _promptManualConnection,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _discoveredDevices.length,
                itemBuilder: (context, index) {
                  final ip = _discoveredDevices.keys.elementAt(index);
                  final name = _discoveredDevices[ip]!;
                  return ListTile(
                    leading: const Icon(
                      Icons.computer,
                      color: Color(0xFF39FF14),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    subtitle: Text(
                      ip,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    onTap: () => setState(() {
                      _selectedDeviceIp = ip;
                      _selectedDeviceName = name;
                      _fetchRemoteDirectoryTree(ip);
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      color: const Color(0xFF0A0A0A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            color: Colors.black,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => setState(() {
                    _selectedDeviceIp = null;
                    _selectedRemotePath = null;
                    _currentRemoteFiles.clear();
                  }),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "DESTINO",
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      _selectedDeviceName!,
                      style: const TextStyle(
                        color: Color(0xFF39FF14),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visibleRemotePaths.length,
              itemBuilder: (context, index) {
                final path = visibleRemotePaths[index];
                final isSelected = _selectedRemotePath == path;
                final depth = path.split('/').length - 1;
                final hasChildren = _remoteFolderPaths.any(
                  (p) => p.startsWith('$path/'),
                );
                final isExpanded = _expandedRemotePaths.contains(path);

                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -4),
                  contentPadding: EdgeInsets.only(
                    left: 10.0 + (depth * 15.0),
                    right: 10.0,
                  ),
                  tileColor: isSelected
                      ? const Color(0xFF39FF14).withValues(alpha: 0.1)
                      : null,
                  leading: Icon(
                    hasChildren
                        ? (isExpanded ? Icons.folder_open : Icons.folder)
                        : Icons.folder,
                    color: isSelected
                        ? const Color(0xFF39FF14)
                        : Colors.white38,
                    size: 18,
                  ),
                  title: Text(
                    path.split('/').last,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                  ),
                  onTap: () {
                    setState(() {
                      if (hasChildren) {
                        isExpanded
                            ? _expandedRemotePaths.remove(path)
                            : _expandedRemotePaths.add(path);
                      }
                      _selectedRemotePath = path;
                    });
                    _fetchRemoteFiles(_selectedDeviceIp!, path);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteFiles() {
    return Material(
      color: const Color(0xFF101010),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1A1A1A),
            child: Text(
              "${_currentRemoteFiles.length} remotos",
              style: const TextStyle(color: Color(0xFF39FF14), fontSize: 10),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _currentRemoteFiles.length,
              itemBuilder: (context, index) => ListTile(
                dense: true,
                visualDensity: const VisualDensity(vertical: -4),
                leading: const Icon(
                  Icons.audiotrack,
                  color: Colors.white24,
                  size: 16,
                ),
                title: Text(
                  _currentRemoteFiles[index],
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final basePath = _getBaseMusicPath();

    List<String> visibleLocalPaths = [];
    for (String path in _localFolderPaths) {
      String rel = path.replaceFirst(basePath, '');
      if (rel.startsWith(Platform.pathSeparator)) rel = rel.substring(1);
      List<String> parts = rel.split(Platform.pathSeparator);
      if (parts.length <= 1) {
        visibleLocalPaths.add(path);
      } else {
        bool allExpanded = true;
        String cp = basePath;
        for (int i = 0; i < parts.length - 1; i++) {
          cp += Platform.pathSeparator + parts[i];
          if (!_expandedLocalPaths.contains(cp)) {
            allExpanded = false;
            break;
          }
        }
        if (allExpanded) visibleLocalPaths.add(path);
      }
    }

    List<String> visibleRemotePaths = [];
    for (String path in _remoteFolderPaths) {
      List<String> parts = path.split('/');
      if (parts.length <= 1) {
        visibleRemotePaths.add(path);
      } else {
        bool allExpanded = true;
        String cp = '';
        for (int i = 0; i < parts.length - 1; i++) {
          cp += (i == 0 ? '' : '/') + parts[i];
          if (!_expandedRemotePaths.contains(cp)) {
            allExpanded = false;
            break;
          }
        }
        if (allExpanded) visibleRemotePaths.add(path);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = constraints.maxWidth < 850;
        Widget headerTelemetry = Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF050505),
            border: Border(
              bottom: BorderSide(
                color: const Color(0xFF00FFFF).withValues(alpha: 0.3),
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  RotationTransition(
                    turns: _radarController,
                    child: const Icon(
                      Icons.radar,
                      color: Color(0xFF00FFFF),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "RED P2P REST",
                        style: TextStyle(
                          color: Color(0xFF00FFFF),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        "$_localIp | Nodos: ${_discoveredDevices.length}",
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (!isMobile)
                Row(
                  children: [
                    const Text(
                      "Sobrescribir",
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    Switch(
                      value: _overwriteExisting,
                      activeThumbColor: const Color(0xFFFF007F),
                      onChanged: _isTransferring
                          ? null
                          : (v) => setState(() => _overwriteExisting = v),
                    ),
                  ],
                ),
            ],
          ),
        );

        return Stack(
          children: [
            Column(
              children: [
                headerTelemetry,
                Container(
                  color: const Color(0xFF101010),
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                        selectedColor: const Color(
                          0xFF39FF14,
                        ).withValues(alpha: 0.2),
                        backgroundColor: Colors.black,
                        side: BorderSide(
                          color: _isPushMode
                              ? const Color(0xFF39FF14)
                              : Colors.white10,
                        ),
                        label: const Text(
                          "ENVIAR PUSH",
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                        selected: _isPushMode,
                        onSelected: (v) => setState(() => _isPushMode = true),
                      ),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        selectedColor: const Color(
                          0xFF00FFFF,
                        ).withValues(alpha: 0.2),
                        backgroundColor: Colors.black,
                        side: BorderSide(
                          color: !_isPushMode
                              ? const Color(0xFF00FFFF)
                              : Colors.white10,
                        ),
                        label: const Text(
                          "EXTRAER PULL",
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                        selected: !_isPushMode,
                        onSelected: (v) => setState(() => _isPushMode = false),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: isMobile
                      ? DefaultTabController(
                          length: 2,
                          child: Column(
                            children: [
                              const TabBar(
                                labelColor: Colors.white,
                                unselectedLabelColor: Colors.white38,
                                indicatorColor: Color(0xFF00FFFF),
                                tabs: [
                                  Tab(text: "ORIGEN (Local)"),
                                  Tab(text: "DESTINO (Remoto)"),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildLocalTree(
                                            visibleLocalPaths,
                                            basePath,
                                          ),
                                        ),
                                        Expanded(child: _buildLocalFiles()),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _buildRemoteTree(
                                            visibleRemotePaths,
                                          ),
                                        ),
                                        Expanded(child: _buildRemoteFiles()),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Container(
                                width: double.infinity,
                                color: const Color(0xFF050505),
                                padding: const EdgeInsets.all(10),
                                child: ElevatedButton.icon(
                                  onPressed:
                                      (_selectedDeviceIp != null &&
                                          _selectedRemotePath != null &&
                                          _selectedLocalPath != null &&
                                          !_isTransferring)
                                      ? _promptTransferConfirmation
                                      : null,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isPushMode
                                        ? const Color(0xFF39FF14)
                                        : const Color(0xFF00FFFF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 15,
                                    ),
                                  ),
                                  icon: Icon(
                                    _isPushMode ? Icons.upload : Icons.download,
                                  ),
                                  label: Text(
                                    _isPushMode
                                        ? "TRANSFERIR (PUSH)"
                                        : "TRANSFERIR (PULL)",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildLocalTree(
                                visibleLocalPaths,
                                basePath,
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(flex: 4, child: _buildLocalFiles()),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(
                              flex: 1,
                              child: Container(
                                color: const Color(0xFF050505),
                                child: Center(
                                  child: ElevatedButton(
                                    onPressed:
                                        (_selectedDeviceIp != null &&
                                            _selectedRemotePath != null &&
                                            _selectedLocalPath != null &&
                                            !_isTransferring)
                                        ? _promptTransferConfirmation
                                        : null,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _isPushMode
                                          ? const Color(0xFF39FF14)
                                          : const Color(0xFF00FFFF),
                                      foregroundColor: Colors.black,
                                      shape: const CircleBorder(),
                                      padding: const EdgeInsets.all(20),
                                    ),
                                    child: Icon(
                                      _isPushMode
                                          ? Icons.double_arrow
                                          : Icons.keyboard_double_arrow_left,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(
                              flex: 3,
                              child: _buildRemoteTree(visibleRemotePaths),
                            ),
                            const VerticalDivider(
                              width: 1,
                              color: Colors.white10,
                            ),
                            Expanded(flex: 4, child: _buildRemoteFiles()),
                          ],
                        ),
                ),
              ],
            ),
            _buildTransferOverlay(),
          ],
        );
      },
    );
  }
}
