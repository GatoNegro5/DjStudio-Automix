import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() => runApp(const MaterialApp(home: QrServerSandbox()));

class QrServerSandbox extends StatefulWidget {
  const QrServerSandbox({super.key});

  @override
  State<QrServerSandbox> createState() => _QrServerSandboxState();
}

class _QrServerSandboxState extends State<QrServerSandbox> {
  HttpServer? _server;
  String _serverUrl = "Iniciando servidor...";
  String _log = "Aplicando políticas de Firewall y levantando servidor...";

  @override
  void initState() {
    super.initState();
    _bootSequence();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _bootSequence() async {
    await _ensureWindowsFirewallRule();
    await _startHttpServer();
  }

  // 🛠️ MOTOR DE AUTO-SETUP: ESCALADA DE PRIVILEGIOS Y BYPASS DE FIREWALL
  Future<void> _ensureWindowsFirewallRule() async {
    if (!Platform.isWindows) return;
    try {
      setState(() => _log = "⚙️ Auditando Windows Defender Firewall...");

      final checkCmd = await Process.run('powershell', [
        '-Command',
        'Get-NetFirewallRule -DisplayName "DjStudio Web Server" -ErrorAction SilentlyContinue',
      ]);

      if (checkCmd.stdout.toString().contains("DjStudio Web Server")) {
        setState(() => _log += "\n✅ Regla de Firewall ya existe.");
        return;
      }

      setState(
        () => _log +=
            "\n⚠️ Regla ausente. Solicitando escalada de privilegios (Acepte el popup UAC)...",
      );

      final addCmd = '''
      Start-Process powershell -Verb runAs -WindowStyle Hidden -ArgumentList "-Command New-NetFirewallRule -DisplayName 'DjStudio Web Server' -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow"
      ''';

      await Process.run('powershell', ['-Command', addCmd]);

      // Delay táctico para que el Kernel de Windows registre la regla antes del bind
      await Future.delayed(const Duration(seconds: 2));
      setState(
        () => _log += "\n✅ Excepción de Firewall inyectada exitosamente.",
      );
    } catch (e) {
      setState(() => _log += "\n🔴 Fallo inyectando regla de firewall: $e");
    }
  }

  Future<void> _startHttpServer() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      String localIp = "127.0.0.1";
      for (var interface in interfaces) {
        if (!interface.name.toLowerCase().contains('virtual') &&
            interface.name != 'lo') {
          localIp = interface.addresses.first.address;
          break;
        }
      }

      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      setState(() {
        _serverUrl = "http://$localIp:8080";
        _log +=
            "\n✅ Servidor Web corriendo en $_serverUrl\nEscanea el QR desde el celular en el WiFi.";
      });

      _server!.listen((HttpRequest request) {
        setState(
          () => _log += "\n➡️ Solicitud: ${request.method} ${request.uri.path}",
        );

        if (request.uri.path == '/') {
          _serveWebApp(request);
        } else if (request.uri.path == '/download') {
          _serveDummyMp3(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write("404 Not Found")
            ..close();
        }
      });
    } catch (e) {
      setState(() => _log += "\n🔴 ERROR LEVANTANDO SERVIDOR: $e");
    }
  }

  void _serveWebApp(HttpRequest request) {
    final html =
        '''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>DjStudio Web Transfer</title>
        <style>
          body { background: #121212; color: #fff; font-family: sans-serif; text-align: center; padding: 20px; }
          .btn { display: block; width: 100%; padding: 15px; margin: 10px 0; background: #39FF14; color: #000; text-decoration: none; font-weight: bold; border-radius: 8px; }
          .btn-blue { background: #00FFFF; }
        </style>
      </head>
      <body>
        <h2>DjStudio LAN Hub</h2>
        <p>Conectado a $_serverUrl</p>
        <a href="/download" class="btn">⬇️ Descargar MP3 de Prueba</a>
        <button class="btn btn-blue" onclick="alert('En el código final, esto abrirá el explorador del celular para enviarte el MP3.')">⬆️ Enviar MP3 a Gabriel</button>
      </body>
      </html>
    ''';

    request.response
      ..headers.contentType = ContentType.html
      ..write(html)
      ..close();
  }

  // 🛠️ FIX API DART: Header inyectado crudo como string
  void _serveDummyMp3(HttpRequest request) {
    final dummyData = List.filled(1024 * 1024 * 2, 0);
    request.response
      ..headers.contentType = ContentType('audio', 'mpeg')
      ..headers.add(
        'content-disposition',
        'attachment; filename="Pista_De_Prueba.mp3"',
      )
      ..add(dummyData)
      ..close();

    setState(() => _log += "\n✅ Archivo descargado por el cliente.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text(
          "Sandbox 1: Web Server + QR",
          style: TextStyle(color: Color(0xFF39FF14)),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_serverUrl.startsWith("http"))
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: QrImageView(
                  data: _serverUrl,
                  version: QrVersions.auto,
                  size: 250.0,
                ),
              ),
            const SizedBox(height: 20),
            Text(
              _serverUrl,
              style: const TextStyle(
                color: Color(0xFF00FFFF),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(15),
              color: Colors.black,
              width: 600,
              height: 200,
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
