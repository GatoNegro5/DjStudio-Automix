import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

void main() => runApp(const MaterialApp(home: NativeShareSandbox()));

class NativeShareSandbox extends StatefulWidget {
  const NativeShareSandbox({super.key});

  @override
  State<NativeShareSandbox> createState() => _NativeShareSandboxState();
}

class _NativeShareSandboxState extends State<NativeShareSandbox> {
  String _log = "Esperando selección de archivo...";

  Future<void> _pickAndShareFile() async {
    try {
      setState(() => _log = "Abriendo selector nativo...");

      // Abre el buscador de archivos del OS (Filtro explícito para Windows)
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'aac', 'flac'],
      );

      if (result != null && result.files.single.path != null) {
        String filePath = result.files.single.path!;
        setState(
          () => _log =
              "Archivo cargado: $filePath\nDelegando al Sistema Operativo...",
        );

        // Delega la carga al OS (Lanza Quick Share / Nearby Share / AirDrop)
        final xFile = XFile(filePath);
        final shareResult = await Share.shareXFiles([
          xFile,
        ], text: 'Te paso este MP3 desde DjStudio');

        setState(
          () => _log += "\n✅ Estado de Acción OS: ${shareResult.status.name}",
        );
      } else {
        setState(() => _log = "Acción cancelada por el usuario.");
      }
    } catch (e) {
      setState(() => _log = "🔴 ERROR NATIVO: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text(
          "Sandbox 2: OS Native Share",
          style: TextStyle(color: Color(0xFF00FFFF)),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.share, color: Color(0xFF00FFFF), size: 100),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              onPressed: _pickAndShareFile,
              icon: const Icon(Icons.audio_file),
              label: const Text("SELECCIONAR MP3 Y ENVIAR AL CELULAR"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FFFF),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 15,
                ),
              ),
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(15),
              color: Colors.black,
              width: 500,
              height: 150,
              child: SingleChildScrollView(
                child: Text(
                  _log,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
