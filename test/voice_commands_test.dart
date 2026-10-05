import 'package:djstudio_player/services/voice_commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  VoiceAction a(String s) => parseVoiceCommand(s).action;

  test('transporte', () {
    expect(a('pausa'), VoiceAction.pause);
    expect(a('Para'), VoiceAction.pause);
    expect(a('detente por favor'), VoiceAction.pause);
    expect(a('play'), VoiceAction.play);
    expect(a('sigue'), VoiceAction.play);
    expect(a('pon música'), VoiceAction.play);
    expect(a('siguiente'), VoiceAction.next);
    expect(a('siguiente canción'), VoiceAction.next);
    expect(a('cambia la canción'), VoiceAction.next);
    expect(a('pon otra'), VoiceAction.next);
  });

  test('volumen', () {
    expect(a('sube el volumen'), VoiceAction.volumeUp);
    expect(a('baja el volumen'), VoiceAction.volumeDown);
    expect(a('sube'), VoiceAction.volumeUp);
    expect(a('más fuerte'), VoiceAction.volumeUp);
    expect(a('más bajo'), VoiceAction.volumeDown);
    final set = parseVoiceCommand('volumen al 40 por ciento');
    expect(set.action, VoiceAction.volumeSet);
    expect(set.number, 40);
    expect(parseVoiceCommand('volumen máximo').number, 100);
  });

  test('mezcla y shuffle', () {
    expect(parseVoiceCommand('mezcla uno').number, 0);
    expect(parseVoiceCommand('mezcla dos').number, 1);
    expect(parseVoiceCommand('mezcla 3').number, 2);
    expect(parseVoiceCommand('pon la mezcla stealth').action, VoiceAction.mix);
    expect(a('shuffle'), VoiceAction.shuffleOn);
    expect(a('modo aleatorio'), VoiceAction.shuffleOn);
    expect(a('secuencial'), VoiceAction.shuffleOff);
  });

  test('carpeta', () {
    final c = parseVoiceCommand('pon la carpeta salsa');
    expect(c.action, VoiceAction.folder);
    expect(c.arg, contains('salsa'));
    expect(parseVoiceCommand('cambia a rock').action, VoiceAction.folder);
    expect(a('cambia de carpeta'), VoiceAction.folderAsk);
    expect(a('cambia'), VoiceAction.next);
  });

  test('palabra clave', () {
    expect(splitWake('Oye DJ pausa')?.rest, 'pausa');
    expect(splitWake('oye dj')?.rest, '');
    expect(splitWake('hey DJ sube el volumen')?.rest, 'sube el volumen');
    expect(splitWake('hola que tal'), isNull);
  });
}
