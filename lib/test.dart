import 'dart:io';

void main() {
  // 🛠️ RUTA DIRECTA AL ARCHIVO DE LETRA (.lrc)
  // Asegúrate de que este archivo exista en tu carpeta.
  final path =
      r"C:\Users\ASUS\Music\ReGenial\80s Ingles\Aerosmith - Walk This Way.lrc";

  final file = File(path);
  if (!file.existsSync()) {
    print("🔴 Archivo LRC no encontrado: $path");
    return;
  }

  final content = file.readAsStringSync();
  final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

  int? firstMs;
  int? lastMs;

  final lines = content.split('\n');
  for (var line in lines) {
    final match = regex.firstMatch(line);
    if (match != null) {
      final text = match.group(4)!.trim().toLowerCase();

      // ======================================================
      // 🛠️ FILTRO ANTI-BASURA: Ignora metadata de sincronización
      // ======================================================
      bool isGarbage =
          text.isEmpty ||
          text.startsWith('by:') ||
          text.startsWith('artist:') ||
          text.startsWith('title:') ||
          text.contains('synced') ||
          text.contains('lyric') ||
          text.contains('www.') ||
          text.length < 3;

      if (!isGarbage) {
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        int ms = int.parse(match.group(3)!);
        if (match.group(3)!.length == 2) ms *= 10;
        final totalMs = (min * 60000) + (sec * 1000) + ms;

        firstMs ??= totalMs; // Captura la primera sílaba REAL
        lastMs = totalMs; // Sobreescribe hasta la última
      }
    }
  }

  print("\n==== DIAGNÓSTICO DE BOUNDING BOX ====");
  if (firstMs != null) {
    print("🗣️ Primera palabra cantada REAL en: $firstMs ms");
    print("🛑 Última palabra cantada REAL en: $lastMs ms");

    int cueIn = firstMs - 5000;
    if (cueIn < 0) cueIn = 0;

    print("-----------------------------------------");
    print("🟢 SET IN CALCULADO (Cue In): $cueIn ms");
    print("-----------------------------------------\n");
  } else {
    print("⚠️ No se encontraron vocales válidas en el archivo LRC.");
  }
}
