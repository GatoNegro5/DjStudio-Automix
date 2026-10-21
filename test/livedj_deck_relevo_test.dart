import 'package:djstudio_player/providers/livedj_provider.dart';
import 'package:djstudio_player/providers/mix_formula.dart';
import 'package:djstudio_player/providers/theme_provider.dart';
import 'package:djstudio_player/ui/workspaces/livedj_deck_relevo.dart';
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
    expect(
      _wash(tester),
      relevoWash(
        outgoing: DjStudioTheme.deckA,
        incoming: DjStudioTheme.deckB,
        t: 0,
        handoff: true,
      ),
    );
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
    expect(_scale(tester, 'relevo-outgoing-scale'), closeTo(0.925, 0.001));
    expect(_scale(tester, 'relevo-incoming-scale'), closeTo(0.775, 0.001));
    expect(
      _wash(tester),
      relevoWash(
        outgoing: DjStudioTheme.deckA,
        incoming: DjStudioTheme.deckB,
        t: 0.5,
        handoff: true,
      ),
    );
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
    expect(
      _wash(tester),
      relevoWash(
        outgoing: DjStudioTheme.deckA,
        incoming: DjStudioTheme.deckB,
        t: 1,
        handoff: true,
      ),
    );
  });
}

const double _viewH = 500;

Future<void> _pump(WidgetTester tester, double t) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 800,
            height: _viewH,
            child: DeckRelevo(
              t: t,
              handoff: true,
              outgoingDeck: DjStudioTheme.deckA,
              incomingDeck: DjStudioTheme.deckB,
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

_Tops _tops(WidgetTester tester) {
  return _Tops(
    tester.getTopLeft(find.byKey(const Key('relevo-stage'))).dy,
    tester.getTopLeft(find.byKey(const Key('relevo-outgoing'))).dy,
    tester.getTopLeft(find.byKey(const Key('relevo-incoming'))).dy,
    relevoMainHeight(_viewH),
  );
}

double _scale(WidgetTester tester, String key) {
  final Transform widget = tester.widget<Transform>(find.byKey(Key(key)));
  return widget.transform.storage[0];
}

Color _wash(WidgetTester tester) {
  final DecoratedBox box = tester.widget<DecoratedBox>(
    find.byKey(const Key('relevo-wash')),
  );
  return (box.decoration as BoxDecoration).color!;
}
