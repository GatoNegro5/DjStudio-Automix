import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // 🛠️ INYECCIÓN: Inicializa el motor de audio nativo
  runApp(const DjStudioTvApp());
}

class DjStudioTvApp extends StatelessWidget {
  const DjStudioTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DjStudio Edge Node',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050505),
        fontFamily: 'Consolas',
      ),
      home: const BootScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ==========================================
// PANTALLA DE CONFIGURACIÓN
// ==========================================
class BootScreen extends StatefulWidget {
  const BootScreen({super.key});

  @override
  State<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<BootScreen> {
  final TextEditingController _ipController = TextEditingController();
  bool _isLoading = true;
  bool _showForm = false;
  String _status = 'Buscando la laptop…';

  @override
  void initState() {
    super.initState();
    unawaited(_autoJoin());
  }

  Future<bool> _probe(String ip) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 450);
    try {
      final request = await client.getUrl(
        Uri.parse('http://$ip:55056/api/whoami'),
      );
      final response = await request.close().timeout(
        const Duration(milliseconds: 450),
      );
      final body = await response.transform(utf8.decoder).join();
      return response.statusCode == 200 && body.contains('djstudio-karaoke');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _scanLan() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isEmpty) return null;
      final self = interfaces.first.addresses.first.address;
      final parts = self.split('.');
      if (parts.length != 4) return null;
      final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
      for (var start = 1; start <= 254; start += 40) {
        if (!mounted) return null;
        final batch = <Future<String?>>[];
        for (var host = start; host < start + 40 && host <= 254; host++) {
          final ip = '$prefix.$host';
          if (ip == self) continue;
          batch.add(_probe(ip).then((ok) => ok ? ip : null));
        }
        final hits = (await Future.wait(batch)).whereType<String>();
        if (hits.isNotEmpty) return hits.first;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _enter(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', ip);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => TeleprompterScreen(serverIp: ip)),
    );
  }

  Future<void> _autoJoin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('server_ip') ?? '';
    if (savedIp.isNotEmpty) {
      _ipController.text = savedIp;
      if (await _probe(savedIp)) {
        await _enter(savedIp);
        return;
      }
    }
    if (mounted) setState(() => _status = 'Explorando WiFi…');
    final found = await _scanLan();
    if (found != null) {
      await _enter(found);
      return;
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _showForm = true;
      _status = 'No hallé la laptop. Escribe la IP del orquestador.';
    });
  }

  void _connect() {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    unawaited(_enter(ip));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFB026FF), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tv, size: 80, color: Color(0xFFB026FF)),
              const SizedBox(height: 20),
              const Text(
                "NODO EDGE TV",
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
              if (_isLoading) ...[
                const SizedBox(height: 30),
                const CircularProgressIndicator(color: Color(0xFF39FF14)),
              ],
              if (_showForm) ...[
                const SizedBox(height: 30),
                TextField(
                  controller: _ipController,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    prefixText: "ws:// ",
                    suffixText: ":55056",
                    prefixStyle: const TextStyle(color: Colors.white38),
                    suffixStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.black,
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF39FF14)),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                ElevatedButton(
                  autofocus: true,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF39FF14),
                    foregroundColor: Colors.black,
                    minimumSize: const Size(double.infinity, 60),
                  ),
                  onPressed: _connect,
                  child: const Text(
                    "CONECTAR",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// EDGE NODE Y GARBAGE COLLECTOR
// ==========================================
class TeleprompterScreen extends StatefulWidget {
  final String serverIp;
  const TeleprompterScreen({super.key, required this.serverIp});

  @override
  State<TeleprompterScreen> createState() => _TeleprompterScreenState();
}

class _StandbyCartridge {
  final String mp3Path;
  final String mp3Url;
  final String trackName;
  final String singer;
  final String rawLrc;

  const _StandbyCartridge({
    required this.mp3Path,
    required this.mp3Url,
    required this.trackName,
    required this.singer,
    required this.rawLrc,
  });
}

class _TeleprompterScreenState extends State<TeleprompterScreen> {
  WebSocketChannel? _channel;
  final ScrollController _scrollController = ScrollController();
  final Player _player = Player();
  final Dio _dio = Dio();
  StreamSubscription? _positionSub;
  StreamSubscription? _completedSub;

  String _status = "Conectando...";
  bool _isConnected = false;
  bool _isDownloading = false;
  bool _paused = false;
  bool _sessionClosed = false;
  double _downloadProgress = 0.0;

  String _currentTrackName = "";
  String _currentSinger = "";
  Map<Duration, String> _lyricsMs = {};
  List<Duration> _lyricKeys = const [];
  Map<String, dynamic> _scoreboard = {};

  Duration _currentPosition = Duration.zero;
  int _activeIndex = 0;
  int _countdown = 0;
  int _lastTickMs = 0;
  double _lastProgressShown = -1;

  String? _localMp3Path;
  _StandbyCartridge? _standby;
  List<Map<String, String>> _queue = const [];
  Map<String, int> _votes = const {'👏': 0, '🔥': 0, '💩': 0};
  String _qrUrl = '';
  bool _session = false;

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
    _setupAudioListener();
    _completedSub = _player.stream.completed.listen((done) {
      if (done) _send({'type': 'TV_TRACK_ENDED'});
    });
  }

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  void _connectWebSocket() {
    if (_sessionClosed) return;
    final uri = Uri.parse('ws://${widget.serverIp}:55056');
    try {
      _channel = WebSocketChannel.connect(uri);
      setState(() {
        _isConnected = true;
        _status = "Esperando pista desde la PC...";
      });

      _channel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);
            switch (data['type']) {
              case 'EDGE_PRELOAD':
                unawaited(_downloadStandby(data));
              case 'EDGE_EXECUTE':
                unawaited(_execute(data));
              case 'EDGE_STOP':
                unawaited(_stopAndClear());
              case 'EDGE_PAUSE':
                unawaited(_pause(fromHost: true));
              case 'EDGE_RESUME':
                unawaited(_resume(fromHost: true));
              case 'SCOREBOARD':
                _showScoreboard(data);
              case 'SESSION_END':
                unawaited(_leaveSession());
              case 'STAGE_STATE':
                _applyStageState(data);
            }
          } catch (e) {
            debugPrint("Parse Error: $e");
          }
        },
        onDone: _handleDisconnect,
        onError: (e) => _handleDisconnect(),
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    if (!mounted || _sessionClosed) return;
    setState(() {
      _isConnected = false;
      _status = "Conexión perdida. Reintentando en 5s...";
    });
    unawaited(_stopAndClear());
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && !_sessionClosed) _connectWebSocket();
    });
  }

  // 🧠 CORE: Ingesta del CDN y Garbage Collection
  Future<void> _garbageCollect() async {
    await _player.stop();
    if (_localMp3Path != null) {
      try {
        final f = File(_localMp3Path!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _stopAndClear() async {
    await _player.stop();
    if (mounted) {
      setState(() {
        _lyricsMs.clear();
        _lyricKeys = const [];
        _currentTrackName = "";
        _currentSinger = "";
        _status = "Esperando pista desde la PC...";
        _countdown = 0;
        _paused = false;
        _scoreboard = {};
      });
    }
  }

  Future<void> _pause({bool fromHost = false}) async {
    await _player.pause();
    if (mounted) setState(() => _paused = true);
    if (!fromHost) _send({'type': 'TV_PAUSE'});
  }

  Future<void> _resume({bool fromHost = false}) async {
    await _player.play();
    if (mounted) setState(() => _paused = false);
    if (!fromHost) _send({'type': 'TV_RESUME'});
  }

  Future<void> _leaveSession() async {
    _sessionClosed = true;
    await _garbageCollect();
    await _clearStandby();
    await _player.stop();
    await _channel?.sink.close();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const BootScreen()),
    );
  }

  void _applyStageState(Map<String, dynamic> data) {
    final rawQueue = data['queue'];
    final queue = <Map<String, String>>[];
    if (rawQueue is List) {
      for (final item in rawQueue) {
        if (item is Map) {
          queue.add({
            'user': '${item['user'] ?? ''}',
            'song': '${item['song'] ?? ''}',
          });
        }
      }
    }
    final rawVotes = data['votes'];
    final votes = <String, int>{
      '👏': 0,
      '🔥': 0,
      '💩': 0,
    };
    if (rawVotes is Map) {
      votes['👏'] = int.tryParse('${rawVotes['👏']}') ?? 0;
      votes['🔥'] = int.tryParse('${rawVotes['🔥']}') ?? 0;
      votes['💩'] = int.tryParse('${rawVotes['💩']}') ?? 0;
    }
    final current = data['current'] is Map
        ? Map<String, dynamic>.from(data['current'] as Map)
        : <String, dynamic>{};
    final paused = data['paused'] == true;
    if (mounted) {
      setState(() {
        _queue = queue;
        _votes = votes;
        _qrUrl = '${data['qr_url'] ?? ''}';
        _session = data['session'] == true;
        if (_scoreboard.isNotEmpty) {
          _scoreboard = Map<String, dynamic>.from(_scoreboard)
            ..['votes'] = votes;
        }
        if ('${current['user'] ?? ''}'.isNotEmpty) {
          _currentSinger = '${current['user']}';
          if (_currentTrackName.isEmpty) {
            _currentTrackName = '${current['song'] ?? ''}';
          }
        }
      });
    }
    if (paused != _paused && _lyricsMs.isNotEmpty) {
      if (paused) {
        unawaited(_pause(fromHost: true));
      } else {
        unawaited(_resume(fromHost: true));
      }
    }
  }

  void _showScoreboard(Map<String, dynamic> data) {
    unawaited(_player.stop());
    if (!mounted) return;
    setState(() {
      _lyricsMs.clear();
      _lyricKeys = const [];
      _scoreboard = data;
      _paused = false;
      _countdown = 0;
      _status = "Calificación";
    });
  }

  Future<void> _clearStandby() async {
    final path = _standby?.mp3Path;
    _standby = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  Future<void> _downloadStandby(Map<String, dynamic> data) async {
    try {
      await _clearStandby();
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/edge_standby_${DateTime.now().millisecondsSinceEpoch}.mp3';
      await _dio.download(data['mp3_url'], path);
      final lrcResponse = await _dio.get(data['lrc_url']);
      _standby = _StandbyCartridge(
        mp3Path: path,
        mp3Url: '${data['mp3_url']}',
        trackName: '${data['track_name']}',
        singer: '${data['singer']}',
        rawLrc: lrcResponse.data.toString(),
      );
    } catch (e) {
      debugPrint("🔴 PRELOAD: $e");
    }
  }

  Future<void> _execute(Map<String, dynamic> data) async {
    final standby = _standby;
    if (standby != null &&
        (standby.trackName == data['track_name'] ||
            standby.mp3Url == data['mp3_url'])) {
      await _player.stop();
      if (_localMp3Path != null && _localMp3Path != standby.mp3Path) {
        try {
          final stale = File(_localMp3Path!);
          if (stale.existsSync()) stale.deleteSync();
        } catch (_) {}
      }
      _localMp3Path = standby.mp3Path;
      _standby = null;
      _parseLrcPayload(standby.trackName, standby.singer, standby.rawLrc);
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _scoreboard = {};
          _paused = false;
        });
      }
      await _player.open(Media(_localMp3Path!));
      await _player.play();
      return;
    }
    await _downloadAndPlay(data);
  }

  Future<void> _downloadAndPlay(Map<String, dynamic> data) async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _status = "Descargando pista al TV...";
      _scoreboard = {};
      _paused = false;
      _lastProgressShown = -1;
    });

    await _garbageCollect();

    try {
      final dir = await getTemporaryDirectory();
      _localMp3Path =
          '${dir.path}/edge_track_${DateTime.now().millisecondsSinceEpoch}.mp3';

      // Descarga atómica a la memoria flash del TV
      await _dio.download(
        data['mp3_url'],
        _localMp3Path!,
        onReceiveProgress: (count, total) {
          if (total == -1 || !mounted) return;
          final progress = count / total;
          if ((progress - _lastProgressShown).abs() < 0.08) return;
          _lastProgressShown = progress;
          setState(() => _downloadProgress = progress);
        },
      );

      final lrcResponse = await _dio.get(data['lrc_url']);
      _parseLrcPayload(
        data['track_name'],
        data['singer'],
        lrcResponse.data.toString(),
      );

      if (mounted) setState(() => _isDownloading = false);

      // Ejecución física directa por HDMI
      await _player.open(Media(_localMp3Path!));
      await _player.play();
    } catch (e) {
      debugPrint("🔴 DIO ERROR: $e");
      if (mounted) {
        setState(() {
          _isDownloading = false;
          // 🛡️ Mostramos el error real en pantalla para depuración
          _status = "Error descargando: $e";
        });
      }
    }
  }

  void _parseLrcPayload(String trackName, String singer, String rawLrc) {
    final Map<Duration, String> newLyrics = {};
    final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (var line in rawLrc.split('\n')) {
      final match = timeRegex.firstMatch(line);
      if (match != null) {
        final int min = int.parse(match.group(1)!);
        final int sec = int.parse(match.group(2)!);
        final String msStr = match.group(3)!;
        final int ms = msStr.length == 2
            ? int.parse(msStr) * 10
            : int.parse(msStr);

        final text = match.group(4)!.trim();
        if (text.isNotEmpty) {
          newLyrics[Duration(minutes: min, seconds: sec, milliseconds: ms)] =
              text;
        }
      }
    }

    if (mounted) {
      setState(() {
        _currentTrackName = trackName;
        _currentSinger = singer;
        _lyricsMs = newLyrics;
        _lyricKeys = newLyrics.keys.toList();
        _activeIndex = 0;
        _countdown = 0;
        _lastTickMs = 0;
      });
    }

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  // 🧠 CORE: Sincronización Matemática Cero Latencia (Local Audio Engine)
  void _setupAudioListener() {
    _positionSub = _player.stream.position.listen((pos) {
      if (!mounted || _lyricsMs.isEmpty || _paused || _scoreboard.isNotEmpty) {
        return;
      }
      final posMs = pos.inMilliseconds;
      if ((posMs - _lastTickMs).abs() < 220) return;
      _lastTickMs = posMs;
      _currentPosition = pos;

      final keys = _lyricKeys;
      if (keys.isEmpty) return;
      int nextIndex = keys.indexWhere((k) => k > _currentPosition);

      // 1. Motor de Cuenta Regresiva
      int newCountdown = 0;
      if (nextIndex != -1) {
        final nextTime = keys[nextIndex];
        final diffMs = (nextTime - _currentPosition).inMilliseconds;

        bool isLargeGap = (nextIndex == 0);
        if (!isLargeGap && nextIndex > 0) {
          final prevTime = keys[nextIndex - 1];
          if ((nextTime - prevTime).inMilliseconds > 5000 &&
              (_currentPosition - prevTime).inMilliseconds > 1000) {
            isLargeGap = true;
          }
        }

        if (isLargeGap && diffMs <= 4000 && diffMs > 0) {
          newCountdown = (diffMs / 1000).ceil();
        }
      }

      int newIndex = nextIndex == -1 ? keys.length - 1 : nextIndex - 1;
      if (newIndex < 0) newIndex = 0;
      if (newIndex == _activeIndex && newCountdown == _countdown) return;

      final scroll = newIndex != _activeIndex;
      setState(() {
        _countdown = newCountdown;
        _activeIndex = newIndex;
      });

      if (scroll && _scrollController.hasClients) {
          const itemHeight = 120.0;
          double targetOffset = 0.0;

          try {
            final viewportHeight = _scrollController.position.viewportDimension;
            targetOffset =
                (_activeIndex * itemHeight) -
                (viewportHeight / 2) +
                (itemHeight / 2);

            if (targetOffset < 0) targetOffset = 0;
            final maxScroll = _scrollController.position.maxScrollExtent;
            if (targetOffset > maxScroll) targetOffset = maxScroll;
          } catch (_) {
            targetOffset = _activeIndex * itemHeight; // Fallback
          }

          _scrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _completedSub?.cancel();
    _player.dispose();
    _channel?.sink.close();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Row(
        children: [
          Expanded(flex: 7, child: _buildStage()),
          const VerticalDivider(width: 1, color: Colors.white10),
          SizedBox(width: 360, child: _buildSidebar()),
        ],
      ),
    );
  }

  Widget _buildStage() {
    if (_scoreboard.isNotEmpty) {
      return Center(child: _buildTvScoreboard());
    }
    if (_isDownloading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF39FF14)),
            const SizedBox(height: 24),
            Text(
              'Preparando pista... ${(_downloadProgress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Color(0xFF39FF14), fontSize: 22),
            ),
          ],
        ),
      );
    }
    if (_lyricsMs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isConnected ? Icons.mic_external_on : Icons.wifi_off,
              size: 88,
              color: _isConnected ? const Color(0xFF39FF14) : Colors.redAccent,
            ),
            const SizedBox(height: 20),
            Text(
              _status,
              style: const TextStyle(color: Colors.white54, fontSize: 22),
            ),
          ],
        ),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        ListView.builder(
          controller: _scrollController,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(
            vertical: MediaQuery.of(context).size.height / 2.8,
          ),
          itemCount: _lyricsMs.length,
          itemBuilder: (context, index) {
            final entry = _lyricsMs.entries.elementAt(index);
            final isActive = index == _activeIndex;
            return SizedBox(
              height: 110,
              child: Center(
                child: Text(
                  entry.value,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive
                        ? const Color(0xFF39FF14)
                        : (index < _activeIndex
                              ? Colors.white24
                              : Colors.white60),
                    fontSize: isActive ? 58 : 40,
                    fontWeight: isActive ? FontWeight.w900 : FontWeight.normal,
                  ),
                ),
              ),
            );
          },
        ),
        if (_countdown > 0)
          Text(
            '$_countdown',
            style: const TextStyle(
              fontSize: 180,
              fontWeight: FontWeight.w900,
              color: Color(0xFF39FF14),
            ),
          ),
        Positioned(
          bottom: 24,
          left: 24,
          right: 24,
          child: Text(
            _paused
                ? 'PAUSA — $_currentSinger'
                : '🎤 $_currentSinger — ${_currentTrackName.replaceAll(RegExp(r'\.mp3$|\.webm$|_K\.mp3$'), '')}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF00FFFF),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    return ColoredBox(
      color: const Color(0xFF101010),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                const Text(
                  'ESCANEA PARA CANTAR',
                  style: TextStyle(
                    color: Color(0xFF39FF14),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 10),
                if (_qrUrl.isNotEmpty)
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(data: _qrUrl, size: 196),
                  )
                else
                  const Text(
                    'Esperando QR del orquestador…',
                    style: TextStyle(color: Colors.white38),
                  ),
                if (_qrUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _qrUrl,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF00FFFF),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(color: Colors.white10),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _scoreChip('👏', _votes['👏'] ?? 0, const Color(0xFF00FFFF)),
                _scoreChip('🔥', _votes['🔥'] ?? 0, const Color(0xFFFF3366)),
                _scoreChip('💩', _votes['💩'] ?? 0, const Color(0xFFFFAA00)),
              ],
            ),
          ),
          const Divider(color: Colors.white10),
          const Padding(
            padding: EdgeInsets.all(10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'SIGUIENTES EN LA COLA',
                style: TextStyle(
                  color: Color(0xFF39FF14),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Expanded(
            child: _queue.isEmpty
                ? const Center(
                    child: Text(
                      'Cola vacía',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    itemCount: _queue.length,
                    itemBuilder: (context, index) {
                      final item = _queue[index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          item['user'] ?? '',
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          item['song'] ?? '',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: IconButton(
                          tooltip: 'Borrar',
                          onPressed: () =>
                              _send({'type': 'TV_REMOVE', 'index': index}),
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Color(0xFFFF3366),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  autofocus: true,
                  onPressed: _lyricsMs.isEmpty
                      ? null
                      : () => _paused ? _resume() : _pause(),
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                  label: Text(_paused ? 'REANUDAR' : 'PAUSA'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A1A1A),
                    foregroundColor: const Color(0xFF00FFFF),
                    minimumSize: const Size(0, 48),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _session
                      ? () => _send({'type': 'TV_SKIP'})
                      : null,
                  icon: const Icon(Icons.skip_next),
                  label: const Text('SIGUIENTE'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF39FF14),
                    foregroundColor: Colors.black,
                    minimumSize: const Size(0, 48),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () {
                    _send({'type': 'TV_SESSION_END'});
                    unawaited(_leaveSession());
                  },
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('FINALIZAR'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF3366),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvScoreboard() {
    final votes = Map<String, dynamic>.from(_scoreboard['votes'] ?? {});
    final nextSinger = '${_scoreboard['next_singer'] ?? ''}';
    final nextTrack = '${_scoreboard['next_track'] ?? ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${_scoreboard['singer']} — ${_scoreboard['track_name']}',
          style: const TextStyle(
            color: Color(0xFF00FFFF),
            fontSize: 36,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        const Text(
          'CALIFICACIÓN',
          style: TextStyle(color: Colors.white54, letterSpacing: 4, fontSize: 18),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _scoreChip('👏', votes['👏'] ?? 0, const Color(0xFF00FFFF)),
            _scoreChip('🔥', votes['🔥'] ?? 0, const Color(0xFFFF3366)),
            _scoreChip('💩', votes['💩'] ?? 0, const Color(0xFFFFAA00)),
          ],
        ),
        const SizedBox(height: 36),
        Text(
          nextSinger.isEmpty
              ? 'Cola vacía. Esperando la siguiente pista…'
              : 'Siguiente: $nextSinger — $nextTrack',
          style: const TextStyle(color: Color(0xFF39FF14), fontSize: 22),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _scoreChip(String emoji, Object count, Color color) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 48)),
        const SizedBox(height: 8),
        Text(
          '$count',
          style: TextStyle(
            color: color,
            fontSize: 36,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
