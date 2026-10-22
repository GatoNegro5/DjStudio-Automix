import 'package:gatomix/providers/livedj_provider.dart';
import 'package:gatomix/providers/mix_formula.dart';
import 'package:gatomix/providers/theme_provider.dart';
import 'package:gatomix/ui/workspaces/livedj_deck_relevo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sin datos de cruce el relevo dura 700 ms', () {
    expect(relevoDurationMs(derive: false), 700);
  });

  test('DNA automático dura 18 s, bypass 4 s', () {
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.activeSync,
        formula: MixFormula.dnaEnergy,
      ),
      18000,
    );
    expect(
      relevoDurationMs(
        derive: true,
        mode: LiveDjMixMode.longBypass,
        formula: MixFormula.dnaEnergy,
      ),
      4000,
    );
  });

  test('el prefijo 112 es el pulso, no el título', () {
    expect(relevoBpm(r'112 - Earth, Wind & Fire, Indeep - September.mp3'), 112);
  });

  testWidgets('t=0 la tarjeta ENTRANDO está abajo y A arriba', (tester) async {
    await _pump(tester, 0);
    final _Tops tops = _tops(tester);
    expect(tops.incoming - tops.stage, closeTo(tops.main, 1));
    expect(tops.outgoing - tops.stage, closeTo(0, 1));
    expect(tops.incoming, greaterThan(tops.outgoing));
    expect(find.text('ENTRANDO'), findsOneWidget);
    expect(find.text('CANCION-C'), findsNothing);
    expect(_scale(tester, 'relevo-outgoing-scale'), closeTo(1, 0.001));
    expect(_scale(tester, 'relevo-incoming-scale'), closeTo(0.55, 0.001));
    _expectSpill(tester, 0);
    expect(find.byKey(const Key('relevo-shimmer')), findsOneWidget);
  });

  testWidgets('t=0.5 B empuja a A hacia arriba y el color va a medias', (
    tester,
  ) async {
    await _pump(tester, 0.5);
    final _Tops tops = _tops(tester);
    expect(tops.outgoing - tops.stage, closeTo(-0.5 * tops.main, 1));
    expect(tops.incoming - tops.stage, closeTo(0.5 * tops.main, 1));
    expect(tops.incoming, greaterThan(tops.outgoing));
    expect(find.text('ENTRANDO'), findsOneWidget);
    expect(find.text('CANCION-C'), findsNothing);
    expect(_scale(tester, 'relevo-outgoing-scale'), closeTo(0.925, 0.001));
    expect(
      _scale(tester, 'relevo-incoming-scale'),
      closeTo(relevoIncomingScale(0.5), 0.001),
    );
    _expectSpill(tester, 0.5);
    expect(find.byKey(const Key('relevo-ring')), findsOneWidget);
    expect(find.byType(ImageFiltered), findsWidgets);
    expect(_flash(tester), 0);
  });

  testWidgets('t=1 A salió por arriba, B ocupa su lugar y sigue la cola', (
    tester,
  ) async {
    await _pump(tester, 1);
    final _Tops tops = _tops(tester);
    expect(tops.outgoing - tops.stage, closeTo(-tops.main, 1));
    expect(tops.incoming - tops.stage, closeTo(0, 1));
    expect(find.text('ENTRANDO'), findsNothing);
    expect(find.text('CANCION-C'), findsOneWidget);
    expect(_scale(tester, 'relevo-outgoing-scale'), closeTo(0.85, 0.001));
    expect(_scale(tester, 'relevo-incoming-scale'), closeTo(1, 0.001));
    _expectSpill(tester, 1);
    expect(_flash(tester), 0);
    expect(find.byKey(const Key('relevo-shimmer')), findsNothing);
  });

  test('el derrame, el flash y el blur no mueven el cruce', () {
    expect(relevoIncomingScale(0), closeTo(0.55, 0.0001));
    expect(relevoIncomingScale(1), closeTo(1, 0.0001));
    expect(relevoOutgoingScale(0.5), closeTo(0.925, 0.0001));
    expect(relevoPeek(0.5), 0);
    expect(relevoPeek(1), 1);
    expect(relevoFlashOpacity(0), 0);
    expect(relevoFlashOpacity(0.5), 0);
    expect(relevoFlashOpacity(0.95), greaterThan(0));
    expect(relevoFlashOpacity(1), 0);
    expect(relevoWave(0.5), 0);
    expect(relevoWave(1), 1);
    expect(relevoBlurEnabled(360), isFalse);
    expect(relevoBlurEnabled(500), isTrue);
    final double y0 = relevoSpill(
      outgoing: GatoMixTheme.deckA,
      incoming: GatoMixTheme.deckB,
      t: 0,
      handoff: true,
      viewport: 500,
    ).center.y;
    final double y1 = relevoSpill(
      outgoing: GatoMixTheme.deckA,
      incoming: GatoMixTheme.deckB,
      t: 1,
      handoff: true,
      viewport: 500,
    ).center.y;
    expect(y0, greaterThan(y1));
  });

  testWidgets('móvil corto no desenfoca y el empuje sigue', (tester) async {
    await _pump(tester, 0.5, height: 360);
    final _Tops tops = _tops(tester, 360);
    expect(tops.outgoing - tops.stage, closeTo(-0.5 * tops.main, 1));
    expect(tops.incoming - tops.stage, closeTo(0.5 * tops.main, 1));
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('ENTRANDO'), findsOneWidget);
  });
}

const double _viewH = 500;

Future<void> _pump(WidgetTester tester, double t, {double height = _viewH}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            height: height,
            child: DeckRelevo(
              t: t,
              handoff: true,
              outgoingDeck: GatoMixTheme.deckA,
              incomingDeck: GatoMixTheme.deckB,
              cardTitle: 'CANCION-B',
              cardSubtitle: 'Entra',
              followingTitle: 'CANCION-C',
              outgoing: const Text('CANCION-A'),
              incoming: const Text('CANCION-B'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Tops {
  final double stage;
  final double outgoing;
  final double incoming;
  final double main;
  const _Tops(this.stage, this.outgoing, this.incoming, this.main);
}

_Tops _tops(WidgetTester tester, [double height = _viewH]) {
  return _Tops(
    tester.getTopLeft(find.byKey(const Key('relevo-stage'))).dy,
    tester.getTopLeft(find.byKey(const Key('relevo-outgoing'))).dy,
    tester.getTopLeft(find.byKey(const Key('relevo-incoming'))).dy,
    relevoMainHeight(height),
  );
}

double _scale(WidgetTester tester, String key) {
  final Transform widget = tester.widget<Transform>(find.byKey(Key(key)));
  return widget.transform.storage[0];
}

void _expectSpill(WidgetTester tester, double t) {
  final DecoratedBox box = tester.widget<DecoratedBox>(
    find.byKey(const Key('relevo-wash')),
  );
  final RadialGradient gradient =
      (box.decoration as BoxDecoration).gradient! as RadialGradient;
  final RelevoSpill spill = relevoSpill(
    outgoing: GatoMixTheme.deckA,
    incoming: GatoMixTheme.deckB,
    t: t,
    handoff: true,
    viewport: _viewH,
  );
  expect(gradient.center, spill.center);
  expect(gradient.radius, closeTo(spill.radius, 0.0001));
  expect(gradient.colors, spill.colors);
  expect(gradient.stops, spill.stops);
}

double _flash(WidgetTester tester) {
  return tester.widget<Opacity>(find.byKey(const Key('relevo-flash'))).opacity;
}
