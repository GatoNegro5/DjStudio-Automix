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
import 'playerDj.dart';
import 'dsp_workspace.dart';
import 'yt_workspace.dart';
import 'lab_workspace.dart';
import 'lan_sync_workspace.dart';

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
    // Solicita acceso crudo al disco duro (MANAGE_EXTERNAL_STORAGE)
    if (await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
    // Fallback de seguridad para APIs antiguas (Android 10 y menor)
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
  }

  // 🛠️ FIX: Bloqueo estricto de orientación (Landscape) dentro del hilo principal
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 🛠️ BINDING 2: Inicialización del Motor Nativo DSP en Rust (I/O Concurrente)
  await RustLib.init();

  // 🛠️ BINDING 3: Inicialización del Motor de Reproducción de Audio (libmpv)
  MediaKit.ensureInitialized();

  runApp(const ProviderScope(child: DjStudioApp()));
}

class DjStudioApp extends StatelessWidget {
  const DjStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF39FF14),
          secondary: Color(0xFFFF007F),
        ),
      ),
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
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.album, color: Color(0xFF39FF14), size: 70),
            const SizedBox(height: 30),
            const CircularProgressIndicator(color: Color(0xFFFF007F)),
            const SizedBox(height: 20),
            Text(
              _statusText,
              style: const TextStyle(
                color: Colors.white70,
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
// VISTA PRINCIPAL (UI ENRUTADA)
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
          // 1. SIDEBAR IZQUIERDO REDUCIDO E INMUNIZADO
          Material(
            color: const Color(0xFF000000),
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
                        color: Color(0xFF39FF14),
                      ),
                    ),
                  ),
                  // 🛠️ FIX GEOMÉTRICO: Scroll para evitar asfixia vertical en móviles
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
                                  ? const Color(0xFF39FF14)
                                  : Colors.white70,
                            ),
                            title: Text(
                              "Automix",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 0
                                    ? const Color(0xFF39FF14)
                                    : Colors.white70,
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
                                  ? const Color(0xFFFF007F)
                                  : Colors.white70,
                            ),
                            title: Text(
                              "Auto-Master",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 1
                                    ? const Color(0xFFFF007F)
                                    : Colors.white70,
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
                                  ? const Color(0xFF00FFFF)
                                  : Colors.white70,
                            ),
                            title: Text(
                              "Descargas YT",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 2
                                    ? const Color(0xFF00FFFF)
                                    : Colors.white70,
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
                                  ? Colors.orangeAccent
                                  : Colors.white70,
                            ),
                            title: Text(
                              "Laboratorio",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 3
                                    ? Colors.orangeAccent
                                    : Colors.white70,
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
                                  ? Colors.yellowAccent
                                  : Colors.white70,
                            ),
                            title: Text(
                              "Transferencia LAN",
                              style: TextStyle(
                                fontSize: 12,
                                color: currentRoute == 4
                                    ? Colors.yellowAccent
                                    : Colors.white70,
                                fontWeight: currentRoute == 4
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () =>
                                ref.read(routerProvider.notifier).setRoute(4),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Mini Status Global del Player anclado al fondo
                  if (playerState.currentTrackPath != null)
                    Container(
                      padding: const EdgeInsets.all(15),
                      color: const Color(0xFF181818),
                      width: double.infinity,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "MOTOR AUDIO",
                            style: TextStyle(
                              color: Colors.white38,
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
                              color: Color(0xFF39FF14),
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

          // 2. ÁREA CENTRAL ENRUTADA DINÁMICAMENTE (ESTADO PERSISTENTE)
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E1E1E), Color(0xFF121212)],
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
