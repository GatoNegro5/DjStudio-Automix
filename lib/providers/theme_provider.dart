import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DjStudioTheme {
  // Entorno Profesional (Estilo Rekordbox / Serato Pro)
  // Contraste extremo para ambientes de poca luz (Cero fatiga visual)
  static const Color bgDark = Color(0xFF0A0C10); // Negro OLED Profundo
  static const Color bgPanel = Color(
    0xFF161920,
  ); // Gris Acero (Elevación de Paneles)

  // Colores de Deck y Acentos (Neón vibrante para romper lo monocromático)
  static const Color deckA = Color(
    0xFF00E5FF,
  ); // Azul Eléctrico (Estándar Deck 1)
  static const Color deckB = Color(
    0xFFFF3D00,
  ); // Naranja Neón (Estándar Deck 2)
  static const Color cyanAccent = Color(
    0xFF2979FF,
  ); // Azul Rey (Botones y Hovers)

  // Estados Críticos del Sistema
  static const Color syncActive = Color(
    0xFF00E676,
  ); // Verde Neón (Sync/Beatmatch)
  static const Color masterPeak = Color(
    0xFFFFC400,
  ); // Ámbar/Oro (Alertas/Master)
  static const Color alertCritical = Color(
    0xFFFF1744,
  ); // Rojo Escarlata (On Air/Errores)

  // Tipografía con tintes profesionales (Cero transparencias sucias)
  static const Color textMain = Color(0xFFF8F9FA); // Blanco Ártico puro
  static const Color textMuted = Color(
    0xFF8A93A2,
  ); // Gris Técnico (Mejor contraste que white54)
  static const Color textHidden = Color(
    0xFF3E4551,
  ); // Gris Oscuro para elementos deshabilitados

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      fontFamily: 'Consolas',
      colorScheme: const ColorScheme.dark(
        primary: syncActive,
        secondary: cyanAccent,
        surface: bgPanel,
        error: alertCritical,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: bgPanel,
          foregroundColor: textMain,
          side: const BorderSide(
            color: Color(0xFF2A2E37),
          ), // Borde sutil arquitectónico
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
        ),
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: syncActive,
        inactiveTrackColor: Color(
          0xFF2A2E37,
        ), // Track inactivo más oscuro y elegante
        thumbColor: textMain,
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textMuted,
        textColor: textMain,
      ),
      iconTheme: const IconThemeData(color: textMuted),
    );
  }
}

final themeProvider = Provider<ThemeData>((ref) => DjStudioTheme.darkTheme);
