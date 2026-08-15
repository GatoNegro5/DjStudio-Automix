import 'dart:io';

void main() async {
  print("🧪 SANDBOX V2: AUDITORÍA DE BINARIO Y MATRIZ EXTENDIDA ANTI-403\n");
  final url = 'https://www.youtube.com/watch?v=my8Av7W4z9w';
  final tempDir = Directory.systemTemp;
  final ytdlpPath = Platform.isWindows
      ? '${tempDir.path}\\yt-dlp.exe'
      : 'yt-dlp';

  if (!File(ytdlpPath).existsSync()) {
    print("🔴 ERROR FATAL: El binario yt-dlp no existe en $ytdlpPath");
    return;
  }

  // 1. Auditoría de Estado
  var vResult = await Process.run(ytdlpPath, ['--version']);
  print("📌 Versión actual del motor: ${vResult.stdout.toString().trim()}");

  print("🔄 Forzando actualización del motor (Auto-Patching)...");
  await Process.run(ytdlpPath, ['-U']);
  vResult = await Process.run(ytdlpPath, ['--version']);
  print("📌 Versión tras actualización: ${vResult.stdout.toString().trim()}\n");

  // 2. Matriz de Ataque (Nuevas firmas)
  final strategies = [
    {
      'name': 'Cliente IOS (Alta prioridad)',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=ios',
        '-o',
        '${tempDir.path}\\test_ios.%(ext)s',
        url,
      ],
    },
    {
      'name': 'Cliente TV (Evasión de po-token)',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=tv',
        '-o',
        '${tempDir.path}\\test_tv.%(ext)s',
        url,
      ],
    },
    {
      'name': 'Cliente ANDROID,WEB (Fallback)',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=android,web',
        '-o',
        '${tempDir.path}\\test_web.%(ext)s',
        url,
      ],
    },
  ];

  for (var s in strategies) {
    print("🚀 Lanzando ataque con firma: ${s['name']}");
    final result = await Process.run(ytdlpPath, s['args'] as List<String>);

    if (result.exitCode == 0) {
      print("✅ VULNERABILIDAD ENCONTRADA. Bypass exitoso.\n");
      return; // Detenemos al encontrar la vía libre
    } else {
      final err = result.stderr.toString();
      final lines = err.split('\n').where((l) => l.contains('ERROR')).toList();
      print(
        "🔴 Repelido: ${lines.isNotEmpty ? lines.first : 'Error de I/O'}\n",
      );
    }
  }

  print(
    "💀 Bloqueo absoluto. Evaluar Arquitectura Alternativa (Cookies / API externa).",
  );
}
