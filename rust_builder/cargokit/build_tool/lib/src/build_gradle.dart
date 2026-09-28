/// This is copied from Cargokit (which is the official way to use it currently)
/// Details: https://fzyzcjy.github.io/flutter_rust_bridge/manual/integrate/builtin

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'artifacts_provider.dart';
import 'builder.dart';
import 'environment.dart';
import 'options.dart';
import 'target.dart';

final log = Logger('build_gradle');

class BuildGradle {
  BuildGradle({required this.userOptions});

  final CargokitUserOptions userOptions;

  Future<void> build() async {
    final targets = Environment.targetPlatforms.map((arch) {
      final target = Target.forFlutterName(arch);
      if (target == null) {
        throw Exception(
            "Unknown darwin target or platform: $arch, ${Environment.darwinPlatformName}");
      }
      return target;
    }).toList();

    final environment = BuildEnvironment.fromEnvironment(isAndroid: true);
    final provider =
        ArtifactProvider(environment: environment, userOptions: userOptions);
    final artifacts = await provider.getArtifacts(targets);

    var copied = 0;
    for (final target in targets) {
      final libs = artifacts[target];
      if (libs == null || libs.isEmpty) {
        throw Exception(
            'Cargokit produced no artifacts for $target. '
            'Expected lib${environment.crateInfo.packageName}.so');
      }
      final outputDir = path.join(Environment.outputDir, target.android!);
      Directory(outputDir).createSync(recursive: true);

      for (final lib in libs) {
        if (lib.type == AritifactType.dylib) {
          File(lib.path).copySync(path.join(outputDir, lib.finalFileName));
          copied += 1;
          log.info('Copied ${lib.finalFileName} -> $outputDir');
        }
      }
    }
    if (copied == 0) {
      throw Exception(
          'Cargokit built Android targets but copied no .so '
          '(lib${environment.crateInfo.packageName}.so).');
    }
  }
}
