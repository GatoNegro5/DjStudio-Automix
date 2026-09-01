import 'dart:async';
import 'package:flutter/foundation.dart';
import 'core_metadata.dart';
import 'core_dsp.dart';
import 'core_nlp.dart';
import 'core_bpm.dart';

class PipelineState {
  final int total;
  final int current;
  final String fileName;
  final String moduleStatus;
  final bool isIdle;

  PipelineState({
    required this.total,
    required this.current,
    required this.fileName,
    required this.moduleStatus,
    required this.isIdle,
  });
}

class PipelineController {
  final BpmEngine _bpm = BpmEngine();
  final MetadataEngine _m1 = MetadataEngine();
  final DspEngine _dsp = DspEngine();
  final NlpEngine _nlp = NlpEngine();

  final StreamController<PipelineState> _streamController =
      StreamController<PipelineState>.broadcast();
  Stream<PipelineState> get stream => _streamController.stream;

  bool _isProcessing = false;
  bool _abortRequested = false; // <-- Bandera de interrupción en memoria

  /// Gatillo para detener la cola de forma segura
  void abortPipeline() {
    if (_isProcessing) {
      _abortRequested = true;
      debugPrint(
        "🛑 [PIPELINE] Señal de aborto recibida. Esperando cierre atómico...",
      );
    }
  }

  Future<void> runBatch(List<String> filePaths) async {
    if (_isProcessing) return;
    _isProcessing = true;
    _abortRequested = false;

    final int total = filePaths.length;
    int current = 0;

    for (String path in filePaths) {
      if (_abortRequested) {
        debugPrint(
          "🛑 [PIPELINE] Cola abortada por el usuario en la pista $current.",
        );
        break;
      }

      current++;
      final fileName = path.split(RegExp(r'[\\/]')).last;

      _emit(total, current, fileName, "🔍 Validando...");

      try {
        bool isOptimized = await _dsp.checkWatermark(path);

        if (!isOptimized) {
          if (_abortRequested) break;
          _emit(total, current, fileName, "⚙️ M1: Limpiando Metadatos");
          await _m1.processFile(path);

          if (_abortRequested) break;
          _emit(total, current, fileName, "🔊 M3: Ajustando Volumen (LUFS)");
          await _dsp.normalizeLUFS(path);

          if (_abortRequested) break;
          _emit(total, current, fileName, "✂️ M2: Cortando Silencios");
          await _dsp.autoTrim(path);

          if (_abortRequested) break;
          _emit(total, current, fileName, "🔐 M3: Sellando Archivo");
          await _dsp.injectWatermark(path);
        } else {
          debugPrint("⏭️ [BYPASS DSP] $fileName ya está optimizado en audio.");
        }

        if (_abortRequested) break;
        _emit(
          total,
          current,
          fileName,
          "📝 M5: Obteniendo Letras Sincronizadas",
        );
        await _nlp.fetchLyrics(path);
        if (_abortRequested) break;
        _emit(total, current, fileName, "🥁 M4: Calculando BPM");
        await _bpm.processBpm(path);
      } catch (e) {
        debugPrint("🔴 [PIPELINE FATAL] Error en $fileName: $e");
      }
    }

    _isProcessing = false;
    _abortRequested = false;

    _streamController.add(
      PipelineState(
        total: total,
        current: current,
        fileName: "-",
        moduleStatus: "Idle",
        isIdle: true,
      ),
    );
    debugPrint("🟢 [PIPELINE LIBERADO] Motor en reposo.");
  }

  void _emit(int total, int current, String fileName, String status) {
    _streamController.add(
      PipelineState(
        total: total,
        current: current,
        fileName: fileName,
        moduleStatus: status,
        isIdle: false,
      ),
    );
  }

  void dispose() {
    _streamController.close();
  }
}
