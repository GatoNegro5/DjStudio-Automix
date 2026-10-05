import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/voice_commands.dart';

/// Micrófono de voz. Toque = dar una orden. Mantener pulsado = activar o
/// desactivar la palabra clave "Oye DJ". Va junto al título en la barra
/// móvil y junto a "DjStudio" en el menú lateral de escritorio.
class VoiceMicButton extends ConsumerWidget {
  const VoiceMicButton({super.key, this.showMessage = true});

  /// Muestra el último mensaje (lo oído / lo hecho) a la derecha del icono.
  final bool showMessage;

  static const Color _live = Color(0xFFFF1744);
  static const Color _wake = Color(0xFF00E676);
  static const Color _idle = Color(0xFF8A93A2);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(voiceCommandsProvider);
    final Color color = s.listening
        ? _live
        : (s.unavailable ? const Color(0xFF3E4551) : (s.wake ? _wake : _idle));
    final IconData icon = s.listening
        ? Icons.mic
        : (s.wake ? Icons.hearing : Icons.mic_none);

    final button = Tooltip(
      message: s.wake
          ? 'Voz: toca para dar una orden. "Oye DJ" activo (mantén pulsado para apagarlo)'
          : 'Voz: toca para dar una orden. Mantén pulsado para activar "Oye DJ"',
      triggerMode: TooltipTriggerMode.manual,
      child: InkResponse(
        radius: 18,
        onTap: () => ref.read(voiceCommandsProvider.notifier).tapMic(),
        onLongPress: () => ref.read(voiceCommandsProvider.notifier).toggleWake(),
        child: SizedBox(
          width: 34,
          height: 36,
          child: Icon(icon, size: 19, color: color),
        ),
      ),
    );

    if (!showMessage || s.message.isEmpty) return button;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(
            s.message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: s.listening ? _live : const Color(0xFF8A93A2),
              fontFamily: 'Consolas',
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
