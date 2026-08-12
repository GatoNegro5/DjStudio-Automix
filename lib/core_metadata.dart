import 'dart:io';
import 'package:flutter/foundation.dart';
// Enlace a la memoria C++
import 'package:djstudio_player/src/rust/api/core_metadata.dart' as rust_meta;

class MetadataEngine {
  Future<void> processFile(String filePath) async {
    // Veto Técnico: Protegemos el Kernel Móvil de bloqueos masivos
    if (Platform.isAndroid || Platform.isIOS) {
      debugPrint(
        "⚠️ [M1 RUST BYPASS] Masterización bloqueada en Sandbox móvil.",
      );
      return;
    }

    debugPrint("⏳ [M1 RUST] Inyectando tags ID3v2 y limpiando nomenclatura...");

    try {
      final result = await rust_meta.processMetadata(inputPath: filePath);

      final newFilename = result[0];
      final artist = result[1];
      final title = result[2];

      debugPrint(
        "🟢 [M1 RUST ÉXITO] Archivo masterizado: $artist - $title -> [$newFilename]",
      );
    } catch (e) {
      debugPrint("🔴 [M1 RUST FATAL]: $e");
    }
  }
}
