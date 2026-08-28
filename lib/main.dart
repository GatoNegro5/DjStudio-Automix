import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:permission_handler/permission_handler.dart';

// 🛠️ INYECCIÓN: El puente de memoria FFI (Rust <> Dart)
import 'package:djstudio_player/src/rust/frb_generated.dart';

// --- IMPORTACIÓN DE MÓDULOS Y PROVIDERS ---
import 'providers/player_provider.dart';
import 'providers/theme_provider.dart'; // 🛠️ INYECCIÓN: Motor de Tema Global
import 'playerDj.dart';
import 'dsp_workspace.dart';
import 'yt_workspace.dart';
import 'lab_workspace.dart';
import 'lan_sync_workspace.dart';
import 'broadcast_workspace.dart';

// ==========================================
// ENRUTADOR DE ESTADO (SPA - Single Page App)
// 0: Dj Workspace, 1: Módulos Auto-Master, 2: Descargas YT, 3: Laboratorio, 4: Transferencia LAN, 5: Radio YT
// ==========================================
class RouterNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setRoute(int newRoute) {
    state = newRoute;
  }
}

final routerProvider = NotifierProvider<RouterNotifier, int>(
  RouterNotifier.new,
);

Future<void> main() async {
  // 🛠️ BINDING 1: Sellar el hilo de Flutter
  WidgetsFlutterBinding.ensureInitialized();

  // 🛠️ FASE 3: Perforación de Scoped Storage en Runtime (Android 11+)
  if (Platform.isAndroid) {
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
  }

  // 🛠️ FIX: Bloqueo estricto de orientación (Landscape)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 🛠️ BINDING 2: Inicialización del Motor Nativo DSP en Rust
  await RustLib.init();

  // 🛠️ BINDING 3: Inicialización del Motor de Reproducción de Audio (libmpv)
  MediaKit.ensureInitialized();

  runApp(const ProviderScope(child: DjStudioApp()));
}

// 🛠️ FIX ARQUITECTURA: Convertido a ConsumerWidget para inyectar Theme Dinámico
class DjStudioApp extends ConsumerWidget {
  const DjStudioApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appTheme = ref.watch(themeProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme, // Aplicación del Motor de Temas
      home: const BootloaderScreen(),
    );
  }
}

// ==========================================
// ESCUDO DE PERMISOS Y ARRANQUE NATIVO
// ==========================================
class BootloaderScreen extends StatefulWidget {
  const BootloaderScreen({super.key});

  @override
  State<BootloaderScreen> createState() => _BootloaderScreenState();
}

class _BootloaderScreenState extends State<BootloaderScreen> {
  String _statusText = "Inicializando motores C++...";

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndBoot();
  }

  Future<void> _requestPermissionsAndBoot() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      setState(() => _statusText = "Verificando llaves de I/O nativo...");

      if (Platform.isAndroid) {
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          await Permission.manageExternalStorage.request();
        }
        await Permission.storage.request();
      } else {
        await Permission.storage.request();
      }
    }

    setState(() => _statusText = "Cargando espacio de trabajo...");
    await Future.delayed(const Duration(milliseconds: 600));

    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              const MainWorkspace(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DjStudioTheme.bgDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.album, color: DjStudioTheme.syncActive, size: 70),
            const SizedBox(height: 30),
            const CircularProgressIndicator(color: DjStudioTheme.deckA),
            const SizedBox(height: 20),
            Text(
              _statusText,
              style: const TextStyle(
                color: DjStudioTheme.textMuted,
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// VISTA PRINCIPAL (UI ENRUTADA CON DISEÑO HÁPTICO)
// ==========================================
class MainWorkspace extends ConsumerWidget {
  const MainWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRoute = ref.watch(routerProvider);
    final playerState = ref.watch(playerProvider);

    return Scaffold(
      body: Row(
        children: [
          // 1. SIDEBAR IZQUIERDO REDUCIDO Y TEMATIZADO
          Material(
            color: DjStudioTheme.bgDark,
            child: SizedBox(
              width: 160,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(15.0),
                    child: Text(
                      "DjStudio",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: DjStudioTheme.textMain,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: Column(
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.album,
                              size: 20,
                              color: currentRoute == 0
                                  ? DjStudioTheme.deckA
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "Automix",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 0
                                    ? DjStudioTheme.deckA
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 0
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(0),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.settings,
                              size: 20,
                              color: currentRoute == 1
                                  ? DjStudioTheme.deckB
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "Auto-Master",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 1
                                    ? DjStudioTheme.deckB
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 1
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(1),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.cloud_download,
                              size: 20,
                              color: currentRoute == 2
                                  ? DjStudioTheme.cyanAccent
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "Descargas YT",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 2
                                    ? DjStudioTheme.cyanAccent
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 2
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(2),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.science,
                              size: 20,
                              color: currentRoute == 3
                                  ? DjStudioTheme.alertCritical
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "Laboratorio",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 3
                                    ? DjStudioTheme.alertCritical
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 3
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(3),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.wifi_tethering,
                              size: 20,
                              color: currentRoute == 4
                                  ? DjStudioTheme.masterPeak
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "LAN Sync",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 4
                                    ? DjStudioTheme.masterPeak
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 4
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(4),
                          ),
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 15,
                            ),
                            leading: Icon(
                              Icons.radio,
                              size: 20,
                              color: currentRoute == 5
                                  ? DjStudioTheme.syncActive
                                  : DjStudioTheme.textHidden,
                            ),
                            title: Text(
                              "Live DJ",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 5
                                    ? DjStudioTheme.syncActive
                                    : DjStudioTheme.textMuted,
                                fontWeight: currentRoute == 5
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(5),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (playerState.currentTrackPath != null)
                    Container(
                      padding: const EdgeInsets.all(15),
                      decoration: const BoxDecoration(
                        color: DjStudioTheme.bgPanel,
                        border: Border(top: BorderSide(color: Colors.white10)),
                      ),
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "MOTOR AUDIO",
                            style: TextStyle(
                              color: DjStudioTheme.textHidden,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            playerState.currentTrackPath!
                                .replaceAll('\\', '/')
                                .split('/')
                                .last,
                            style: const TextStyle(
                              color: DjStudioTheme.syncActive,
                              fontSize: 11,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 2. ÁREA CENTRAL
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [DjStudioTheme.bgPanel, DjStudioTheme.bgDark],
                ),
              ),
              child: IndexedStack(
                index: currentRoute,
                children: const [
                  UnifiedDjWorkspace(),
                  DspNlpWorkspace(),
                  YoutubeSearchAndDownloadWorkspace(),
                  LabWorkspace(),
                  LanSyncWorkspace(),
                  BroadcastWorkspace(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
