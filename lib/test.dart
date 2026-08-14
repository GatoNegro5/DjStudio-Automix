import 'dart:io';
import 'dart:convert';

void main() {
  print("🧪 INICIANDO SANDBOX: I/O AUDIT DEL ARCHIVO LRC\n");

  final audioPath =
      r"C:\Users\ASUS\Music\DjStudio_LAB\Los Dukes - 20 Años Menos.m4a";
  final regex = RegExp(r'\.(mp3|m4a|webm|wav|flac)$', caseSensitive: false);
  final lrcPath = audioPath.replaceAll(regex, '.lrc');

  print("📂 Buscando letra física en: $lrcPath");

  final lrcFile = File(lrcPath);

  if (!lrcFile.existsSync()) {
    print("\n🔴 FATAL: El archivo .lrc NO EXISTE físicamente en el disco.");
    print(
      "-> El proceso de rescate nunca lo creó para esta canción, o se borró en el proceso atómico.",
    );
    return;
  }

  print("🟢 ¡Archivo encontrado! Procediendo a decodificación UTF-8...\n");

  try {
    final content = lrcFile.readAsLinesSync(encoding: utf8);

    if (content.isEmpty) {
      print(
        "⚠️ ALERTA: El archivo existe pero está de tamaño 0 bytes (VACÍO).",
      );
      return;
    }

    print("📜 VOLCADO DE MEMORIA (${content.length} líneas detectadas):");
    print("-" * 50);
    for (var i = 0; i < content.length; i++) {
      if (i >= 20) {
        print(
          "... [+ ${content.length - 20} líneas adicionales omitidas en consola]",
        );
        break;
      }
      print(content[i]);
    }
    print("-" * 50);
    print("✅ I/O Audit exitoso. Los datos están intactos en el disco.");
  } catch (e) {
    print("\n💥 CRASH DE DECODIFICACIÓN I/O: $e");
  }
}
