import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gatomix_tv/main.dart';

void main() {
  testWidgets('muestra la configuración del nodo TV', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const GatoMixTvApp());
    await tester.pumpAndSettle();

    expect(find.text('NODO EDGE TV'), findsOneWidget);
    expect(find.text('CONECTAR'), findsOneWidget);
  });
}
