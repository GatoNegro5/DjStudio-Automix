import 'dart:io';

import 'package:http/http.dart' as http;

/// Baja [url] a [targetPath].
///
/// 1) Dart (`package:http`). 2) Si falla (p. ej. `CERTIFICATE_VERIFY_FAILED`
/// en laptops con certificados raíz incompletos), en Windows reintenta con
/// `curl.exe` y luego PowerShell: ambos usan el almacén de certificados de
/// Windows. La verificación de certificados NUNCA se desactiva.
Future<void> downloadFileRobust(String url, String targetPath) async {
  Object? firstError;
  try {
    final r = await http.get(Uri.parse(url));
    if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
      await File(targetPath).writeAsBytes(r.bodyBytes);
      return;
    }
    firstError = 'HTTP ${r.statusCode}';
  } catch (e) {
    firstError = e;
  }

  if (Platform.isWindows) {
    final tmp = '$targetPath.part';
    try {
      final curl = await Process.run('curl.exe', [
        '-L',
        '--fail',
        '--silent',
        '--show-error',
        '-o',
        tmp,
        url,
      ]);
      if (curl.exitCode == 0 && _okFile(tmp)) {
        await _move(tmp, targetPath);
        return;
      }
    } catch (_) {}
    try {
      final ps = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r"$ProgressPreference='SilentlyContinue'; "
            "[Net.ServicePointManager]::SecurityProtocol = "
            "[Net.SecurityProtocolType]::Tls12; "
            "Invoke-WebRequest -UseBasicParsing -Uri '$url' -OutFile '$tmp'",
      ]);
      if (ps.exitCode == 0 && _okFile(tmp)) {
        await _move(tmp, targetPath);
        return;
      }
    } catch (_) {}
    try {
      if (File(tmp).existsSync()) File(tmp).deleteSync();
    } catch (_) {}
  }

  throw Exception(
    'No se pudo descargar $url. Revisa fecha/hora de Windows, antivirus e '
    'internet. Detalle: $firstError',
  );
}

bool _okFile(String p) {
  final f = File(p);
  return f.existsSync() && f.lengthSync() > 0;
}

Future<void> _move(String from, String to) async {
  if (File(to).existsSync()) {
    try {
      File(to).deleteSync();
    } catch (_) {}
  }
  await File(from).rename(to);
}
