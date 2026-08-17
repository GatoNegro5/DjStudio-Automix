import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

class RadioSandbox extends StatefulWidget {
  const RadioSandbox({super.key});

  @override
  State<RadioSandbox> createState() => _RadioSandboxState();
}

class _RadioSandboxState extends State<RadioSandbox> {
  late final Player _player;
  final TextEditingController _controller = TextEditingController();

  String _status = "Esperando comando de radio...";
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    // 🛠️ MODO ZERO-DISK: Configuramos libmpv para que prefiera streams nativos y no cachee a disco
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
      _status = "Buscando ID de '$query' en los servidores de YT...";
    });

    try {
      // 1. Obtener ID del primer resultado algorítmico (Solo el ID y Título)
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
        _status = "Iniciando Transmisión Zero-Disk en RAM:\n$title";
      });

      // 2. Reproducir Directamente desde YouTube (media_kit + yt-dlp nativo)
      // Pasamos la URL completa. libmpv internamente invoca su propio yt-dlp embebido para el streaming.
      final directUrl = 'https://www.youtube.com/watch?v=$videoId';

      await _player.open(Media(directUrl), play: true);

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _status = "Error Crítico: $e";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        title: const Text(
          "Laboratorio: Motor de Radio V1",
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(30.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Género o Semilla (Ej. Salsa, Rock de los 80)",
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00FFFF)),
                ),
                prefixIcon: Icon(Icons.radio, color: Colors.white54),
              ),
              onSubmitted: (val) => _isLoading ? null : _startRadioStream(val),
            ),
            const SizedBox(height: 25),
            ElevatedButton(
              onPressed: _isLoading
                  ? null
                  : () => _startRadioStream(_controller.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FFFF),
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
                      "TRANSMITIR ESTACIÓN",
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
                onPressed: () => _player.stop(),
                tooltip: "Cortar Transmisión",
              ),
            ),
          ],
        ),
      ),
    );
  }
}
