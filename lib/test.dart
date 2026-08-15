import 'dart:io';

void main() async {
  final url = 'https://www.youtube.com/watch?v=my8Av7W4z9w';
  final tempDir = Directory.systemTemp;
  final ytdlpPath = Platform.isWindows
      ? '${tempDir.path}\\yt-dlp.exe'
      : 'yt-dlp';

  print("🧪 INICIANDO SANDBOX: FUERZA BRUTA ANTI-403");
  print("Objetivo: $url\n");

  // Matriz de firmas para evadir el DRM (SABR)
  final strategies = [
    {
      'name': '1. Cliente Default (Actual)',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=default',
        '-o',
        '${tempDir.path}\\t1.%(ext)s',
        url,
      ],
    },
    {
      'name': '2. Cliente Android_VR',
      'args': [
        '--rm-cache-dir',
        '-f',
        '140/bestaudio',
        '--extractor-args',
        'youtube:player_client=android_vr',
        '-o',
        '${tempDir.path}\\t2.%(ext)s',
        url,
      ],
    },
    {
      'name': '3. Cliente Android + Web',
      'args': [
        '--rm-cache-dir',
        '-f',
        'bestaudio',
        '--extractor-args',
        'youtube:player_client=android,web',
        '-o',
        '${tempDir.path}\\t3.%(ext)s',
        url,
      ],
    },
    {
      'name': '4. Sin Spoofing (Firma nativa de yt-dlp)',
      'args': [
        '--rm-cache-dir',
        '-f',
        'bestaudio',
        '-o',
        '${tempDir.path}\\t4.%(ext)s',
        url,
      ],
    },
  ];

  for (var i = 0; i < strategies.length; i++) {
    final strategy = strategies[i];
    print("🚀 Probando: ${strategy['name']}");

    final result = await Process.run(
      ytdlpPath,
      strategy['args'] as List<String>,
    );

    if (result.exitCode == 0) {
      print("✅ ÉXITO. Bypass logrado.");
      print("--------------------------------------------------");
      print(result.stdout.toString().split('\n').take(4).join('\n'));
      print("--------------------------------------------------\n");
      return; // Detenemos la ejecución al encontrar la firma ganadora
    } else {
      print("🔴 FALLO.");
      final stderr = result.stderr.toString().trim();
      final errorLines = stderr
          .split('\n')
          .where((l) => l.contains('ERROR') || l.contains('HTTP Error 403'))
          .toList();
      if (errorLines.isNotEmpty) {
        print("Causa: ${errorLines.last}\n");
      } else {
        print("Causa: $stderr\n");
      }
    }
  }
  print("💀 Bloqueo total. El DRM de YouTube repelió todos los ataques.");
}
