import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LocalCdnServer {
  HttpServer? _server;
  final int port = 55057;

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint("🟢 [CDN LOCAL] Servidor de archivos activo en puerto $port");

      _server!.listen((HttpRequest request) async {
        final filePath = request.uri.queryParameters['path'];
        if (filePath == null || filePath.isEmpty) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
          return;
        }

        final file = File(filePath);
        if (!file.existsSync()) {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
          return;
        }

        try {
          request.response.headers.contentType = ContentType(
            'application',
            'octet-stream',
          );
          request.response.headers.add(HttpHeaders.acceptRangesHeader, 'bytes');
          await file.openRead().pipe(request.response);
        } catch (e) {
          debugPrint("🔴 [CDN LOCAL] Error sirviendo archivo: $e");
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..close();
        }
      });
    } catch (e) {
      debugPrint("🔴 [CDN LOCAL FATAL] Fallo al iniciar puerto $port: $e");
    }
  }

  void stop() {
    _server?.close(force: true);
    debugPrint("🔴 [CDN LOCAL] Servidor destruido.");
  }
}

final cdnProvider = Provider<LocalCdnServer>((ref) {
  final server = LocalCdnServer();
  server.start();
  ref.onDispose(() => server.stop());
  return server;
});
