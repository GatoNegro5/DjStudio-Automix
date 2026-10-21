import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../providers/livedj_provider.dart';
import '../../providers/mix_formula.dart';
import '../../providers/theme_provider.dart';

/// Alto de la tarjeta «la que viene» dentro del relevo.
const double kRelevoCardHeight = 64;

/// El motor no publica el progreso del crossfade (sigue dentro de
/// `_executeMixEngine`). La vista usa la misma duración del lazo DAWN
/// en automático: DNA 18 s, bypass 4 s, Phrase/Stealth `phraseFadeMs`.
/// Si no se puede derivar, 700 ms.
int relevoDurationMs({
  required bool derive,
  LiveDjMixMode? mode,
  MixFormula? formula,
  double bpm = 0,
  int durationMs = 0,
}) {
  if (!derive || mode == null || formula == null) return 700;
  if (mode == LiveDjMixMode.longBypass) return 4000;
  if (formula == MixFormula.phraseGrid || formula == MixFormula.stealthGap) {
    final int ms = phraseFadeMs(
      incomingBpm: bpm,
      incomingDurationMs: durationMs,
    );
    return ms <= 0 ? 700 : ms;
  }
  return 18000;
}

/// BPM para el pulso visual. Prefijo `112 -` o un `128 bpm` en el nombre.
/// 0 si no hay un BPM de canción. No toca el audio.
double relevoBpm(String? path) {
  if (path == null || path.isEmpty) return 0;
  var name = path.replaceAll('\\', '/');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  final int dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  final RegExpMatch? tagged = RegExp(
    r'(\d{2,3}(?:\.\d+)?)\s*bpm',
    caseSensitive: false,
  ).firstMatch(name);
  if (tagged != null) {
    final double? v = double.tryParse(tagged.group(1)!);
    if (v != null && v >= 40 && v <= 250) return v;
  }
  final String lead = name.split(' - ').first.trim();
  if (RegExp(r'^\d{2,3}(?:\.\d+)?$').hasMatch(lead)) {
    final double? v = double.tryParse(lead);
    if (v != null && v >= 40 && v <= 250) return v;
  }
  return 0;
}

int relevoBeatMs(double bpm) {
  if (bpm < 40 || bpm > 250) return 500;
  return (60000 / bpm).round().clamp(240, 1500);
}

double relevoCardExtent(double viewport) {
  if (viewport < 96) return math.max(32, viewport * 0.34);
  return kRelevoCardHeight;
}

double relevoMainHeight(double viewport) =>
    math.max(0, viewport - relevoCardExtent(viewport));

/// A sale hacia arriba. B entra desde abajo la misma distancia: la empuja.
double relevoOutgoingTop(double t, double mainH) => -t.clamp(0.0, 1.0) * mainH;

double relevoIncomingTop(double t, double mainH) =>
    (1 - t.clamp(0.0, 1.0)) * mainH;

/// Carátula que sale: 1.0 → 0.85.
double relevoOutgoingScale(double t) => 1.0 - 0.15 * t.clamp(0.0, 1.0);

/// Carátula que entra: crece hasta el tamaño principal.
double relevoIncomingScale(double t) => 0.55 + 0.45 * t.clamp(0.0, 1.0);

/// Fondo: del deck saliente al entrante. En reposo, transparente
/// (queda el degradado de la cabina).
Color relevoWash({
  required Color outgoing,
  required Color incoming,
  required double t,
  required bool handoff,
}) {
  if (!handoff) return const Color(0x00000000);
  final double u = t.clamp(0.0, 1.0);
  final Color deck = Color.lerp(outgoing, incoming, u)!;
  return Color.lerp(DjStudioTheme.bgDark, deck, 0.42)!;
}

/// Relevo visual de dos decks. Solo pinta: no abre reproductores ni
/// escribe el motor. [t] es el progreso del cruce, 0 al empezar y 1 al terminar.
/// B sube desde la tarjeta y empuja a A fuera por arriba.
class DeckRelevo extends StatelessWidget {
  final double t;
  final bool handoff;
  final Widget outgoing;
  final Widget incoming;
  final String cardTitle;
  final String cardSubtitle;
  final String followingTitle;
  final String followingSubtitle;
  final Color outgoingDeck;
  final Color incomingDeck;
  final double beatPhase;

  const DeckRelevo({
    super.key,
    required this.t,
    required this.handoff,
    required this.outgoing,
    required this.incoming,
    required this.outgoingDeck,
    required this.incomingDeck,
    this.cardTitle = '',
    this.cardSubtitle = '',
    this.followingTitle = '',
    this.followingSubtitle = '',
    this.beatPhase = 0,
  });

  @override
  Widget build(BuildContext context) {
    final double u = t.clamp(0.0, 1.0);
    final bool live = handoff;
    final double shown = live ? u : 0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double h = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 360;
        final double cardH = relevoCardExtent(h);
        final double mainH = relevoMainHeight(h);
        final double outScale = live ? relevoOutgoingScale(shown) : 1;
        final double inScale = live ? relevoIncomingScale(shown) : 0.55;
        final bool entering = live && shown < 1;
        final double pulse = entering
            ? 1 + 0.04 * math.sin(beatPhase * math.pi * 2)
            : 1.0;
        return ClipRect(
          child: DecoratedBox(
            key: const Key('relevo-stage'),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B3A4B), DjStudioTheme.bgDark],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const SizedBox.expand(),
                DecoratedBox(
                  key: const Key('relevo-wash'),
                  decoration: BoxDecoration(
                    color: relevoWash(
                      outgoing: outgoingDeck,
                      incoming: incomingDeck,
                      t: shown,
                      handoff: live,
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
                Positioned(
                  top: relevoOutgoingTop(shown, mainH),
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: KeyedSubtree(
                    key: const Key('relevo-outgoing'),
                    child: Opacity(
                      opacity: live ? (1 - shown).clamp(0.0, 1.0) : 1,
                      child: Transform(
                        key: const Key('relevo-outgoing-scale'),
                        alignment: Alignment.topCenter,
                        transform: Matrix4.diagonal3Values(
                          outScale,
                          outScale,
                          1,
                        ),
                        child: outgoing,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: live ? relevoIncomingTop(shown, mainH) : mainH,
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: KeyedSubtree(
                    key: const Key('relevo-incoming'),
                    child: Opacity(
                      opacity: live ? shown : 0,
                      child: Transform(
                        key: const Key('relevo-incoming-scale'),
                        alignment: Alignment.bottomCenter,
                        transform: Matrix4.diagonal3Values(inScale, inScale, 1),
                        child: incoming,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 0,
                  height: cardH,
                  child: Transform.scale(
                    key: const Key('relevo-card'),
                    scale: pulse,
                    alignment: Alignment.center,
                    child: _RelevoCard(
                      entering: entering,
                      title: entering ? cardTitle : followingTitle,
                      subtitle: entering ? cardSubtitle : followingSubtitle,
                      deck: incomingDeck,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _RelevoCard extends StatelessWidget {
  final bool entering;
  final String title;
  final String subtitle;
  final Color deck;

  const _RelevoCard({
    required this.entering,
    required this.title,
    required this.subtitle,
    required this.deck,
  });

  @override
  Widget build(BuildContext context) {
    if (!entering && title.isEmpty) return const SizedBox.shrink();
    final Color fill = entering
        ? Color.lerp(DjStudioTheme.bgPanel, deck, 0.55)!
        : DjStudioTheme.bgPanel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: entering ? deck : DjStudioTheme.textHidden),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (entering)
              Text(
                'ENTRANDO',
                key: const Key('relevo-entrando'),
                maxLines: 1,
                style: TextStyle(
                  color: deck,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  letterSpacing: 1.1,
                ),
              ),
            Text(
              title,
              key: Key(entering ? 'relevo-card-title' : 'relevo-next'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: DjStudioTheme.textMain,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DjStudioTheme.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
