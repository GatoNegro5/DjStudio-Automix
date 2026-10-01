import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../providers/automix_provider.dart';
import '../providers/directory_provider.dart';
import 'voice_folder_match.dart';

final voiceLaunchProvider = Provider<VoiceLaunch>((ref) {
  final launch = VoiceLaunch(ref);
  ref.onDispose(launch.cancel);
  return launch;
});

/// Un aviso al abrir, una escucha, cola Automix + `loadContextAndPlay`.
class VoiceLaunch {
  VoiceLaunch(this._ref);

  final Ref _ref;
  bool _opened = false;
  bool _alive = true;
  SpeechToText? _speech;
  FlutterTts? _tts;
  Completer<void>? _listenDone;
  bool _listenArmed = false;
  bool _heardListening = false;
  String _heard = '';
  bool _audible = false;
  bool _reportedTtsFailure = false;

  void cancel() {
    _alive = false;
    _finishListen();
    final speech = _speech;
    if (speech != null && speech.isListening) {
      speech.stop();
    }
    final tts = _tts;
    if (tts != null) {
      tts.stop();
    }
  }

  Future<void> open() async {
    if (_opened) return;
    _opened = true;
    try {
      await _flow();
    } catch (e, stack) {
      debugPrint('🔴 [VOICE] $e\n$stack');
      if (_alive && !_audible) {
        await _reportTtsFailure();
      }
    }
  }

  Future<void> _flow() async {
    // El aviso no espera al reconocedor. En Android `initialize` lanza
    // o no vuelve si no hay servicio, y ese espera dejaba el arranque mudo.
    final foldersFuture = listLibraryFolders(musicLibraryRoot());
    final greeted = await _say('¿Qué pongo?');
    if (!_alive) return;
    if (!greeted) {
      await _reportTtsFailure();
      return;
    }

    if (!await _micGranted()) {
      await _say('Sin el micrófono no puedo oír qué pongo.');
      return;
    }
    if (!_alive) return;

    final speech = SpeechToText();
    _speech = speech;
    final ready = await _recognizerReady(speech);
    if (!_alive) return;
    if (!ready) {
      await _say('No pude activar el reconocimiento de voz.');
      return;
    }

    final localeId = await _spanishLocale(speech)
        .timeout(const Duration(seconds: 4), onTimeout: () => null);
    final folders = await foldersFuture;
    if (!_alive) return;

    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!_alive) return;

    final String heard;
    try {
      heard = await _listenOnce(speech, localeId, folders);
    } catch (e) {
      debugPrint('🔴 [VOICE] listen $e');
      await _say('No pude activar el reconocimiento de voz.');
      return;
    }
    if (!_alive) return;

    final decision = decideSpokenFolder(folders, heard);
    final folder = decision.folder;
    if (folder == null) {
      await _say(_missLine(decision.miss ?? VoiceMiss.noMatch));
      return;
    }
    await _queueFolderAndPlay(folder.path);
  }

  Future<bool> _micGranted() async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      return true;
    }
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted || status.isLimited) return true;
      status = await Permission.microphone.request();
      return status.isGranted || status.isLimited;
    } catch (e) {
      debugPrint('🔴 [VOICE] mic $e');
      return false;
    }
  }

  Future<void> _reportTtsFailure() async {
    if (_reportedTtsFailure || !_alive) return;
    _reportedTtsFailure = true;
    await _say('No pude usar la voz.');
  }

  /// `true` solo si el motor aceptó la frase y arrancó o terminó.
  /// Un `speak` que devuelve 0, lanza, o no vuelve no se traga.
  Future<bool> _say(String text) async {
    if (!_alive) return false;
    final tts = _tts ??= FlutterTts();
    try {
      if (await _speakOnce(tts, text)) {
        _audible = true;
        return true;
      }
    } catch (e) {
      debugPrint('🔴 [VOICE] tts $e');
    }
    if (!_alive) return false;
    _silenceTtsHandlers(tts);
    try {
      await tts.stop().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('🔴 [VOICE] tts stop $e');
    }
    if (!_alive) return false;
    try {
      final spoken = await _speakOnce(tts, text);
      if (spoken) _audible = true;
      return spoken;
    } catch (e) {
      debugPrint('🔴 [VOICE] tts $e');
      return false;
    }
  }

  Future<void> _prepareTts(FlutterTts tts) async {
    // Sin `awaitSpeakCompletion`: si la utterance falla, el plugin no
    // completa el future y el arranque se quedaba mudo.
    await tts.awaitSpeakCompletion(false);
    await tts.setVolume(1.0);
    if (Platform.isAndroid) {
      // Guía de navegación, sin pedir audio focus (`focus` queda en false).
      // Así la frase se oye y un fallo de voz no pausa la sesión reanudada.
      try {
        await tts.setAudioAttributesForNavigation();
      } catch (e) {
        debugPrint('🔴 [VOICE] tts attributes $e');
      }
    }
    await _applySpanishTts(tts);
  }

  void _silenceTtsHandlers(FlutterTts tts) {
    tts.setStartHandler(() {});
    tts.setCompletionHandler(() {});
    tts.setErrorHandler((_) {});
    tts.setCancelHandler(() {});
  }

  Future<bool> _speakOnce(FlutterTts tts, String text) async {
    final done = Completer<bool>();
    var started = false;
    void finish(bool ok) {
      if (!done.isCompleted) done.complete(ok);
    }

    tts.setStartHandler(() {
      started = true;
    });
    tts.setCompletionHandler(() => finish(true));
    tts.setErrorHandler((message) {
      debugPrint('🔴 [VOICE] tts $message');
      finish(false);
    });
    tts.setCancelHandler(() => finish(false));

    try {
      await _prepareTts(tts).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      debugPrint('🔴 [VOICE] tts prep timeout');
    } catch (e) {
      debugPrint('🔴 [VOICE] tts prep $e');
    }
    if (!_alive) return false;

    final dynamic result;
    try {
      result = await tts.speak(text).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      debugPrint('🔴 [VOICE] tts speak timeout');
      return started;
    }
    if (result != 1 && result != true) {
      debugPrint('🔴 [VOICE] tts speak rejected ($result)');
      return false;
    }
    try {
      return await done.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return started;
    }
  }

  Future<bool> _recognizerReady(SpeechToText speech) async {
    try {
      return await speech
          .initialize(
            onError: _onSpeechError,
            onStatus: _onSpeechStatus,
            options: [SpeechToText.androidNoBluetooth],
          )
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (e) {
      debugPrint('🔴 [VOICE] init $e');
      return false;
    }
  }

  Future<void> _applySpanishTts(FlutterTts tts) async {
    for (final lang in ['es-ES', 'es-MX', 'es-US', 'es']) {
      try {
        final available = await tts.isLanguageAvailable(lang);
        if (available == true || available == 1) {
          await tts.setLanguage(lang);
          return;
        }
      } catch (_) {}
    }
    try {
      await tts.setLanguage('es-ES');
    } catch (_) {}
  }

  Future<String?> _spanishLocale(SpeechToText speech) async {
    try {
      final locales = await speech.locales();
      String? esEs;
      String? esMx;
      String? any;
      for (final locale in locales) {
        final id = locale.localeId.toLowerCase().replaceAll('-', '_');
        if (id.startsWith('es_es')) {
          esEs ??= locale.localeId;
        } else if (id.startsWith('es_mx')) {
          esMx ??= locale.localeId;
        } else if (id.startsWith('es')) {
          any ??= locale.localeId;
        }
      }
      return esEs ?? esMx ?? any;
    } catch (e) {
      debugPrint('🔴 [VOICE] locales $e');
      return null;
    }
  }

  void _onSpeechStatus(String status) {
    if (!_listenArmed) return;
    if (status == 'listening') {
      _heardListening = true;
      return;
    }
    if ((status == 'done' || status == 'notListening') &&
        (_heardListening || _heard.isNotEmpty)) {
      _finishListen();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    debugPrint('🔴 [VOICE] stt ${error.errorMsg}');
    _finishListen();
  }

  void _finishListen() {
    final done = _listenDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<String> _listenOnce(
    SpeechToText speech,
    String? localeId,
    List<FolderCandidate> folders,
  ) async {
    _heard = '';
    _heardListening = false;
    _listenDone = Completer<void>();
    _listenArmed = true;
    final timer = Timer(const Duration(seconds: 12), _finishListen);
    try {
      await speech.listen(
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) _heard = words;
          if (result.finalResult) _finishListen();
        },
        listenOptions: SpeechListenOptions(
          listenMode: ListenMode.confirmation,
          partialResults: true,
          cancelOnError: true,
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 2),
          localeId: localeId,
          contextualPhrases: _biasPhrases(folders),
        ),
      );
      await _listenDone!.future;
    } finally {
      timer.cancel();
      _listenArmed = false;
    }
    if (speech.isListening) {
      await speech.stop();
    }
    return _heard.trim();
  }

  Future<void> _queueFolderAndPlay(String folderPath) async {
    if (!_alive) return;
    await _ref.read(directoryProvider.notifier).scanPath(folderPath);
    if (!_alive) return;

    final dirState = _ref.read(directoryProvider);
    final List<File> files;
    if (_samePath(dirState.currentPath, folderPath)) {
      files = List<File>.from(dirState.files);
    } else {
      files = await listLibraryAudio(folderPath);
    }
    if (files.isEmpty) {
      await _say('Esa carpeta no tiene pistas.');
      return;
    }

    final played = _ref.read(playedTracksProvider.notifier);
    for (final file in files) {
      played.removeTrack(file.path);
    }
    final queue = _ref.read(automixQueueProvider.notifier);
    queue.clearQueue();
    queue.addAll(files);
    if (!_alive) return;
    await _ref
        .read(automixProvider.notifier)
        .loadContextAndPlay(files.map((file) => file.path).toList(), 0);
  }
}

List<String> _biasPhrases(List<FolderCandidate> folders) {
  final names = <String>[];
  final seen = <String>{};
  for (final folder in folders) {
    final name = folder.name.trim();
    if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
    names.add(name);
    if (names.length >= 80) break;
  }
  return names;
}

String _missLine(VoiceMiss miss) {
  switch (miss) {
    case VoiceMiss.unheard:
      return 'No escuché ninguna carpeta.';
    case VoiceMiss.noMatch:
      return 'No encontré esa carpeta.';
    case VoiceMiss.ambiguous:
      return 'Hay varias carpetas parecidas.';
  }
}

bool _samePath(String a, String b) {
  String norm(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  return norm(a) == norm(b);
}
