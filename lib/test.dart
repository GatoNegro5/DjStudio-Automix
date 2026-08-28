import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: RadioSandbox()),
  );
}

class RadioSandbox extends StatefulWidget {
  const RadioSandbox({super.key});

  @override
  State<RadioSandbox> createState() => _RadioSandboxState();
}

class _RadioSandboxState extends State<RadioSandbox> {
  late final Player _player;
  final yt = YoutubeExplode();
  HttpServer? _localProxy;
  String _log = "Motor de Radio en espera...";

  @override
  void initState() {
    super.initState();
    _player = Player(configuration: const PlayerConfiguration(vo: 'null'));

    _player.stream.error.listen((error) {
      debugPrint("🔴 [MEDIA_KIT ERROR]: $error");
    });
  }

  @override
  void dispose() {
    _player.dispose();
    yt.close();
    _localProxy?.close(force: true); // Destruimos el servidor al salir
    super.dispose();
  }

  Future<void> _testRadio() async {
    setState(() => _log = "1. Resolviendo nodos en Dart...");

    try {
      final query = '80s classic rock hits audio';
      final searchResults = await yt.search.search(query);

      if (searchResults.isEmpty) {
        setState(() => _log = "⚠️ Cero resultados de YouTube.");
        return;
      }

      final video = searchResults.first;
      setState(
        () => _log =
            "2. Obtenido: ${video.title}\n3. Extrayendo manifiesto DASH/AAC...",
      );

      final manifest = await yt.videos.streamsClient.getManifest(video.id);
      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();

      setState(() => _log = "4. Levantando Servidor Local (Proxy RAM)...");

      // =========================================================
      // 🛠️ ARQUITECTURA SENIOR: EL LOCAL PROXY
      // =========================================================
      await _localProxy?.close(force: true);
      // Abrimos un puerto dinámico (0) en localhost
      _localProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      _localProxy!.listen((HttpRequest request) async {
        try {
          // Dart descarga el flujo de YouTube burlando el Fingerprinting
          final stream = yt.videos.streamsClient.get(audioStreamInfo);

          request.response.headers.contentType = ContentType('audio', 'mp4');
          request.response.statusCode = 200;

          // Bombeamos el flujo binario a nuestra propia respuesta HTTP
          await stream.pipe(request.response);
        } catch (e) {
          debugPrint("🔴 [PROXY ERROR]: $e");
          request.response.statusCode = 500;
          request.response.close();
        }
      });

      setState(() => _log = "5. Bóveda abierta. Engañando a libmpv...");

      // libmpv se conecta a nuestro servidor interno. ¡Jaque mate al 403!
      final localUrl = 'http://127.0.0.1:${_localProxy!.port}';
      await _player.open(Media(localUrl), play: true);
      await _player.setVolume(100.0);

      setState(() => _log = "▶️ SONANDO EN VIVO:\n${video.title}");
    } catch (e) {
      setState(() => _log = "🔴 Falla Crítica: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: _testRadio,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 20,
                  ),
                ),
                child: const Text(
                  "PROBAR SEÑAL ROCK 80s",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 30),
              Text(
                _log,
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 16,
                  fontFamily: 'Consolas',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              IconButton(
                onPressed: () {
                  _player.stop();
                  setState(() => _log = "Transmisión detenida.");
                },
                icon: const Icon(
                  Icons.stop_circle,
                  color: Colors.redAccent,
                  size: 60,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
