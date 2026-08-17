import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'dart:io';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: TestSetIn()),
  );
}

class TestSetIn extends StatefulWidget {
  const TestSetIn({super.key});

  @override
  State<TestSetIn> createState() => _TestSetInState();
}

class _TestSetInState extends State<TestSetIn> {
  late final Player _player;

  // 🛠️ MOCK DEL AUTO-MASTER: Fingimos que la BD nos dio un SET IN de 25 segundos (25000 ms)
  final int _customCueInMs = 25000;
  String _status = "Motor libmpv en espera...";

  // 🛠️ FIX ARQUITECTÓNICO: Flag de estado para garantizar un único salto determinista
  bool _hasSkippedIn = false;

  @override
  void initState() {
    super.initState();
    _player = Player();

    _player.stream.position.listen((Duration pos) {
      final posMs = pos.inMilliseconds;

      // ==========================================
      // ALGORITMO AISLADO: ESCUDO DE ENTRADA (SET IN)
      // ==========================================
      if (_customCueInMs > 0 && !_hasSkippedIn) {
        // En cuanto el stream reporta posición y estamos antes de la marca, saltamos.
        if (posMs < _customCueInMs) {
          _hasSkippedIn = true; // Bloqueo atómico
          _player.seek(Duration(milliseconds: _customCueInMs));

          setState(() {
            _status =
                "✅ Salto ejecutado correctamente a los ${_customCueInMs}ms";
          });
          debugPrint("🟢 TEST: Salto forzado al SET IN -> $_customCueInMs ms");
        }
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _playAerosmith() async {
    const String path =
        r"C:\Users\ASUS\Music\ReGenial\80s Ingles\Aerosmith - Walk This Way.mp3";

    if (!File(path).existsSync()) {
      setState(() => _status = "⚠️ Archivo no encontrado en:\n$path");
      return;
    }

    // Reset del flag por si se le vuelve a dar Play
    _hasSkippedIn = false;

    setState(() => _status = "Iniciando pista...");
    await _player.open(Media(path), play: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        title: const Text(
          "Sandbox: Prueba de SET IN",
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _playAerosmith,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF39FF14),
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 20,
                ),
              ),
              child: const Text(
                "PROBAR AEROSMITH (SET IN)",
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontFamily: 'Consolas',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
