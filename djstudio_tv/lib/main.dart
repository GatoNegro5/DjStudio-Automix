import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

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

  @override
  void initState() {
    super.initState();
    _loadSavedIp();
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('server_ip') ?? '';
    if (savedIp.isNotEmpty) {
      _ipController.text = savedIp;
    }
    setState(() => _isLoading = false);
  }

  void _connect() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server_ip', ip);

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => TeleprompterScreen(serverIp: ip)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

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
              const Text(
                "Ingresa la IP que muestra el Orquestador en Windows",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
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

class _TeleprompterScreenState extends State<TeleprompterScreen> {
  WebSocketChannel? _channel;
  final ScrollController _scrollController = ScrollController();
  final Player _player = Player();
  final Dio _dio = Dio();
  StreamSubscription? _positionSub;

  String _status = "Conectando...";
  bool _isConnected = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  String _currentTrackName = "";
  String _currentSinger = "";
  Map<Duration, String> _lyricsMs = {};

  Duration _currentPosition = Duration.zero;
  int _activeIndex = 0;
  int _countdown = 0;

  String? _localMp3Path;

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
    _setupAudioListener();
  }

  void _connectWebSocket() {
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
            if (data['type'] == 'EDGE_EXECUTE') {
              _downloadAndPlay(data);
            } else if (data['type'] == 'EDGE_STOP') {
              _stopAndClear();
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
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _status = "Conexión perdida. Reintentando en 5s...";
    });
    _stopAndClear();
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _connectWebSocket();
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

  void _stopAndClear() async {
    await _garbageCollect();
    if (mounted) {
      setState(() {
        _lyricsMs.clear();
        _currentTrackName = "";
        _currentSinger = "";
        _status = "Esperando pista desde la PC...";
        _countdown = 0;
      });
    }
  }

  Future<void> _downloadAndPlay(Map<String, dynamic> data) async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _status = "Descargando pista al TV...";
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
          if (total != -1 && mounted) {
            setState(() => _downloadProgress = count / total);
          }
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
        _activeIndex = 0;
        _countdown = 0;
      });
    }

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  // 🧠 CORE: Sincronización Matemática Cero Latencia (Local Audio Engine)
  void _setupAudioListener() {
    _positionSub = _player.stream.position.listen((pos) {
      if (!mounted || _lyricsMs.isEmpty) return;
      _currentPosition = pos;

      final keys = _lyricsMs.keys.toList();
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

      if (newCountdown != _countdown) {
        setState(() => _countdown = newCountdown);
      }

      // 2. Cálculo Estricto de Viewport (Cero Jitter)
      int newIndex = nextIndex == -1 ? keys.length - 1 : nextIndex - 1;
      if (newIndex < 0) newIndex = 0;

      if (newIndex != _activeIndex) {
        setState(() => _activeIndex = newIndex);

        if (_scrollController.hasClients) {
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
      }
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _player.dispose();
    _channel?.sink.close();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isConnected || (_lyricsMs.isEmpty && !_isDownloading)) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isConnected ? Icons.mic_external_on : Icons.wifi_off,
                size: 100,
                color: _isConnected
                    ? const Color(0xFF39FF14)
                    : Colors.redAccent,
              ),
              const SizedBox(height: 30),
              Text(
                _status,
                style: const TextStyle(fontSize: 24, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    if (_isDownloading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFF39FF14)),
              const SizedBox(height: 30),
              Text(
                "Preparando pista... ${(_downloadProgress * 100).toStringAsFixed(0)}%",
                style: const TextStyle(fontSize: 24, color: Color(0xFF39FF14)),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        alignment: Alignment.center,
        children: [
          Container(color: const Color(0xFF030303)),

          ListView.builder(
            controller: _scrollController,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(
              vertical: MediaQuery.of(context).size.height / 2.5,
            ),
            itemCount: _lyricsMs.length,
            itemBuilder: (context, index) {
              final entry = _lyricsMs.entries.elementAt(index);
              final isActive = index == _activeIndex;
              final isPassed = index < _activeIndex;

              return Container(
                height: 120,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    color: isActive
                        ? const Color(0xFF39FF14)
                        : (isPassed ? Colors.white24 : Colors.white60),
                    fontSize: isActive ? 65 : 45,
                    fontWeight: isActive ? FontWeight.w900 : FontWeight.normal,
                    shadows: isActive
                        ? [
                            const Shadow(
                              color: Color(0xFF39FF14),
                              blurRadius: 20,
                            ),
                          ]
                        : [],
                  ),
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
            },
          ),

          if (_countdown > 0)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _countdown > 0 ? 1.0 : 0.0,
              child: Container(
                padding: const EdgeInsets.all(80),
                decoration: BoxDecoration(
                  color: const Color(0xFF030303).withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF39FF14), width: 8),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF39FF14).withValues(alpha: 0.4),
                      blurRadius: 80,
                    ),
                  ],
                ),
                child: Text(
                  _countdown.toString(),
                  style: const TextStyle(
                    fontSize: 220,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF39FF14),
                    shadows: [Shadow(color: Color(0xFF39FF14), blurRadius: 30)],
                  ),
                ),
              ),
            ),

          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.mic, color: Color(0xFF00FFFF), size: 24),
                const SizedBox(width: 15),
                Text(
                  "$_currentSinger - ${_currentTrackName.replaceAll(RegExp(r'\.mp3$|\.webm$|_K\.mp3$'), '')}",
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
