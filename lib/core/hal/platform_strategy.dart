import 'dart:io';

abstract class PlatformMixStrategy {
  String get hifiFilter;
  String getSessionPath();
  bool get supportsHighFidelityMastering;
}

class WindowsMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'loudnorm=I=-14:TP=-1.5:LRA=11,aresample=resampler=soxr:precision=28,crystalizer=i=2.0,bass=g=3:f=60,extrastereo=m=1.15';

  @override
  String getSessionPath() {
    final dir = Directory(
      '${Platform.environment['USERPROFILE']}\\Music\\DjPlaylists',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}\\player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => true;
}

class MacOsMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter =>
      'loudnorm=I=-14:TP=-1.5:LRA=11,aresample=resampler=soxr:precision=28,crystalizer=i=2.0,bass=g=3:f=60,extrastereo=m=1.15';

  @override
  String getSessionPath() {
    final dir = Directory('${Platform.environment['HOME']}/Music/DjPlaylists');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => true;
}

class AndroidMixStrategy implements PlatformMixStrategy {
  @override
  String get hifiFilter => 'loudnorm=I=-14:TP=-1.5:LRA=11,bass=g=3:f=60';

  @override
  String getSessionPath() {
    final dir = Directory('/storage/emulated/0/Music/DjPlaylists');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/_player_session.json';
  }

  @override
  bool get supportsHighFidelityMastering => false;
}

class MixStrategyFactory {
  static PlatformMixStrategy getStrategy() {
    if (Platform.isWindows) return WindowsMixStrategy();
    if (Platform.isMacOS) return MacOsMixStrategy();
    if (Platform.isAndroid || Platform.isIOS) return AndroidMixStrategy();
    return WindowsMixStrategy();
  }
}
