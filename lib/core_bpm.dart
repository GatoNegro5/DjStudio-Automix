import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';

class BpmEngine {
  /// M4: Detección e Inyección de BPM (Multi-Plataforma ARM/x86)
  Future<void> processBpm(String filePath) async {
    final file = File(filePath);
    final fileName = file.uri.pathSegments.last;

    // 1. PRE-CHECK: Evaluar Tag TBPM (Cross-Platform)
    bool hasTag = await _checkWatermark(filePath);
    if (hasTag) {
      debugPrint("🟢 [M4 BYPASS] Tag de BPM ya existente en: $fileName");
      return;
    }

    debugPrint("⏳ [M4] Iniciando análisis rítmico: $fileName");
    int? finalBpm = await _extractBpm(filePath);

    // 2. FALLBACK WINDOWS EXCLUSIVO (SoundStretch exe)
    if (finalBpm == null && Platform.isWindows) {
      debugPrint(
        "🟡 [M4 FALLBACK] Windows detectado. Escalando a binario secundario...",
      );
      finalBpm = await _resolveBpmWithSoundStretch(filePath);
    }

    // 3. INYECCIÓN ATÓMICA
    if (finalBpm != null && finalBpm > 0) {
      final tempFilePath =
          "${file.parent.path}${Platform.pathSeparator}temp_bpm.mp3";
      bool success = await _injectBpmTag(filePath, tempFilePath, finalBpm);

      if (success) {
        await _atomicReplace(file, File(tempFilePath));
        debugPrint(
          "🟢 [M4 ÉXITO] Etiqueta TBPM=$finalBpm inyectada atómicamente.",
        );
      } else {
        debugPrint("🔴 [M4 ERROR I/O] Fallo al inyectar ID3.");
      }
    } else {
      debugPrint(
        "🔴 [M4 ABORTADO] No se pudo determinar el BPM en esta plataforma.",
      );
    }
  }

  // ==========================================
  // CAPA INFRAESTRUCTURA (Cross-Platform wrappers)
  // ==========================================

  Future<bool> _checkWatermark(String filePath) async {
    if (Platform.isWindows || Platform.isLinux) {
      final process = await Process.run('ffmpeg', [
        '-i',
        filePath,
        '-f',
        'ffmetadata',
        '-',
      ]);
      final log = process.stderr.toString() + process.stdout.toString();
      return log.contains('TBPM=');
    } else {
      final session = await FFmpegKit.execute('-i "$filePath" -f ffmetadata -');
      final log = await session.getLogsAsString();
      return log.contains('TBPM=');
    }
  }

  Future<int?> _extractBpm(String filePath) async {
    String logText = "";

    if (Platform.isWindows || Platform.isLinux) {
      final process = await Process.run('ffmpeg', [
        '-i',
        filePath,
        '-af',
        'bpm',
        '-f',
        'null',
        '-',
      ]);
      logText = process.stderr.toString();
    } else {
      // Android / iOS: Enrutamiento al C++ wrapper
      final session = await FFmpegKit.execute(
        '-i "$filePath" -af bpm -f null /dev/null',
      );
      final logs = await session.getLogsAsString();
      logText = logs;
    }

    final bpmMatch = RegExp(r'BPM:\s*([0-9.]+)').firstMatch(logText);
    if (bpmMatch != null) {
      return double.parse(bpmMatch.group(1)!).round();
    }
    return null;
  }

  Future<bool> _injectBpmTag(String input, String output, int bpm) async {
    if (Platform.isWindows || Platform.isLinux) {
      final process = await Process.run('ffmpeg', [
        '-y',
        '-i',
        input,
        '-map',
        '0',
        '-c',
        'copy',
        '-metadata',
        'TBPM=$bpm',
        output,
      ]);
      return process.exitCode == 0;
    } else {
      final session = await FFmpegKit.execute(
        '-y -i "$input" -map 0 -c copy -metadata TBPM=$bpm "$output"',
      );
      final returnCode = await session.getReturnCode();
      return ReturnCode.isSuccess(returnCode);
    }
  }

  // --- FALLBACK EXCLUSIVO PARA WINDOWS (x86) ---
  Future<int?> _resolveBpmWithSoundStretch(String filePath) async {
    final tempDir = Directory.systemTemp;
    final exeFile = File('${tempDir.path}\\soundstretch.exe');

    if (!exeFile.existsSync()) {
      try {
        final url = Uri.parse(
          'https://github.com/ssrc-dev/soundtouch-win32/releases/latest/download/soundstretch.exe',
        );
        final response = await http
            .get(url)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          await exeFile.writeAsBytes(response.bodyBytes);
        }
      } catch (_) {
        return null;
      }
    }

    final tempWav = File('${tempDir.path}\\temp_analysis.wav');
    try {
      await Process.run('ffmpeg', ['-y', '-i', filePath, tempWav.path]);
      final process = await Process.run(exeFile.path, [tempWav.path, '-bpm']);
      if (tempWav.existsSync()) await tempWav.delete();

      final log = process.stdout.toString() + process.stderr.toString();
      final match = RegExp(r'BPM rate\s*([0-9.]+)').firstMatch(log);
      if (match != null) return double.parse(match.group(1)!).round();
    } catch (_) {
      if (tempWav.existsSync()) await tempWav.delete();
    }
    return null;
  }

  Future<void> _atomicReplace(File original, File temp) async {
    final originalPath = original.path;
    await original.delete();
    await temp.rename(originalPath);
  }
}
