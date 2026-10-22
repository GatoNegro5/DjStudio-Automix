import 'dart:io';

import 'package:gatomix_player/providers/livedj_provider.dart';
import 'package:gatomix_player/ui/workspaces/livedj_folder_playlist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// No abre los decks: solo pinta la vista para cazar un overflow.
class _FakeLiveDj extends LiveDjNotifier {
  @override
  LiveDjState build() {
    return LiveDjState(
      isPlaying: true,
      position: const Duration(seconds: 68),
      duration: const Duration(minutes: 3),
      customMixOutMs: 150000,
      currentTrackPath:
          r'C:\music\112 - Earth, Wind & Fire, Indeep - September.mp3',
      queue: [
        File(r'C:\music\100 - Dj Bobo - Chihuahua.mp3'),
        File(r'C:\music\Billy Idol - White Wedding.mp3'),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<Size> sizes = <Size>[
    const Size(1920, 1080),
    const Size(1440, 900),
    const Size(1280, 800),
    const Size(844, 390),
    const Size(800, 360),
  ];

  for (final Size size in sizes) {
    testWidgets('sin overflow a ${size.width.toInt()}x${size.height.toInt()}', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [liveDjProvider.overrideWith(_FakeLiveDj.new)],
          child: const MaterialApp(
            home: Scaffold(body: LiveDjFolderPlaylist()),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Earth, Wind & Fire, Indeep'), findsWidgets);
      expect(find.text('September'), findsWidgets);
      expect(find.text('112'), findsNothing);
      expect(find.text('Cargar Carpeta'), findsNothing);
      expect(find.text('COLA (2)'), findsOneWidget);
      expect(find.text('Dj Bobo'), findsOneWidget);
      expect(find.text('Chihuahua'), findsOneWidget);
      expect(find.text('100'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
