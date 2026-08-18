import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'providers/player_provider.dart';

class RadioWorkspace extends ConsumerStatefulWidget {
  const RadioWorkspace({super.key});

  @override
  ConsumerState<RadioWorkspace> createState() => _RadioWorkspaceState();
}

class _RadioWorkspaceState extends ConsumerState<RadioWorkspace> {
  late final Player _player;
  StreamSubscription? _completedSub;
  StreamSubscription? _playingSub;

  // 🛠️ ESTADO DE LA RADIO
  bool _isLoading = false;
  bool _isPlaying = false;
  String _activeStation = "";
  String _status = "Selecciona una estación para comenzar";

  // 🛠️ MOTOR DE COLA (QUEUE)
  List<Map<String, String>> _queue = [];
  Map<String, String>? _currentTrack;

  // 🛠️ CATÁLOGO DE ESTACIONES COMERCIALES
  final List<Map<String, dynamic>> _stations = [
    {
      'title': 'Rock 80s',
      'query': '80s classic rock hits audio',
      'icon': Icons.electric_bolt,
      'color': Colors.redAccent,
    },
    {
      'title': 'Salsa Romántica',
      'query': 'Salsa romantica clasicos audio',
      'icon': Icons.nightlife,
      'color': Colors.orange,
    },
    {
      'title': 'EDM & House',
      'query': 'EDM house club mix audio',
      'icon': Icons.headphones,
      'color': Colors.blueAccent,
    },
    {
      'title': 'Baladas',
      'query': 'Baladas del recuerdo en español audio',
      'icon': Icons.favorite,
      'color': Colors.pinkAccent,
    },
    {
      'title': 'Pop Latino',
      'query': 'Pop latino exitos audio',
      'icon': Icons.star,
      'color': Colors.purpleAccent,
    },
    {
      'title': 'Reggaeton Old',
      'query': 'Reggaeton old school clasicos audio',
      'icon': Icons.local_fire_department,
      'color': Colors.amber,
    },
    {
      'title': 'Jazz & Relax',
      'query': 'Smooth jazz relax audio',
      'icon': Icons.coffee,
      'color': Colors.brown,
    },
    {
      'title': 'Cumbia',
      'query': 'Cumbias bailables clasicas audio',
      'icon': Icons.music_note,
      'color': Colors.teal,
    },
  ];

  @override
  void initState() {
    super.initState();
    // Motor Zero-Disk (Sin salida de video)
    _player = Player(configuration: const PlayerConfiguration(vo: 'null'));
    _attachListeners();
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _playingSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _attachListeners() {
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });

    // 🛠️ EVENT LOOP: El corazón del Auto-Play infinito
    _completedSub = _player.stream.completed.listen((completed) {
      if (completed && _currentTrack != null) {
        debugPrint("🟢 [RADIO] Pista terminada. Saltando a la siguiente...");
        _playNextInQueue();
      }
    });
  }

  Future<void> _tuneInStation(Map<String, dynamic> station) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _activeStation = station['title'];
      _status = "Sintonizando ${_activeStation}...";
      _queue.clear();
      _currentTrack = null;
    });

    await _player.stop();

    try {
      // 🛠️ SCRAPER DE LOTES: Buscamos 20 resultados para tener holgura tras el filtrado
      final query = station['query'];
      final searchRes = await Process.run('yt-dlp', [
        'ytsearch20:$query',
        '--print',
        '%(id)s|%(title)s',
        '--no-warnings',
      ]);

      if (searchRes.exitCode != 0) throw Exception("Error de conexión al CDN");

      final lines = searchRes.stdout.toString().trim().split('\n');
      if (lines.isEmpty || lines.first.isEmpty)
        throw Exception("Cero resultados.");

      // Obtenemos la playlist local actual para filtrar duplicados
      final localPlaylist = ref.read(playerProvider).playlist;
      List<String> normalizedLocalNames = localPlaylist.map((path) {
        String name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
        name = name.replaceAll('.mp3', '').replaceAll('.webm', '');
        return name.replaceAll(RegExp(r'\[.*?\]|\(.*?\)'), '').trim();
      }).toList();

      int colisiones = 0;

      for (var line in lines) {
        final parts = line.split('|');
        if (parts.length >= 2) {
          final ytId = parts[0].trim();
          final ytTitleRaw = parts[1].trim();

          String ytTitleClean = ytTitleRaw
              .toLowerCase()
              .replaceAll(RegExp(r'\[.*?\]|\(.*?\)'), '')
              .trim();

          // 🛠️ ESCUDO DE DUPLICADOS: Comparamos strings
          bool yaExiste = false;
          for (String localName in normalizedLocalNames) {
            if (localName.contains(ytTitleClean) ||
                ytTitleClean.contains(localName)) {
              yaExiste = true;
              break;
            }
          }

          if (yaExiste) {
            colisiones++;
            debugPrint(
              "🛡️ [RADIO] Pista descartada (Ya existe en disco): $ytTitleRaw",
            );
          } else {
            _queue.add({'id': ytId, 'title': ytTitleRaw});
          }
        }
      }

      debugPrint(
        "📻 [RADIO] Buffer llenado: ${_queue.length} pistas. Colisiones evitadas: $colisiones",
      );
      _queue.shuffle(); // Aleatoriedad de reproducción

      if (_queue.isNotEmpty) {
        setState(() => _isLoading = false);
        _playNextInQueue();
      } else {
        throw Exception(
          "Buffer vacío (Todas las pistas obtenidas ya están en tu disco local).",
        );
      }
    } catch (e) {
      setState(() {
        _status = "Error sintonizando: $e";
        _isLoading = false;
      });
    }
  }

  Future<void> _playNextInQueue() async {
    if (_queue.isEmpty) {
      setState(
        () => _status = "Fin de la transmisión. Sintoniza otra estación.",
      );
      _currentTrack = null;
      return;
    }

    final nextTrack = _queue.removeAt(0); // Pop the top
    setState(() {
      _currentTrack = nextTrack;
      _status = "Reproduciendo de $_activeStation";
    });

    try {
      final directUrl = 'https://www.youtube.com/watch?v=${nextTrack['id']}';
      await _player.open(Media(directUrl), play: true);
    } catch (e) {
      debugPrint("🔴 [RADIO] Error reproduciendo pista, saltando... $e");
      _playNextInQueue(); // Fallback automático si un video falla (restricciones de edad, etc)
    }
  }

  void _togglePlayPause() {
    _player.playOrPause();
  }

  void _skipTrack() {
    _player.stop(); // Esto dispara automáticamente el Event Loop de completado
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ==========================================
        // CAPA 1: GRID DE ESTACIONES
        // ==========================================
        Padding(
          padding: const EdgeInsets.only(
            left: 30,
            right: 30,
            top: 40,
            bottom: 120,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Explorar Estaciones",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _status,
                style: TextStyle(
                  color: _isLoading ? Colors.purpleAccent : Colors.white54,
                  fontSize: 14,
                  fontFamily: 'Consolas',
                ),
              ),
              const SizedBox(height: 30),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.purpleAccent,
                        ),
                      )
                    : GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              crossAxisSpacing: 20,
                              mainAxisSpacing: 20,
                              childAspectRatio: 1.1,
                            ),
                        itemCount: _stations.length,
                        itemBuilder: (context, index) {
                          final station = _stations[index];
                          final isActive = _activeStation == station['title'];

                          return InkWell(
                            onTap: () => _tuneInStation(station),
                            borderRadius: BorderRadius.circular(15),
                            child: Container(
                              decoration: BoxDecoration(
                                color: isActive
                                    ? station['color'].withOpacity(0.2)
                                    : const Color(0xFF181818),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: isActive
                                      ? station['color']
                                      : Colors.white12,
                                  width: isActive ? 2 : 1,
                                ),
                                boxShadow: isActive
                                    ? [
                                        BoxShadow(
                                          color: station['color'].withOpacity(
                                            0.3,
                                          ),
                                          blurRadius: 15,
                                        ),
                                      ]
                                    : [],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    station['icon'],
                                    size: 40,
                                    color: station['color'],
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    station['title'],
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        // ==========================================
        // CAPA 2: REPRODUCTOR FLOTANTE (NOW PLAYING)
        // ==========================================
        if (_currentTrack != null)
          Positioned(
            bottom: 30,
            left: 30,
            right: 30,
            child: Container(
              height: 90,
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 20,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // 🛠️ RENDERIZADO DINÁMICO DE PORTADA (API Estática de YouTube)
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                      bottomLeft: Radius.circular(20),
                    ),
                    child: Image.network(
                      'https://img.youtube.com/vi/${_currentTrack!['id']}/mqdefault.jpg',
                      width: 120,
                      height: 90,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 120,
                        color: Colors.grey[900],
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),

                  // METADATA
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _currentTrack!['title']!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          "Radio • $_activeStation",
                          style: const TextStyle(
                            color: Colors.purpleAccent,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // CONTROLES
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                        ),
                        iconSize: 50,
                        color: Colors.white,
                        onPressed: _togglePlayPause,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        iconSize: 40,
                        color: Colors.white70,
                        onPressed: _skipTrack,
                      ),
                      const SizedBox(width: 20),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
