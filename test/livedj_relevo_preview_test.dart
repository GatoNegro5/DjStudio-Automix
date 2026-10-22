import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:gatomix_player/providers/theme_provider.dart';
import 'package:gatomix_player/ui/workspaces/livedj_deck_relevo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captura la vista previa solo con RELEVO_PREVIEW=1.
/// No corre en el suite normal: no toca red ni el motor.
void main() {
  testWidgets('vista previa del relevo', (tester) async {
    if (Platform.environment['RELEVO_PREVIEW'] != '1') return;
    final String root =
        Platform.environment['RELEVO_OUT'] ?? '/tmp/relevo-preview';
    final Directory stills = Directory('$root/stills')
      ..createSync(recursive: true);
    final Directory v2 = Directory('$root/v2')..createSync(recursive: true);
    final Directory antes = Directory('$root/antes')
      ..createSync(recursive: true);

    const double w = 960;
    const double h = 540;
    const List<(String, double, double)> keys = [
      ('t0', 0, 0.25),
      ('t025', 0.25, 0.25),
      ('t050', 0.50, 0.25),
      ('t075', 0.75, 0.00),
      ('t100', 1, 0.25),
      ('remate', 0.94, 0.00),
    ];

    for (final (String name, double t, double beat) in keys) {
      await _shot(
        tester,
        file: File('${stills.path}/relevo-v2-$name.png'),
        width: w,
        height: h,
        t: t,
        beat: beat,
        after: true,
        label: 'RELEVO V2',
      );
      await _shot(
        tester,
        file: File('${stills.path}/relevo-antes-$name.png'),
        width: w,
        height: h,
        t: t,
        beat: beat,
        after: false,
        label: 'v3.0.19',
      );
    }
    await _shot(
      tester,
      file: File('${stills.path}/relevo-v2-movil-t050.png'),
      width: 800,
      height: 360,
      t: 0.5,
      beat: 0.25,
      after: true,
      label: 'V2 MOVIL',
    );

    if (Platform.environment['RELEVO_STILLS'] == '1') return;
    const int frames = 100;
    const double seconds = 5;
    for (int i = 0; i < frames; i++) {
      final double t = i / (frames - 1);
      final double beat = (i / frames) * seconds * (124 / 60);
      final String id = i.toString().padLeft(3, '0');
      await _shot(
        tester,
        file: File('${v2.path}/frame_$id.png'),
        width: w,
        height: h,
        t: t,
        beat: beat,
        after: true,
        label: 'RELEVO V2',
      );
      await _shot(
        tester,
        file: File('${antes.path}/frame_$id.png'),
        width: w,
        height: h,
        t: t,
        beat: beat,
        after: false,
        label: 'v3.0.19',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<void> _shot(
  WidgetTester tester, {
  required File file,
  required double width,
  required double height,
  required double t,
  required double beat,
  required bool after,
  required String label,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Stage(
        width: width,
        height: height,
        t: t,
        beat: beat,
        after: after,
        label: label,
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('relevo-preview')),
      );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) {
      throw StateError('sin bytes ${file.path}');
    }
    file.writeAsBytesSync(data.buffer.asUint8List());
  });
}

class _Stage extends StatelessWidget {
  final double width;
  final double height;
  final double t;
  final double beat;
  final bool after;
  final String label;

  const _Stage({
    required this.width,
    required this.height,
    required this.t,
    required this.beat,
    required this.after,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final Widget body = after
        ? DeckRelevo(
            t: t,
            handoff: true,
            outgoing: const _Face(
              mark: 'A',
              base: Color(0xFF143A66),
              accent: GatoMixTheme.deckA,
              headline: 'NOCHE LARGA',
              subtitle: 'A. Rivera',
            ),
            incoming: const _Face(
              mark: 'B',
              base: Color(0xFF5A2414),
              accent: GatoMixTheme.deckB,
              headline: 'FUEGO',
              subtitle: 'B. Sol',
              bpm: true,
            ),
            cardTitle: 'FUEGO',
            cardSubtitle: '124 BPM',
            followingTitle: 'DESPUES',
            followingSubtitle: 'C. Mar',
            outgoingDeck: GatoMixTheme.deckA,
            incomingDeck: GatoMixTheme.deckB,
            beatPhase: beat,
          )
        : RelevoAntes(
            t: t,
            beat: beat,
            outgoing: const _Face(
              mark: 'A',
              base: Color(0xFF143A66),
              accent: GatoMixTheme.deckA,
              headline: 'NOCHE LARGA',
              subtitle: 'A. Rivera',
            ),
            incoming: const _Face(
              mark: 'B',
              base: Color(0xFF5A2414),
              accent: GatoMixTheme.deckB,
              headline: 'FUEGO',
              subtitle: 'B. Sol',
              bpm: true,
            ),
          );
    return ColoredBox(
      color: GatoMixTheme.bgDark,
      child: SizedBox(
        width: width,
        height: height,
        child: RepaintBoundary(
          key: const Key('relevo-preview'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              body,
              Positioned(
                top: 8,
                right: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: GatoMixTheme.bgPanel.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: GatoMixTheme.textMain,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Face extends StatelessWidget {
  final String mark;
  final Color base;
  final Color accent;
  final String headline;
  final String subtitle;
  final bool bpm;

  const _Face({
    required this.mark,
    required this.base,
    required this.accent,
    required this.headline,
    required this.subtitle,
    this.bpm = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool wide = relevoWide(MediaQuery.sizeOf(context).width);
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          wide ? 24 : 12,
          wide ? 16 : 8,
          wide ? 16 : 10,
          wide ? 8 : 4,
        ),
        child: LayoutBuilder(
          builder: (context, inner) {
            final double side = math
                .min(inner.maxHeight, inner.maxWidth * 0.62)
                .clamp(0.0, 440.0);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Art(
                  side: side,
                  base: base,
                  accent: accent,
                  mark: mark,
                  bpm: bpm,
                ),
                SizedBox(width: wide ? 20 : 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: wide ? 36 : 22,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: wide ? 16 : 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Art extends StatelessWidget {
  final double side;
  final Color base;
  final Color accent;
  final String mark;
  final bool bpm;

  const _Art({
    required this.side,
    required this.base,
    required this.accent,
    required this.mark,
    required this.bpm,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: side,
        height: side,
        child: CustomPaint(
          painter: _ArtPainter(
            base: base,
            accent: accent,
            mark: mark,
            bpm: bpm,
          ),
        ),
      ),
    );
  }
}

class _ArtPainter extends CustomPainter {
  final Color base;
  final Color accent;
  final String mark;
  final bool bpm;

  const _ArtPainter({
    required this.base,
    required this.accent,
    required this.mark,
    required this.bpm,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    canvas.drawCircle(
      Offset(size.width * 0.74, size.height * 0.28),
      size.width * 0.18,
      Paint()..color = accent,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.62, size.width, size.height * 0.38),
      Paint()..color = GatoMixTheme.bgDark.withValues(alpha: 0.55),
    );
    final TextPainter big = TextPainter(
      text: TextSpan(
        text: mark,
        style: TextStyle(
          color: GatoMixTheme.textMain,
          fontSize: size.width * 0.34,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    big.paint(canvas, Offset(size.width * 0.08, size.height * 0.60));
    if (!bpm) return;
    final TextPainter small = TextPainter(
      text: TextSpan(
        text: '124',
        style: TextStyle(
          color: GatoMixTheme.textMain,
          fontSize: size.width * 0.12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    small.paint(canvas, Offset(size.width * 0.08, size.height * 0.08));
  }

  @override
  bool shouldRepaint(covariant _ArtPainter old) => false;
}

/// Dibujo de v3.0.19: empuje lineal, fundido plano, sin 3D ni anillo.
class RelevoAntes extends StatelessWidget {
  final double t;
  final double beat;
  final Widget outgoing;
  final Widget incoming;

  const RelevoAntes({
    super.key,
    required this.t,
    required this.beat,
    required this.outgoing,
    required this.incoming,
  });

  @override
  Widget build(BuildContext context) {
    final double u = t.clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final double h = constraints.maxHeight;
        final double cardH = relevoCardExtent(h);
        final double mainH = relevoMainHeight(h);
        final bool entering = u < 1;
        final double pulse = entering
            ? 1 + 0.04 * math.sin(beat * math.pi * 2)
            : 1;
        final Color wash = Color.lerp(
          GatoMixTheme.bgDark,
          Color.lerp(GatoMixTheme.deckA, GatoMixTheme.deckB, u)!,
          0.42,
        )!;
        return ClipRect(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1B3A4B), GatoMixTheme.bgDark],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: wash),
                Positioned(
                  top: relevoOutgoingTop(u, mainH),
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: Opacity(
                    opacity: (1 - u).clamp(0.0, 1.0),
                    child: Transform(
                      alignment: Alignment.topCenter,
                      transform: Matrix4.diagonal3Values(
                        relevoOutgoingScale(u),
                        relevoOutgoingScale(u),
                        1,
                      ),
                      child: outgoing,
                    ),
                  ),
                ),
                Positioned(
                  top: relevoIncomingTop(u, mainH),
                  left: 0,
                  right: 0,
                  height: mainH,
                  child: Opacity(
                    opacity: u,
                    child: Transform(
                      alignment: Alignment.bottomCenter,
                      transform: Matrix4.diagonal3Values(
                        0.55 + 0.45 * u,
                        0.55 + 0.45 * u,
                        1,
                      ),
                      child: incoming,
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 0,
                  height: cardH,
                  child: Transform.scale(
                    scale: pulse,
                    child: _AntesCard(entering: entering),
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

class _AntesCard extends StatelessWidget {
  final bool entering;
  const _AntesCard({required this.entering});

  @override
  Widget build(BuildContext context) {
    final Color deck = GatoMixTheme.deckB;
    final Color fill = entering
        ? Color.lerp(GatoMixTheme.bgPanel, deck, 0.55)!
        : GatoMixTheme.bgPanel;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: entering ? deck : GatoMixTheme.textHidden),
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
                style: TextStyle(
                  color: deck,
                  fontWeight: FontWeight.bold,
                  fontSize: 10,
                  letterSpacing: 1.1,
                ),
              ),
            Text(
              entering ? 'FUEGO' : 'DESPUES',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: GatoMixTheme.textMain,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            Text(
              entering ? '124 BPM' : 'C. Mar',
              maxLines: 1,
              style: const TextStyle(
                color: GatoMixTheme.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
