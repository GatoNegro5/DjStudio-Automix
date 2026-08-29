import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DjStudioTheme {
  // Matriz de Energía y Contraste Cognitivo (Dark UI Premium)
  static const Color bgDark = Color(
    0xFF181A1F,
  ); // Gris Pizarra Profundo (Alivia fatiga visual)
  static const Color bgPanel = Color(
    0xFF21252B,
  ); // Gris Industrial (Elevación de Paneles)
  static const Color deckA = Color(0xFF9B59B6); // Amatista (Púrpura)
  static const Color deckB = Color(0xFFE67E22); // Ojo de Tigre (Ámbar)
  static const Color syncActive = Color(0xFF2ECC71); // Verde Jade (Éxitos)
  static const Color masterPeak = Color(
    0xFFF1C40F,
  ); // Oro Pirita (Alertas/Master)
  static const Color alertCritical = Color(
    0xFFE74C3C,
  ); // Rojo Neón (Laboratorio/Errores)
  static const Color cyanAccent = Color(0xFF00E5FF); // Cian (Descargas/Nube)

  static const Color textMain = Colors.white;
  static const Color textMuted = Colors.white54;
  static const Color textHidden = Colors.white24;

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      fontFamily: 'Consolas',
      colorScheme: const ColorScheme.dark(
        primary: syncActive,
        secondary: deckA,
        surface: bgPanel,
        error: alertCritical,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bgPanel,
          foregroundColor: textMain,
          side: const BorderSide(color: Colors.white10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: syncActive,
        inactiveTrackColor: Colors.white10,
        thumbColor: textMain,
      ),
    );
  }
}

final themeProvider = Provider<ThemeData>((ref) => DjStudioTheme.darkTheme);
