import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

class RadioWorkspace extends StatefulWidget {
  const RadioWorkspace({super.key});

  @override
  State<RadioWorkspace> createState() => _RadioWorkspaceState();
}

class _RadioWorkspaceState extends State<RadioWorkspace> {
  late final Player _player;
  final TextEditingController _controller = TextEditingController();

  String _status = "Esperando semilla de radio...";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // 🛠️ MODO ZERO-DISK: Configuramos libmpv sin salida de video para optimizar RAM
    _player = Player(configuration: const PlayerConfiguration(vo: 'null'));
  }

  @override
  void dispose() {
    _player.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startRadioStream(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _status = "Buscando túnel de audio para '$query'...";
    });

    try {
      // 1. Obtener ID del primer resultado algorítmico vía yt-dlp
      final searchRes = await Process.run('yt-dlp', [
        'ytsearch1:$query',
        '--print',
        '%(id)s|%(title)s',
      ]);

      if (searchRes.exitCode != 0)
        throw Exception("Fallo en búsqueda algorítmica.");

      final line = searchRes.stdout.toString().trim();
      if (line.isEmpty) throw Exception("Cero resultados encontrados.");

      final parts = line.split('|');
      final videoId = parts[0];
      final title = parts.length > 1 ? parts[1] : videoId;

      setState(() {
        _status = "Transmitiendo Zero-Disk en RAM:\n$title";
      });

      // 2. Transmisión Directa: Inyección de URL. libmpv maneja el stream sin I/O físico.
      final directUrl = 'https://www.youtube.com/watch?v=$videoId';
      await _player.open(Media(directUrl), play: true);

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _status = "Error Crítico de Conexión: $e";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Radio YT (Zero-Disk Streaming)",
            style: TextStyle(
              color: Colors.purpleAccent,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            "Motor de inyección directa a RAM. Cero archivos descargados.",
            style: TextStyle(color: Colors.white54, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 50),
          TextField(
            controller: _controller,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText:
                  "Género, Artista o Semilla (Ej. Mix Salsa, Rock de los 80)",
              labelStyle: TextStyle(color: Colors.white54),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.purpleAccent),
              ),
              prefixIcon: Icon(Icons.radio, color: Colors.white54),
            ),
            onSubmitted: (val) => _isLoading ? null : _startRadioStream(val),
          ),
          const SizedBox(height: 30),
          ElevatedButton(
            onPressed: _isLoading
                ? null
                : () => _startRadioStream(_controller.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purpleAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 20),
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.black,
                      strokeWidth: 2,
                    ),
                  )
                : const Text(
                    "CONECTAR ESTACIÓN",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
          ),
          const SizedBox(height: 50),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              fontFamily: 'Consolas',
            ),
          ),
          const SizedBox(height: 40),
          Center(
            child: IconButton(
              icon: const Icon(
                Icons.stop_circle_outlined,
                color: Colors.redAccent,
                size: 70,
              ),
              onPressed: () {
                _player.stop();
                setState(() => _status = "Transmisión detenida.");
              },
              tooltip: "Cortar Transmisión",
            ),
          ),
        ],
      ),
    );
  }
}
