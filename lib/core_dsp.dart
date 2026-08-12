import 'dart:io';
import 'package:flutter/foundation.dart';
// Enlace a la memoria C++
import 'package:djstudio_player/src/rust/api/core_dsp.dart' as rust_dsp;

class DspEngine {
  /// M2: AutoTrim - Recorte delegado al Kernel de Rust
  Future<void> autoTrim(String filePath) async {
    // Veto Pasivo: Ignorar DSP pesado en móviles (Performance Mode)
    if (Platform.isAndroid || Platform.isIOS) {
      debugPrint(
        "⚠️ [M2 RUST BYPASS] Procesamiento bloqueado en plataforma móvil.",
      );
      return;
    }

    debugPrint(
      "⏳ [M2 RUST] Aplicando Auto-Trim: ${Uri.file(filePath).pathSegments.last}",
    );
    try {
      final success = await rust_dsp.processAutoTrim(inputPath: filePath);
      if (success) debugPrint("🟢 [M2 RUST ÉXITO] Archivo truncado.");
    } catch (e) {
      debugPrint("🔴 [M2 RUST FATAL]: $e");
    }
  }

  /// INYECCIÓN: Sella el archivo atómicamente
  Future<void> injectWatermark(String filePath) async {
    if (Platform.isAndroid || Platform.isIOS) return;

    try {
      final success = await rust_dsp.injectWatermark(inputPath: filePath);
      if (success) debugPrint("🟢 [WATERMARK RUST] Firma inyectada en ID3v2.");
    } catch (e) {
      debugPrint("🔴 [WATERMARK FATAL]: $e");
    }
  }

  /// M3: Normalización LUFS de Doble Pasada (Dual-Pass EBU R128)
  Future<void> normalizeLUFS(String filePath) async {
    if (Platform.isAndroid || Platform.isIOS) return;

    debugPrint(
      "⏳ [M3 RUST] Iniciando Doble Pasada LUFS: ${Uri.file(filePath).pathSegments.last}",
    );
    try {
      final success = await rust_dsp.normalizeLufs(inputPath: filePath);
      if (success) {
        debugPrint("🟢 [M3 RUST ÉXITO] Volumen estandarizado a -14 LUFS.");
      }
    } catch (e) {
      debugPrint("🔴 [M3 RUST FATAL]: $e");
    }
  }

  /// PRE-CHECK: Valida si la pista ya pasó por el pipeline
  Future<bool> checkWatermark(String filePath) async {
    if (Platform.isAndroid || Platform.isIOS) return false;

    try {
      return await rust_dsp.checkWatermark(inputPath: filePath);
    } catch (e) {
      debugPrint("🔴 [PRE-CHECK FATAL]: $e");
      return false;
    }
  }
}
