import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum TvAdbTargetState { connected, discoverable, pairingRequired }

class TvAdbTarget {
  final String endpoint;
  final String name;
  final TvAdbTargetState state;
  final String? pairingEndpoint;

  const TvAdbTarget({
    required this.endpoint,
    required this.name,
    required this.state,
    this.pairingEndpoint,
  });

  String get host => endpoint.split(':').first;

  bool get canInstall => state != TvAdbTargetState.pairingRequired;

  TvAdbTarget copyWith({
    String? endpoint,
    String? name,
    TvAdbTargetState? state,
    String? pairingEndpoint,
  }) {
    return TvAdbTarget(
      endpoint: endpoint ?? this.endpoint,
      name: name ?? this.name,
      state: state ?? this.state,
      pairingEndpoint: pairingEndpoint ?? this.pairingEndpoint,
    );
  }
}

class TvAdbDeploymentService {
  Future<String> _resolveAdb() async {
    final sdkRoots = <String?>[
      Platform.environment['ANDROID_SDK_ROOT'],
      Platform.environment['ANDROID_HOME'],
      if (Platform.isWindows)
        '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk',
      if (Platform.isMacOS)
        '${Platform.environment['HOME']}/Library/Android/sdk',
    ];

    for (final root in sdkRoots.whereType<String>()) {
      final candidate = Platform.isWindows
          ? '$root\\platform-tools\\adb.exe'
          : '$root/platform-tools/adb';
      if (File(candidate).existsSync()) return candidate;
    }
    throw StateError('ADB no encontrado. Instala Android SDK Platform-Tools.');
  }

  Future<ProcessResult> _adb(List<String> arguments) async {
    final adb = await _resolveAdb();
    return Process.run(adb, arguments, runInShell: false);
  }

  Future<List<TvAdbTarget>> discover() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError(
        'La instalación ADB solo se ejecuta en escritorio.',
      );
    }

    await _adb(['start-server']);
    final targets = <String, TvAdbTarget>{};

    final devices = await _adb(['devices', '-l']);
    for (final line in const LineSplitter().convert('${devices.stdout}')) {
      final match = RegExp(r'^(\S+)\s+device\b(.*)$').firstMatch(line.trim());
      if (match == null) continue;
      final serial = match.group(1)!;
      final details = match.group(2) ?? '';
      final model = RegExp(r'\bmodel:(\S+)').firstMatch(details)?.group(1);
      if (await _isTelevision(serial)) {
        targets[serial.split(':').first] = TvAdbTarget(
          endpoint: serial,
          name: (model ?? 'Google TV').replaceAll('_', ' '),
          state: TvAdbTargetState.connected,
        );
      }
    }

    for (final service in await _readMdnsServices()) {
      final host = service.host;
      final existing = targets[host];

      if (service.isPairing) {
        targets[host] = existing == null
            ? TvAdbTarget(
                endpoint: service.endpoint,
                name: 'Google TV — requiere código',
                state: TvAdbTargetState.pairingRequired,
                pairingEndpoint: service.endpoint,
              )
            : existing.copyWith(pairingEndpoint: service.endpoint);
        continue;
      }

      if (existing == null) {
        targets[host] = TvAdbTarget(
          endpoint: service.endpoint,
          name: 'Google TV — disponible',
          state: TvAdbTargetState.discoverable,
        );
      } else if (existing.state == TvAdbTargetState.pairingRequired) {
        targets[host] = existing.copyWith(
          endpoint: service.endpoint,
          name: 'Google TV — disponible',
          state: TvAdbTargetState.discoverable,
        );
      }
    }

    if (targets.isEmpty) {
      await _scanLegacyAdb(targets);
    }

    return targets.values.toList()
      ..sort((a, b) => a.state.index.compareTo(b.state.index));
  }

  Future<List<_MdnsAdbService>> _readMdnsServices() async {
    final mdns = await _adb(['mdns', 'services']);
    final pattern = RegExp(
      r'(_adb-tls-(?:connect|pairing)\._tcp)'
      r'\D+(\d{1,3}(?:\.\d{1,3}){3})[:\s]+(\d+)',
    );
    final services = <_MdnsAdbService>[];
    for (final line in const LineSplitter().convert('${mdns.stdout}')) {
      final match = pattern.firstMatch(line.trim());
      if (match == null) continue;
      services.add(
        _MdnsAdbService(
          isPairing: match.group(1)!.contains('pairing'),
          host: match.group(2)!,
          port: match.group(3)!,
        ),
      );
    }
    return services;
  }

  Future<bool> _isTelevision(String serial) async {
    return await _probeTelevision(serial) ?? false;
  }

  /// `null` cuando ADB no devolvió la propiedad: no es una negativa.
  Future<bool?> _probeTelevision(String serial) async {
    try {
      final result = await _adb([
        '-s',
        serial,
        'shell',
        'getprop',
        'ro.build.characteristics',
      ]);
      final value = '${result.stdout}'.trim().toLowerCase();
      if (value.isEmpty) return null;
      return value.contains('tv') || value.contains('leanback');
    } catch (_) {
      return null;
    }
  }

  Future<void> _scanLegacyAdb(Map<String, TvAdbTarget> targets) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final address = interfaces
        .expand((interface) => interface.addresses)
        .map((item) => item.address)
        .where((item) => item.split('.').length == 4)
        .firstOrNull;
    if (address == null) return;

    final octets = address.split('.');
    final subnet = '${octets[0]}.${octets[1]}.${octets[2]}';
    for (int start = 1; start <= 254; start += 32) {
      final probes = <Future<void>>[];
      for (int host = start; host < start + 32 && host <= 254; host++) {
        final ip = '$subnet.$host';
        if (ip == address) continue;
        probes.add(_probeLegacyEndpoint(ip, targets));
      }
      await Future.wait(probes);
    }
  }

  Future<void> _probeLegacyEndpoint(
    String ip,
    Map<String, TvAdbTarget> targets,
  ) async {
    try {
      final socket = await Socket.connect(
        ip,
        5555,
        timeout: const Duration(milliseconds: 220),
      );
      socket.destroy();
      targets[ip] = TvAdbTarget(
        endpoint: '$ip:5555',
        name: 'Android TV — depuración de red',
        state: TvAdbTargetState.discoverable,
      );
    } catch (_) {}
  }

  Future<String> pair({required String endpoint, required String code}) async {
    final result = await _adb(['pair', endpoint, code.trim()]);
    final output = '${result.stdout}\n${result.stderr}'.trim();
    if (result.exitCode != 0 ||
        !output.toLowerCase().contains('successfully paired')) {
      throw StateError(
        output.isEmpty
            ? 'No se pudo emparejar. Revisa que el IP:puerto sea el del '
                  'diálogo “Vincular con dispositivo” y que siga abierto.'
            : output,
      );
    }
    return output;
  }

  Future<void> buildInstallAndLaunch({
    required TvAdbTarget target,
    required void Function(String message) onProgress,
  }) async {
    var endpoint = target.endpoint;
    if (target.state != TvAdbTargetState.connected) {
      onProgress('Conectando con $endpoint…');
      if (!await _tryConnect(endpoint)) {
        final refreshed = await _resolveConnectEndpoint(target.host);
        if (refreshed == null || refreshed == endpoint) {
          throw StateError(
            'ADB no pudo conectar con $endpoint.\n'
            'Esta TV exige emparejarse antes: en la TV abre Depuración '
            'inalámbrica → Emparejar dispositivo y pulsa la llave 🔑 de esta '
            'lista con el IP:PUERTO y el código de 6 dígitos que aparecen en '
            'pantalla. Ese puerto NO es el mismo que el de conexión.',
          );
        }
        onProgress('Puerto renovado, reintentando en $refreshed…');
        if (!await _tryConnect(refreshed)) {
          throw StateError(
            'ADB no pudo conectar con $refreshed. Empareja la TV de nuevo.',
          );
        }
        endpoint = refreshed;
      }
    }

    final isTelevision = await _probeTelevision(endpoint);
    if (isTelevision == false) {
      throw StateError(
        '$endpoint no es un dispositivo TV/Leanback. Elige otro destino.',
      );
    }
    if (isTelevision == null) {
      onProgress('Aviso: ADB no confirmó Leanback; continuando…');
    }

    final project = _resolveTvProject();
    final apk = File(
      '${project.path}${Platform.pathSeparator}build${Platform.pathSeparator}'
      'app${Platform.pathSeparator}outputs${Platform.pathSeparator}'
      'flutter-apk${Platform.pathSeparator}app-release.apk',
    );

    if (_requiresBuild(project, apk)) {
      onProgress('Compilando DJ Studio Karaoke TV…');
      final build = await Process.start(
        Platform.isWindows ? 'flutter.bat' : 'flutter',
        ['build', 'apk', '--release'],
        workingDirectory: project.path,
        runInShell: true,
      );
      final stdoutSub = build.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onProgress);
      final stderrSub = build.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onProgress);
      final buildExit = await build.exitCode;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (buildExit != 0 || !apk.existsSync()) {
        throw StateError('Falló la compilación del APK para Google TV.');
      }
    } else {
      onProgress('APK release vigente; omitiendo recompilación.');
    }

    onProgress('Instalando APK en ${target.name}…');
    final install = await _adb([
      '-s',
      endpoint,
      'install',
      '-r',
      '-d',
      apk.path,
    ]);
    final installOutput = '${install.stdout}\n${install.stderr}'.trim();
    if (install.exitCode != 0 ||
        !installOutput.toLowerCase().contains('success')) {
      throw StateError(installOutput);
    }

    onProgress('Abriendo DJ Studio Karaoke en la TV…');
    await _adb([
      '-s',
      endpoint,
      'shell',
      'monkey',
      '-p',
      'com.example.djstudio_tv',
      '-c',
      'android.intent.category.LEANBACK_LAUNCHER',
      '1',
    ]);
    onProgress('Instalación terminada. Revisa la pantalla de la TV.');
  }

  Future<bool> _tryConnect(String endpoint) async {
    final connect = await _adb(['connect', endpoint]);
    if (connect.exitCode != 0) return false;
    final output = '${connect.stdout}\n${connect.stderr}'.toLowerCase();
    return output.contains('connected to') &&
        !output.contains('failed to connect');
  }

  /// El puerto TLS de conexión rota tras cada emparejamiento o reinicio.
  Future<String?> _resolveConnectEndpoint(String host) async {
    for (final service in await _readMdnsServices()) {
      if (!service.isPairing && service.host == host) return service.endpoint;
    }
    return null;
  }

  bool _requiresBuild(Directory project, File apk) {
    if (!apk.existsSync()) return true;
    final apkModified = apk.lastModifiedSync();
    final sourcePaths = [
      'pubspec.yaml',
      'lib${Platform.pathSeparator}main.dart',
      'android${Platform.pathSeparator}app${Platform.pathSeparator}'
          'build.gradle.kts',
      'android${Platform.pathSeparator}app${Platform.pathSeparator}src'
          '${Platform.pathSeparator}main${Platform.pathSeparator}'
          'AndroidManifest.xml',
    ];
    return sourcePaths.any((relative) {
      final source = File('${project.path}${Platform.pathSeparator}$relative');
      return source.existsSync() &&
          source.lastModifiedSync().isAfter(apkModified);
    });
  }

  Directory _resolveTvProject() {
    final roots = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final root in roots) {
      var cursor = root;
      for (int depth = 0; depth < 10; depth++) {
        final candidate = Directory(
          '${cursor.path}${Platform.pathSeparator}djstudio_tv',
        );
        if (File(
          '${candidate.path}${Platform.pathSeparator}pubspec.yaml',
        ).existsSync()) {
          return candidate;
        }
        if (cursor.parent.path == cursor.path) break;
        cursor = cursor.parent;
      }
    }
    throw StateError(
      'No se encontró djstudio_tv/. Ejecuta desde el repositorio de DJ Studio.',
    );
  }
}

class _MdnsAdbService {
  final bool isPairing;
  final String host;
  final String port;

  const _MdnsAdbService({
    required this.isPairing,
    required this.host,
    required this.port,
  });

  String get endpoint => '$host:$port';
}
