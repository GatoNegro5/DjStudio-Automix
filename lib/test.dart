import 'dart:io';

void main() async {
  final url = 'https://www.youtube.com/watch?v=WaSQSvSg5sQ';
  final tempDir = Directory.systemTemp;
  final ytdlpPath = Platform.isWindows
      ? '${tempDir.path}\\yt-dlp.exe'
      : 'yt-dlp';

  print("🧪 INICIANDO SANDBOX DE I/O PARA YT-DLP...");
  print("Ruta del binario: $ytdlpPath");

  // Matriz de estrategias para evadir el DRM y el experimento SABR
  final strategies = [
    {
      'name': 'Spoofing iOS + Web',
      'args': [
        '--rm-cache-dir',
        '-f',
        'bestaudio',
        '--extractor-args',
        'youtube:player_client=ios,web',
        '-o',
        '${tempDir.path}\\test1.%(ext)s',
        url,
      ],
    },
    {
      'name': 'Spoofing TV + Web',
      'args': [
        '--rm-cache-dir',
        '-f',
        'bestaudio',
        '--extractor-args',
        'youtube:player_client=tv,web',
        '-o',
        '${tempDir.path}\\test2.%(ext)s',
        url,
      ],
    },
    {
      'name': 'Default Client (Fuerza bruta m4a)',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=default',
        '-o',
        '${tempDir.path}\\test3.%(ext)s',
        url,
      ],
    },
  ];

  for (var i = 0; i < strategies.length; i++) {
    final strategy = strategies[i];
    print("\n🚀 Probando Estrategia ${i + 1}: ${strategy['name']}");

    final result = await Process.run(
      ytdlpPath,
      strategy['args'] as List<String>,
    );

    if (result.exitCode == 0) {
      print("✅ ÉXITO. La estrategia ${i + 1} evadió el bloqueo.");
      print("Log de salida:\n${result.stdout}");
      return; // Detenemos el test al encontrar el vector funcional
    } else {
      print("🔴 FALLO. Bloqueo detectado.");
      print("Error arrojado:\n${result.stderr}");
    }
  }

  print(
    "\n💀 Todas las estrategias fallaron. Se requiere actualización del binario yt-dlp.",
  );
}
