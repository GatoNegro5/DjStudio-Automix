import 'dart:io';

void main() async {
  final int port = 55055;

  try {
    print("⏳ [TRACKER] Iniciando bind en puerto $port...");
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);

    print("✅ [TRACKER] Servidor de prueba ACTIVO.");
    print("👉 Abre tu navegador e ingresa: http://localhost:$port/karaoke");

    await for (HttpRequest request in server) {
      print(
        "📡 [TRACKER] Request entrante: ${request.method} ${request.uri.path} desde ${request.connectionInfo?.remoteAddress.address}",
      );

      if (request.method == 'GET' && request.uri.path == '/karaoke') {
        const String htmlPayload = r'''
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Test Karaoke Web</title>
  <style>
    body { background: #0a0a0a; color: #39ff14; font-family: Consolas, monospace; text-align: center; padding: 50px; }
  </style>
</head>
<body>
  <h2>🎤 TEST DE SOCKETS: Módulo Karaoke</h2>
  <p>Si ves esto, el HttpServer nativo está despachando HTML correctamente.</p>
</body>
</html>
''';
        request.response
          ..headers.contentType = ContentType.html
          ..write(htmlPayload)
          ..close();
        print("✅ [TRACKER] Payload HTML despachado con código 200.");
      } else {
        request.response
          ..statusCode = 404
          ..close();
        print("⚠️ [TRACKER] 404: Ruta no implementada en el test.");
      }
    }
  } catch (e) {
    print(
      "🔴 [TRACKER FATAL ERROR]: El puerto podría estar bloqueado o en uso.",
    );
    print(e);
  }
}
