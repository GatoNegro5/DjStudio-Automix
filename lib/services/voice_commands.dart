import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:volume_controller/volume_controller.dart';

import '../core/hal/platform_strategy.dart';
import '../djiphone/iphone_library.dart';
import '../providers/automix_provider.dart';
import '../providers/directory_provider.dart';
import '../providers/livedj_provider.dart';
import '../providers/mix_formula.dart';
import 'audio_interruption.dart';
import 'voice_folder_match.dart';

// ============================================================================
// COMANDOS DE VOZ — botón de micrófono junto al título + palabra "Oye DJ".
// Un solo código para Windows, Android, macOS y iPhone.
//
// Comandos: pausa / para · play / sigue · siguiente · sube / baja volumen
// (o "volumen 40") · mezcla uno / dos / tres (Live DJ) · shuffle / secuencial
// · pon / cambia a [carpeta] · "cambia de carpeta" (pregunta cuál).
// ============================================================================

enum VoiceAction {
  pause,
  play,
  next,
  volumeUp,
  volumeDown,
  volumeSet,
  mix,
  shuffleOn,
  shuffleOff,
  folder,
  folderAsk,
  unknown,
}

class VoiceCommand {
  final VoiceAction action;

  /// Nombre de carpeta hablado (folder).
  final String arg;

  /// Porcentaje 0..100 (volumeSet) o índice 0..2 (mix).
  final int? number;

  const VoiceCommand(this.action, {this.arg = '', this.number});

  @override
  String toString() => 'VoiceCommand($action, "$arg", $number)';
}

class WakeHit {
  /// Lo dicho después de "Oye DJ" (vacío si solo dijo la palabra clave).
  final String rest;
  const WakeHit(this.rest);
}

// "oye dj" y las formas en que los reconocedores suelen escribirlo.
final RegExp _wakeRegex = RegExp(
  r'\b(?:oye|oie|oiga|hey|ey|hoy|ei)\s+'
  r'(?:dj|d\s?j|di\s?jey|di\s?yei|di\s?jei|di\s?yey|di\s?llei|dee\s?jay|'
  r'diyei|dijey|dijei)\b',
);

/// Detecta "Oye DJ" en [heard]. `null` si no aparece.
WakeHit? splitWake(String heard) {
  final t = normalizeSpoken(heard);
  final m = _wakeRegex.firstMatch(t);
  if (m == null) return null;
  return WakeHit(t.substring(m.end).trim());
}

const Set<String> _folderVerbs = {
  'pon',
  'pone',
  'poner',
  'ponme',
  'reproduce',
  'reproducir',
  'cambia',
  'cambiar',
  'cambiame',
  'carga',
  'cargar',
  'abre',
  'abrir',
  'toca',
  'tocar',
  'busca',
  'buscar',
};

const Set<String> _folderStop = {
  'la',
  'el',
  'lo',
  'a',
  'de',
  'del',
  'una',
  'un',
  'por',
  'favor',
  'carpeta',
  'carpetas',
  'musica',
};

const Map<String, int> _numberWords = {
  'cero': 0,
  'diez': 10,
  'veinte': 20,
  'treinta': 30,
  'cuarenta': 40,
  'cincuenta': 50,
  'sesenta': 60,
  'setenta': 70,
  'ochenta': 80,
  'noventa': 90,
  'cien': 100,
  'ciento': 100,
  'mitad': 50,
  'maximo': 100,
  'minimo': 0,
};

/// Interpreta una frase hablada. Función pura (se prueba sin micrófono).
VoiceCommand parseVoiceCommand(String heard) {
  final t = normalizeSpoken(heard);
  if (t.isEmpty) return const VoiceCommand(VoiceAction.unknown);
  final w = t.split(' ');
  bool has(Iterable<String> words) => w.any(words.contains);

  const upWords = {
    'sube',
    'subir',
    'subele',
    'aumenta',
    'aumentar',
    'fuerte',
    'alto',
    'mas',
  };
  const downWords = {
    'baja',
    'bajar',
    'bajale',
    'disminuye',
    'disminuir',
    'suave',
    'bajo',
    'menos',
    'despacio',
  };

  // 1) Volumen explícito.
  if (has(const {'volumen'})) {
    int? level;
    for (final token in w) {
      final n = int.tryParse(token);
      if (n != null && n >= 0 && n <= 100) {
        level = n;
        break;
      }
      if (_numberWords.containsKey(token)) {
        level = _numberWords[token];
        break;
      }
    }
    if (level != null) {
      return VoiceCommand(VoiceAction.volumeSet, number: level);
    }
    if (has(downWords)) return const VoiceCommand(VoiceAction.volumeDown);
    if (has(upWords)) return const VoiceCommand(VoiceAction.volumeUp);
    return const VoiceCommand(VoiceAction.unknown);
  }

  // 2) Tipo de mezcla (solo cuenta si trae número o nombre).
  final mentionsMix = has(const {'mezcla', 'tipo', 'formula', 'mix'});
  int? mix;
  if (has(const {'dna'})) mix = 0;
  if (has(const {'phrase', 'frase', 'fraseo'})) mix = 1;
  if (has(const {'stealth', 'sigilo', 'sigiloso'})) mix = 2;
  if (mix == null && mentionsMix) {
    if (has(const {'1', 'uno', 'una', 'primera', 'primero'})) mix = 0;
    if (has(const {'2', 'dos', 'segunda', 'segundo'})) mix = 1;
    if (has(const {'3', 'tres', 'tercera', 'tercero'})) mix = 2;
  }
  if (mix != null) return VoiceCommand(VoiceAction.mix, number: mix);

  // 3) Shuffle / secuencial.
  if (has(const {'shuffle', 'aleatorio', 'aleatoria', 'random', 'baraja'}) ||
      t.contains('al azar')) {
    return const VoiceCommand(VoiceAction.shuffleOn);
  }
  if (has(const {'secuencial', 'ordenado', 'ordenada'}) ||
      t.contains('en orden')) {
    return const VoiceCommand(VoiceAction.shuffleOff);
  }

  // 4) Carpeta: "pon X", "cambia a X", "cambia de carpeta".
  if (_folderVerbs.contains(w.first)) {
    final rest = w.sublist(1);
    final restSet = rest.toSet();
    final mentionsFolder =
        restSet.contains('carpeta') || restSet.contains('carpetas');
    const songWords = {
      'cancion',
      'canciones',
      'tema',
      'pista',
      'rola',
      'siguiente',
      'proxima',
      'proximo',
    };
    if (restSet.any(songWords.contains)) {
      return const VoiceCommand(VoiceAction.next);
    }
    if (!mentionsFolder && (restSet.contains('otra') || restSet.contains('otro'))) {
      return const VoiceCommand(VoiceAction.next);
    }
    final meaningful = rest.where((x) => !_folderStop.contains(x)).toList();
    final onlyFiller = meaningful.isEmpty || (meaningful.length == 1 && meaningful.first == 'otra');
    if (onlyFiller) {
      if (mentionsFolder) return const VoiceCommand(VoiceAction.folderAsk);
      if (w.first == 'cambia' ||
          w.first == 'cambiar' ||
          w.first == 'cambiame') {
        return const VoiceCommand(VoiceAction.next);
      }
      return const VoiceCommand(VoiceAction.play);
    }
    final name = rest.where((x) => x != 'carpeta' && x != 'carpetas').join(' ');
    return VoiceCommand(VoiceAction.folder, arg: name);
  }

  // 5) Volumen corto: "sube", "baja", "más fuerte", "más bajo".
  if (w.length <= 3) {
    if (has(const {'baja', 'bajar', 'bajale', 'disminuye', 'disminuir'}) ||
        (has(const {'mas'}) && has(const {'bajo', 'suave', 'despacio'})) ||
        has(const {'menos'})) {
      return const VoiceCommand(VoiceAction.volumeDown);
    }
    if (has(const {'sube', 'subir', 'subele', 'aumenta', 'aumentar'}) ||
        (has(const {'mas'}) && has(const {'fuerte', 'alto'}))) {
      return const VoiceCommand(VoiceAction.volumeUp);
    }
  }

  // 6) Siguiente.
  if (has(const {
    'siguiente',
    'proxima',
    'proximo',
    'salta',
    'saltar',
    'next',
    'adelante',
    'otra',
    'pasa',
  })) {
    return const VoiceCommand(VoiceAction.next);
  }

  // 7) Pausa / para.
  if (has(const {
    'pausa',
    'pausar',
    'pausalo',
    'deten',
    'detente',
    'detener',
    'stop',
    'calla',
    'callate',
  })) {
    return const VoiceCommand(VoiceAction.pause);
  }
  if (w.length <= 3 && has(const {'para', 'parar', 'paralo'})) {
    return const VoiceCommand(VoiceAction.pause);
  }

  // 8) Play.
  if (w.length <= 4 &&
      has(const {
        'play',
        'sigue',
        'sigamos',
        'continua',
        'continuar',
        'reanuda',
        'reanudar',
        'dale',
        'empieza',
        'empezar',
        'inicia',
        'iniciar',
        'arranca',
        'arrancar',
        'ponla',
        'ponlo',
      })) {
    return const VoiceCommand(VoiceAction.play);
  }

  return const VoiceCommand(VoiceAction.unknown);
}

// ============================================================================
// ESTADO + SERVICIO
// ============================================================================

class VoiceState {
  final bool listening;
  final bool wake;
  final bool unavailable;
  final String message;

  const VoiceState({
    this.listening = false,
    this.wake = false,
    this.unavailable = false,
    this.message = '',
  });

  VoiceState copyWith({
    bool? listening,
    bool? wake,
    bool? unavailable,
    String? message,
  }) {
    return VoiceState(
      listening: listening ?? this.listening,
      wake: wake ?? this.wake,
      unavailable: unavailable ?? this.unavailable,
      message: message ?? this.message,
    );
  }
}

enum _Engine { automix, livedj }

final voiceCommandsProvider = NotifierProvider<VoiceCommands, VoiceState>(
  VoiceCommands.new,
);

class VoiceCommands extends Notifier<VoiceState> {
  bool _alive = true;
  SpeechToText? _speech;
  bool _ready = false;
  String? _locale;

  Completer<void>? _done;
  String _heard = '';
  bool _sawListening = false;
  String? _lastError;
  void Function(String words, bool isFinal)? _onWords;

  int Function()? _routeReader;
  Timer? _messageTimer;

  bool _loopRunning = false;
  bool _wakeListening = false;
  bool _pauseWake = false;

  List<FolderCandidate> _folders = const [];
  DateTime _foldersAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  VoiceState build() {
    ref.onDispose(() {
      _alive = false;
      _messageTimer?.cancel();
      _finish();
    });
    return VoiceState(wake: _readWakeSetting());
  }

  /// Cada pantalla principal indica en qué módulo está (0 Automix, 5 Live DJ)
  /// para saber a qué motor obedece la voz cuando nada suena.
  void attachRoute(int Function() reader) {
    _routeReader = reader;
    if (state.wake) unawaited(_wakeLoop());
  }

  // --------------------------------------------------------------------------
  // Botón
  // --------------------------------------------------------------------------

  Future<void> tapMic() async {
    if (state.listening) {
      await _abortListen();
      return;
    }
    _pauseWake = true;
    try {
      await _abortListen();
      for (var i = 0; i < 30 && _wakeListening; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!await _ensureSpeech()) return;
      _clickSound();
      await _listenCommandAndRun();
    } finally {
      _pauseWake = false;
    }
  }

  Future<void> toggleWake() => setWake(!state.wake);

  Future<void> setWake(bool on) async {
    if (on && !await _ensureSpeech()) {
      state = state.copyWith(wake: false);
      _writeWakeSetting(false);
      return;
    }
    state = state.copyWith(wake: on);
    _writeWakeSetting(on);
    if (on) {
      _flash(
        'Palabra clave "Oye DJ" activada',
        ms: 4500,
      );
      unawaited(_wakeLoop());
    } else {
      _flash('Palabra clave desactivada');
      await _abortListen();
    }
  }

  // --------------------------------------------------------------------------
  // Reconocimiento
  // --------------------------------------------------------------------------

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
      debugPrint('🔴 [VOZ] permiso mic $e');
      return false;
    }
  }

  Future<bool> _ensureSpeech() async {
    if (_ready) return true;
    if (!await _micGranted()) {
      state = state.copyWith(unavailable: true);
      _flash('Sin permiso de micrófono');
      return false;
    }
    final speech = _speech ??= SpeechToText();
    var ok = false;
    try {
      ok = await speech
          .initialize(
            onError: _onError,
            onStatus: _onStatus,
            options: [SpeechToText.androidNoBluetooth],
          )
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (e) {
      debugPrint('🔴 [VOZ] init $e');
    }
    if (!ok) {
      state = state.copyWith(unavailable: true);
      _flash('Voz no disponible en este equipo', ms: 5000);
      return false;
    }
    _locale = await _spanishLocale(speech)
        .timeout(const Duration(seconds: 4), onTimeout: () => null);
    _ready = true;
    state = state.copyWith(unavailable: false);
    return true;
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
    } catch (_) {
      return null;
    }
  }

  void _onStatus(String status) {
    if (_done == null) return;
    if (status == 'listening') {
      _sawListening = true;
      return;
    }
    if ((status == 'done' || status == 'notListening') &&
        (_sawListening || _heard.isNotEmpty)) {
      _finish();
    }
  }

  void _onError(SpeechRecognitionError error) {
    _lastError = error.errorMsg;
    debugPrint('🔴 [VOZ] stt ${error.errorMsg}');
    _finish();
  }

  void _finish() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> _abortListen() async {
    _finish();
    try {
      final speech = _speech;
      if (speech != null && speech.isListening) await speech.cancel();
    } catch (_) {}
  }

  /// Una escucha. Devuelve lo oído (vacío si nada).
  Future<String> _listen({
    required int listenSec,
    required int pauseSec,
    required ListenMode mode,
    void Function(String words, bool isFinal)? onWords,
    List<String>? phrases,
  }) async {
    final speech = _speech!;
    _heard = '';
    _sawListening = false;
    _onWords = onWords;
    final done = Completer<void>();
    _done = done;
    markVoiceFocusActivity();
    final timer = Timer(Duration(seconds: listenSec + 4), _finish);
    try {
      await speech.listen(
        onResult: (result) {
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) _heard = words;
          _onWords?.call(words, result.finalResult);
          if (result.finalResult) _finish();
        },
        listenOptions: SpeechListenOptions(
          listenMode: mode,
          partialResults: true,
          cancelOnError: true,
          listenFor: Duration(seconds: listenSec),
          pauseFor: Duration(seconds: pauseSec),
          localeId: _locale,
          contextualPhrases: phrases,
        ),
      );
      await done.future;
    } finally {
      timer.cancel();
      _onWords = null;
      _done = null;
    }
    try {
      if (speech.isListening) await speech.stop();
    } catch (_) {}
    markVoiceFocusActivity();
    return _heard.trim();
  }

  void _clickSound() {
    try {
      SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  /// Escucha una orden, la ejecuta y muestra el resultado.
  Future<void> _listenCommandAndRun() async {
    state = state.copyWith(listening: true, message: 'Escuchando…');
    _messageTimer?.cancel();
    String heard = '';
    try {
      heard = await _listen(
        listenSec: 8,
        pauseSec: 2,
        mode: ListenMode.confirmation,
      );
    } catch (e) {
      debugPrint('🔴 [VOZ] escucha $e');
    } finally {
      state = state.copyWith(listening: false);
    }
    if (!_alive) return;
    if (heard.isEmpty) {
      _flash('No te escuché');
      return;
    }
    await _handleText(heard);
  }

  // --------------------------------------------------------------------------
  // Palabra clave "Oye DJ"
  // --------------------------------------------------------------------------

  Future<void> _wakeLoop() async {
    if (_loopRunning) return;
    _loopRunning = true;
    var wait = const Duration(milliseconds: 500);
    try {
      while (state.wake && _alive) {
        if (_pauseWake || state.listening) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        if (!await _ensureSpeech()) {
          await setWake(false);
          break;
        }
        _lastError = null;
        String? early;
        Timer? debounce;
        var text = '';
        _wakeListening = true;
        try {
          text = await _listen(
            listenSec: 45,
            pauseSec: 4,
            mode: ListenMode.dictation,
            onWords: (words, isFinal) {
              debounce?.cancel();
              final hit = splitWake(words);
              if (hit == null) return;
              // No esperar los 4 s de silencio: si la frase ya se estabilizó,
              // se ejecuta (la orden llega en la misma frase o se pregunta).
              debounce = Timer(
                Duration(milliseconds: hit.rest.isEmpty ? 1400 : 900),
                () {
                  early = hit.rest;
                  _finish();
                },
              );
            },
          );
        } catch (e) {
          _lastError = 'exception';
          debugPrint('🔴 [VOZ] wake $e');
        } finally {
          debounce?.cancel();
          _wakeListening = false;
        }
        if (!state.wake || !_alive) break;
        if (_pauseWake) continue;

        final String? cmd = early ?? splitWake(text)?.rest;
        if (cmd != null) {
          wait = const Duration(milliseconds: 500);
          await _abortListen();
          if (cmd.isEmpty) {
            _clickSound();
            await _listenCommandAndRun();
          } else {
            await _handleText(cmd);
          }
        } else if (_lastError == 'error_permission' ||
            _lastError == 'error_language_not_supported' ||
            _lastError == 'error_language_unavailable') {
          _flash('Palabra clave no disponible: ${_lastError!}', ms: 6000);
          await setWake(false);
          break;
        } else if (_lastError == 'error_busy' ||
            _lastError == 'error_client' ||
            _lastError == 'exception') {
          final next = wait * 2;
          wait = next > const Duration(seconds: 8)
              ? const Duration(seconds: 8)
              : next;
        } else {
          wait = const Duration(milliseconds: 500);
        }
        await Future<void>.delayed(wait);
      }
    } finally {
      _loopRunning = false;
    }
  }

  // --------------------------------------------------------------------------
  // Ejecución
  // --------------------------------------------------------------------------

  Future<void> _handleText(String heard) async {
    final cmd = parseVoiceCommand(heard);
    debugPrint('🎙️ [VOZ] "$heard" → $cmd');
    String msg;
    try {
      msg = await _run(cmd);
    } catch (e, stack) {
      debugPrint('🔴 [VOZ] $e\n$stack');
      msg = 'No pude hacerlo';
    }
    if (cmd.action == VoiceAction.unknown) {
      msg = 'No entendí: "$heard"';
    }
    _flash(msg, ms: 5000);
  }

  _Engine _engine() {
    final automixPlaying = ref.read(automixProvider).isPlaying;
    final livePlaying = ref.read(liveDjProvider).isPlaying;
    if (livePlaying && !automixPlaying) return _Engine.livedj;
    if (automixPlaying && !livePlaying) return _Engine.automix;
    final route = _routeReader?.call() ?? 0;
    return route == 5 ? _Engine.livedj : _Engine.automix;
  }

  Future<String> _run(VoiceCommand cmd) async {
    switch (cmd.action) {
      case VoiceAction.pause:
        var paused = false;
        if (ref.read(automixProvider).isPlaying) {
          await ref.read(automixProvider.notifier).pause();
          paused = true;
        }
        if (ref.read(liveDjProvider).isPlaying) {
          await ref.read(liveDjProvider.notifier).togglePlayPause();
          paused = true;
        }
        return paused ? 'Pausa' : 'No hay nada sonando';

      case VoiceAction.play:
        if (ref.read(automixProvider).isPlaying ||
            ref.read(liveDjProvider).isPlaying) {
          return 'Ya está sonando';
        }
        if (_engine() == _Engine.livedj) {
          final live = ref.read(liveDjProvider);
          if (live.queue.isEmpty && live.currentTrackPath == null) {
            return 'Live DJ no tiene canciones';
          }
          await ref.read(liveDjProvider.notifier).togglePlayPause();
        } else {
          if (ref.read(automixProvider).currentTrackPath == null) {
            return 'Automix no tiene canción';
          }
          await ref.read(automixProvider.notifier).togglePlayPause();
        }
        return 'Play';

      case VoiceAction.next:
        if (_engine() == _Engine.livedj) {
          final live = ref.read(liveDjProvider);
          if (live.queue.isEmpty) return 'No hay siguiente en la cola';
          await ref.read(liveDjProvider.notifier).forceNext();
        } else {
          final auto = ref.read(automixProvider);
          if (auto.playlist.length < 2) return 'No hay siguiente';
          final next = (auto.currentIndex + 1) % auto.playlist.length;
          await ref.read(automixProvider.notifier).forceTransition(next);
        }
        return 'Siguiente';

      case VoiceAction.volumeUp:
        return _volume(delta: 0.15);
      case VoiceAction.volumeDown:
        return _volume(delta: -0.15);
      case VoiceAction.volumeSet:
        return _volume(set: (cmd.number ?? 50) / 100.0);

      case VoiceAction.mix:
        final index = (cmd.number ?? 0).clamp(0, 2);
        ref.read(mixFormulaProvider.notifier).state = MixFormula.values[index];
        const names = ['1 · DNA', '2 · Phrase 8', '3 · Stealth'];
        return 'Mezcla ${names[index]}';

      case VoiceAction.shuffleOn:
      case VoiceAction.shuffleOff:
        final wantRandom = cmd.action == VoiceAction.shuffleOn;
        if (_engine() == _Engine.livedj) {
          final isRandom =
              ref.read(liveDjProvider).mixStrategy == LiveDjMixStrategy.random;
          if (isRandom != wantRandom) {
            ref.read(liveDjProvider.notifier).toggleMixStrategy();
          }
        } else {
          final isRandom =
              ref.read(automixProvider).mixStrategy == MixStrategy.random;
          if (isRandom != wantRandom) {
            ref.read(automixProvider.notifier).toggleMixStrategy();
          }
        }
        return wantRandom ? 'Shuffle activado' : 'Modo secuencial';

      case VoiceAction.folderAsk:
        _flash('¿Qué carpeta?', ms: 9000);
        _clickSound();
        state = state.copyWith(listening: true);
        String heard = '';
        try {
          heard = await _listen(
            listenSec: 8,
            pauseSec: 2,
            mode: ListenMode.confirmation,
            phrases: await _folderPhrases(),
          );
        } finally {
          state = state.copyWith(listening: false);
        }
        if (heard.isEmpty) return 'No escuché ninguna carpeta';
        return _loadFolder(heard);

      case VoiceAction.folder:
        return _loadFolder(cmd.arg);

      case VoiceAction.unknown:
        return '';
    }
  }

  Future<String> _volume({double? set, double delta = 0}) async {
    try {
      final controller = VolumeController.instance;
      final current = await controller.getVolume();
      final target = (set ?? (current + delta)).clamp(0.0, 1.0);
      await controller.setVolume(target);
      return 'Volumen ${(target * 100).round()}%';
    } catch (e) {
      debugPrint('🔴 [VOZ] volumen $e');
      return 'No pude cambiar el volumen';
    }
  }

  String _libraryRoot() {
    if (Platform.isIOS && IphoneLibrary.musicRoot.isNotEmpty) {
      return IphoneLibrary.musicRoot;
    }
    return musicLibraryRoot();
  }

  Future<List<FolderCandidate>> _folderList() async {
    final fresh = DateTime.now().difference(_foldersAt).inSeconds < 90;
    if (fresh && _folders.isNotEmpty) return _folders;
    _folders = await listLibraryFolders(_libraryRoot());
    _foldersAt = DateTime.now();
    return _folders;
  }

  Future<List<String>> _folderPhrases() async {
    final folders = await _folderList();
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

  Future<String> _loadFolder(String spoken) async {
    final folders = await _folderList();
    if (folders.isEmpty) return 'No encontré carpetas de música';
    final decision = decideSpokenFolder(folders, spoken);
    final folder = decision.folder;
    if (folder == null) {
      switch (decision.miss ?? VoiceMiss.noMatch) {
        case VoiceMiss.unheard:
          return 'No escuché ninguna carpeta';
        case VoiceMiss.noMatch:
          return 'No encontré esa carpeta';
        case VoiceMiss.ambiguous:
          return 'Hay varias carpetas parecidas';
      }
    }

    final files = await listLibraryAudio(folder.path);
    if (files.isEmpty) return 'Esa carpeta no tiene pistas';

    if (_engine() == _Engine.livedj) {
      await ref.read(liveDjDirectoryProvider.notifier).scanPath(folder.path);
      final live = ref.read(liveDjProvider.notifier);
      live.clearQueue();
      live.addAllTracks(files);
      await live.forceNext();
    } else {
      await ref.read(directoryProvider.notifier).scanPath(folder.path);
      final played = ref.read(playedTracksProvider.notifier);
      for (final file in files) {
        played.removeTrack(file.path);
      }
      final queue = ref.read(automixQueueProvider.notifier);
      queue.clearQueue();
      queue.addAll(files);
      await ref
          .read(automixProvider.notifier)
          .loadContextAndPlay(files.map((f) => f.path).toList(), 0);
    }
    return 'Carpeta: ${folder.name}';
  }

  // --------------------------------------------------------------------------
  // Mensajes y ajustes
  // --------------------------------------------------------------------------

  void _flash(String message, {int ms = 3500}) {
    if (!_alive) return;
    state = state.copyWith(message: message);
    _messageTimer?.cancel();
    _messageTimer = Timer(Duration(milliseconds: ms), () {
      if (_alive && !state.listening) state = state.copyWith(message: '');
    });
  }

  File? _settingsFile() {
    try {
      final dir = File(MixStrategyFactory.getStrategy().getSessionPath()).parent;
      return File('${dir.path}${Platform.pathSeparator}voice_settings.json');
    } catch (_) {
      return null;
    }
  }

  bool _readWakeSetting() {
    try {
      final file = _settingsFile();
      if (file == null || !file.existsSync()) return false;
      final data = jsonDecode(file.readAsStringSync());
      return data is Map && data['wake'] == true;
    } catch (_) {
      return false;
    }
  }

  void _writeWakeSetting(bool on) {
    try {
      final file = _settingsFile();
      if (file == null) return;
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({'wake': on}));
    } catch (_) {}
  }
}
