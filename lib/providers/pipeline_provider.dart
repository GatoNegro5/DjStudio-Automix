import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 1. Nuevo Servicio de Infraestructura (Separación de Concerns)
class MediaProcessKiller {
  /// Ejecuta un SIGKILL a nivel OS. Úsese con precaución ya que afecta a procesos globales.
  static void executeGlobalHardAbort() {
    try {
      if (Platform.isWindows) {
        Process.run('taskkill', ['/F', '/IM', 'ffmpeg.exe']);
        Process.run('taskkill', ['/F', '/IM', 'yt-dlp.exe']);
      } else {
        Process.run('killall', ['-9', 'ffmpeg']);
        Process.run('killall', ['-9', 'yt-dlp']);
      }
    } catch (_) {}
  }
}

class PipelineState {
  final bool isIdle;
  final int current;
  final int total;
  final String fileName;
  final String moduleStatus;
  final List<String> quarantinedTracks;
  final bool isAborted; // Bandera atómica de cancelación

  PipelineState({
    this.isIdle = true,
    this.current = 0,
    this.total = 0,
    this.fileName = "",
    this.moduleStatus = "",
    this.quarantinedTracks = const [],
    this.isAborted = false,
  });

  PipelineState copyWith({
    bool? isIdle,
    int? current,
    int? total,
    String? fileName,
    String? moduleStatus,
    List<String>? quarantinedTracks,
    bool? isAborted,
  }) {
    return PipelineState(
      isIdle: isIdle ?? this.isIdle,
      current: current ?? this.current,
      total: total ?? this.total,
      fileName: fileName ?? this.fileName,
      moduleStatus: moduleStatus ?? this.moduleStatus,
      quarantinedTracks: quarantinedTracks ?? this.quarantinedTracks,
      isAborted: isAborted ?? this.isAborted,
    );
  }
}

class PipelineNotifier extends Notifier<PipelineState> {
  @override
  PipelineState build() => PipelineState();

  void updateProgress(
    int current,
    int total,
    String fileName,
    String moduleStatus,
  ) {
    if (state.isAborted) return; // Bloqueo de actualizaciones si está abortado
    state = state.copyWith(
      isIdle: false,
      current: current,
      total: total,
      fileName: fileName,
      moduleStatus: moduleStatus,
    );
  }

  void addQuarantine(String trackPath) {
    state = state.copyWith(
      quarantinedTracks: [...state.quarantinedTracks, trackPath],
    );
  }

  void clearQuarantine() {
    state = state.copyWith(quarantinedTracks: []);
  }

  // 🛠️ Freno de Emergencia (Hard Abort OS-Level)
  void abort() {
    state = state.copyWith(
      isAborted: true,
      moduleStatus: "🔴 Abortando operación... aniquilando procesos binarios.",
    );

    // Delegación estricta a la capa de infraestructura. El Notifier ya no maneja binarios.
    MediaProcessKiller.executeGlobalHardAbort();
  }

  void reset() {
    state = PipelineState(quarantinedTracks: state.quarantinedTracks);
  }
}

final pipelineProvider = NotifierProvider<PipelineNotifier, PipelineState>(
  PipelineNotifier.new,
);
