import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

/// Caché propio de Live DJ (independiente de Automix): BPM por carpeta,
/// leído de `_dj_metadata.json` de la carpeta donde vive cada canción.
final Map<String, Future<Map<String, double>>> _liveDjBpmDirCache = {};

Future<Map<String, double>> _loadLiveDjBpmDir(String dir) {
  return _liveDjBpmDirCache.putIfAbsent(dir, () async {
    final out = <String, double>{};
    try {
      final f = File('$dir${Platform.pathSeparator}_dj_metadata.json');
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is num) {
              out[key.toString()] = value.toDouble();
            } else if (value is Map && value['bpm'] is num) {
              out[key.toString()] = (value['bpm'] as num).toDouble();
            }
          });
        }
      }
    } catch (_) {}
    return out;
  });
}

Future<double> _liveDjBpmFor(String path) async {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  final dir = File(path).parent.path;
  final cache = await _loadLiveDjBpmDir(dir);
  final cached = cache[name];
  if (cached != null && cached > 0) return cached;
  final match = RegExp(
    r'(?:\b|_|-)(\d{2,3}(?:\.\d+)?)\s*bpm\b',
    caseSensitive: false,
  ).firstMatch(name);
  return match != null ? double.parse(match.group(1)!) : 0.0;
}

/// BPM de la canción, mostrado a la izquierda de cada fila del Cartridge.
class LiveDjBpmBadge extends StatelessWidget {
  final String path;
  const LiveDjBpmBadge({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: FutureBuilder<double>(
        future: _liveDjBpmFor(path),
        builder: (context, snap) {
          final bpm = snap.data ?? 0.0;
          return Text(
            bpm > 0 ? bpm.round().toString() : '–',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: bpm > 0 ? Colors.white : Colors.white24,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          );
        },
      ),
    );
  }
}
