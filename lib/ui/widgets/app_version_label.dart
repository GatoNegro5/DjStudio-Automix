import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Versión instalada (la del pubspec = la del tag de GitHub), en texto chico.
/// Sirve para saber de qué build habla una captura.
class AppVersionLabel extends StatelessWidget {
  const AppVersionLabel({super.key});

  static final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        if (info == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Text(
            'v${info.version}',
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white38,
              letterSpacing: 0.6,
            ),
          ),
        );
      },
    );
  }
}
