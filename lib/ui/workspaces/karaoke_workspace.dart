import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/tv_sync_server.dart';
import '../../services/tv_adb_deployment_service.dart';
// 🛠️ NUEVO
import 'package:media_kit/media_kit.dart';

// ----------------------------------------------------------------------
// 1. SINGLETON (Puente de Memoria RAM entre el Servidor REST y la UI)
// ----------------------------------------------------------------------
class KaraokeCore {
  static final KaraokeCore _instance = KaraokeCore._internal();
  factory KaraokeCore() => _instance;
  KaraokeCore._internal();

  final ValueNotifier<List<Map<String, dynamic>>> queueNotifier = ValueNotifier(
    [],
  );
  final ValueNotifier<Map<String, int>> votesNotifier = ValueNotifier({
    '🔥': 0,
    '💩': 0,
    '👏': 0,
  });
  final ValueNotifier<Map<String, String>> currentSingerNotifier =
      ValueNotifier({});

  void addToQueue(String user, String songPath) {
    final currentQueue = List<Map<String, dynamic>>.from(queueNotifier.value);
    currentQueue.add({'user': user, 'song': songPath});
    queueNotifier.value = currentQueue;
  }

  void addVote(String type) {
    if (votesNotifier.value.containsKey(type)) {
      final currentVotes = Map<String, int>.from(votesNotifier.value);
      currentVotes[type] = currentVotes[type]! + 1;
      votesNotifier.value = currentVotes;
    }
  }

  void popNextSong() {
    final currentQueue = List<Map<String, dynamic>>.from(queueNotifier.value);
    if (currentQueue.isNotEmpty) {
      final next = currentQueue.removeAt(0);
      currentSingerNotifier.value = {
        'user': next['user'],
        'song': next['song'],
      };
      queueNotifier.value = currentQueue;
      votesNotifier.value = {'🔥': 0, '💩': 0, '👏': 0};
    } else {
      currentSingerNotifier.value = {};
    }
  }
}

// ----------------------------------------------------------------------
// 2. MÓDULO UI: KARAOKE WORKSPACE (Inyectado con Telemetría TV)
// ----------------------------------------------------------------------
class KaraokeWorkspace extends ConsumerStatefulWidget {
  const KaraokeWorkspace({super.key});

  @override
  ConsumerState<KaraokeWorkspace> createState() => _KaraokeWorkspaceState();
}

class _KaraokeWorkspaceState extends ConsumerState<KaraokeWorkspace> {
  final ScrollController _lrcScrollController = ScrollController();
  final TvAdbDeploymentService _tvDeploymentService = TvAdbDeploymentService();
  Map<Duration, String> _currentLyrics = {};
  Duration _currentAudioPosition = Duration.zero;
  StreamSubscription? _audioPositionSub;
  StreamSubscription? _audioCompletedSub;

  // 🛡️ MOTOR AISLADO: Jamás toca el player_provider
  final Player _player = Player();
  int _countdown = 0;

  String _tvSyncUrl = "Escaneando red...";
  String _hostIp = '127.0.0.1';
  int _lastTvSyncMs = 0;

  @override
  void initState() {
    super.initState();
    // El nodo WS :55056 es lazy. Sin esta lectura la TV no tiene a quién
    // conectarse hasta que suene la primera pista.
    ref.read(tvSyncProvider);
    unawaited(_ensureTvFirewallRule());
    _fetchTvSyncUrl();

    _audioPositionSub = _player.stream.position.listen((Duration position) {
      if (mounted) {
        setState(() => _currentAudioPosition = position);
        _syncLyricsScroll();
        _updateCountdown();

        final posMs = position.inMilliseconds;
        if ((posMs - _lastTvSyncMs).abs() > 500) {
          _lastTvSyncMs = posMs;
          try {
            ref.read(tvSyncProvider).broadcastSyncPing(posMs, true);
          } catch (_) {}
        }
      }
    });

    // 🛡️ STOP ABSOLUTO AL TERMINAR
    _audioCompletedSub = _player.stream.completed.listen((completed) {
      if (completed && mounted) {
        _player.stop();
        setState(() {
          _currentLyrics = {};
          _countdown = 0;
        });
        try {
          ref.read(tvSyncProvider).broadcastSyncPing(0, false);
          ref.read(tvSyncProvider).broadcastEdgeStop();
        } catch (_) {}
      }
    });

    KaraokeCore().currentSingerNotifier.addListener(_onSingerChanged);
  }

  /// Abre el puerto del nodo TV en Windows Defender. La regla de LAN Sync solo
  /// cubre :55055; sin esta, la Google TV no completa el upgrade WebSocket.
  Future<void> _ensureTvFirewallRule() async {
    if (!Platform.isWindows) return;
    const ruleName = 'DjStudio TV Sync';
    try {
      final probe = await Process.run('powershell', [
        '-Command',
        'Get-NetFirewallRule -DisplayName "$ruleName" '
            '-ErrorAction SilentlyContinue',
      ]);
      if (probe.stdout.toString().contains(ruleName)) return;

      await Process.run('powershell', [
        '-Command',
        'Start-Process powershell -Verb runAs -WindowStyle Hidden '
            '-ArgumentList "-Command New-NetFirewallRule '
            "-DisplayName '$ruleName' -Direction Inbound "
            '-LocalPort 55056 -Protocol TCP -Action Allow"',
      ]);
    } catch (e) {
      debugPrint('🔴 [KARAOKE TV] Firewall :55056 $e');
    }
  }

  Future<void> _fetchTvSyncUrl() async {
    String hostIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty) {
        hostIp = interfaces.first.addresses.first.address;
      }
    } catch (e) {
      debugPrint("🔴 Error obteniendo IP para TV Sync: $e");
    }
    if (mounted) {
      setState(() {
        _hostIp = hostIp;
        _tvSyncUrl = 'ws://$hostIp:55056';
      });
    }
  }

  void _dispatchEdgeExecute({
    required String audioPath,
    required String originalPath,
    required String singer,
  }) {
    try {
      final lrcPath = originalPath.replaceAll(
        RegExp(r'\.mp3$', caseSensitive: false),
        '.lrc',
      );
      final trackName = originalPath.replaceAll('\\', '/').split('/').last;
      final encodedAudio = Uri.encodeQueryComponent(audioPath);
      final encodedLrc = Uri.encodeQueryComponent(lrcPath);
      ref
          .read(tvSyncProvider)
          .broadcastEdgeExecute(
            mp3Url: 'http://$_hostIp:55056/karaoke/audio?p=$encodedAudio',
            lrcUrl: 'http://$_hostIp:55056/karaoke/lrc?p=$encodedLrc',
            trackName: trackName,
            singer: singer,
          );
    } catch (e) {
      debugPrint('🔴 [KARAOKE TV] EDGE_EXECUTE: $e');
    }
  }

  @override
  void dispose() {
    KaraokeCore().currentSingerNotifier.removeListener(_onSingerChanged);
    _audioPositionSub?.cancel();
    _audioCompletedSub?.cancel();
    _lrcScrollController.dispose();
    _player.dispose();
    super.dispose();
  }

  void _onSingerChanged() {
    final songData = KaraokeCore().currentSingerNotifier.value;
    if (songData.containsKey('song')) {
      final originalPath = songData['song']!;
      _loadLrc(originalPath);

      final karaokePath = originalPath.replaceAll(
        RegExp(r'\.mp3$', caseSensitive: false),
        '_K.mp3',
      );
      final fileK = File(karaokePath);
      final finalAudioPath = fileK.existsSync() ? karaokePath : originalPath;

      _player.open(Media(finalAudioPath));
      _player.play();
      _dispatchEdgeExecute(
        audioPath: finalAudioPath,
        originalPath: originalPath,
        singer: songData['user'] ?? '',
      );
    } else {
      try {
        ref.read(tvSyncProvider).broadcastEdgeStop();
      } catch (_) {}
      _player.stop();
      setState(() {
        _currentLyrics = {};
        _countdown = 0;
      });
      try {
        ref.read(tvSyncProvider).broadcastSyncPing(0, false);
      } catch (_) {}
    }
  }

  void _loadLrc(String mp3Path) {
    final lrcPath = mp3Path.replaceAll(
      RegExp(r'\.mp3$', caseSensitive: false),
      '.lrc',
    );
    final file = File(lrcPath);

    if (file.existsSync()) {
      final rawLrcContent = file.readAsStringSync();
      final Map<Duration, String> lyrics = {};
      final RegExp timeRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

      for (var line in rawLrcContent.split('\n')) {
        final match = timeRegex.firstMatch(line);
        if (match != null) {
          final int min = int.parse(match.group(1)!);
          final int sec = int.parse(match.group(2)!);
          final String msStr = match.group(3)!;
          final int ms = msStr.length == 2
              ? int.parse(msStr) * 10
              : int.parse(msStr);
          final text = match.group(4)!.trim();
          if (text.isNotEmpty) {
            lyrics[Duration(minutes: min, seconds: sec, milliseconds: ms)] =
                text;
          }
        }
      }
      setState(() => _currentLyrics = lyrics);

      final trackName = mp3Path.replaceAll('\\', '/').split('/').last;
      try {
        ref.read(tvSyncProvider).broadcastLrcTrack(trackName, rawLrcContent);
      } catch (_) {}
    } else {
      setState(
        () => _currentLyrics = {
          Duration.zero: "No hay letra (.lrc) disponible para esta pista.",
        },
      );
    }
  }

  void _syncLyricsScroll() {
    if (_currentLyrics.isEmpty || !_lrcScrollController.hasClients) return;
    final keys = _currentLyrics.keys.toList();
    int nextIdx = keys.indexWhere((k) => k > _currentAudioPosition);
    int activeIndex = nextIdx == -1 ? keys.length - 1 : nextIdx - 1;
    if (activeIndex < 0) activeIndex = 0;

    const itemHeight = 80.0;
    double targetOffset = 0.0;
    try {
      final viewportHeight = _lrcScrollController.position.viewportDimension;
      targetOffset =
          (activeIndex * itemHeight) - (viewportHeight / 2) + (itemHeight / 2);
      if (targetOffset < 0) targetOffset = 0;
      final maxScroll = _lrcScrollController.position.maxScrollExtent;
      if (targetOffset > maxScroll) targetOffset = maxScroll;
    } catch (_) {
      targetOffset = activeIndex * itemHeight;
    }

    _lrcScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _updateCountdown() {
    if (_currentLyrics.isEmpty) {
      if (_countdown != 0) setState(() => _countdown = 0);
      return;
    }
    final keys = _currentLyrics.keys.toList();
    final nextIndex = keys.indexWhere((k) => k > _currentAudioPosition);

    if (nextIndex != -1) {
      final nextTime = keys[nextIndex];
      final diff = nextTime - _currentAudioPosition;

      bool isLargeGap = (nextIndex == 0);
      if (!isLargeGap && nextIndex > 0) {
        final prevTime = keys[nextIndex - 1];
        if ((nextTime - prevTime).inSeconds > 5 &&
            (_currentAudioPosition - prevTime).inSeconds > 1) {
          isLargeGap = true;
        }
      }

      if (isLargeGap && diff.inSeconds <= 4 && diff.inSeconds > 0) {
        if (_countdown != diff.inSeconds) {
          setState(() => _countdown = diff.inSeconds);
        }
      } else {
        if (_countdown != 0) setState(() => _countdown = 0);
      }
    } else {
      if (_countdown != 0) setState(() => _countdown = 0);
    }
  }

  Future<void> _showQrModal(BuildContext context) async {
    String hostIp = '127.0.0.1';
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isNotEmpty) {
        hostIp = interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final String karaokeUrl = 'http://$hostIp:55055/karaoke?v=$timestamp';
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return Dialog(
          backgroundColor: const Color(0xFF101010),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF00FFFF), width: 2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(25.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "🎤 ESCANEA PARA CANTAR",
                  style: TextStyle(
                    color: Color(0xFF39FF14),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(10),
                  height: 250,
                  width: 250,
                  child: QrImageView(
                    data: karaokeUrl,
                    version: QrVersions.auto,
                    size: 230.0,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  karaokeUrl,
                  style: const TextStyle(
                    color: Color(0xFF00FFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF39FF14),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    "CERRAR",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showTvInstaller() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TvDeploymentDialog(service: _tvDeploymentService),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Row(
        children: [
          Expanded(
            flex: 7,
            child: Container(
              padding: const EdgeInsets.all(40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ValueListenableBuilder<Map<String, String>>(
                    valueListenable: KaraokeCore().currentSingerNotifier,
                    builder: (context, currentSinger, _) {
                      if (currentSinger.isEmpty) return const SizedBox.shrink();
                      final songName =
                          currentSinger['song']
                              ?.replaceAll('\\', '/')
                              .split('/')
                              .last
                              .replaceAll(
                                RegExp(r'\.mp3$', caseSensitive: false),
                                '',
                              ) ??
                          '';
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00FFFF).withAlpha(25),
                          border: Border.all(color: const Color(0xFF00FFFF)),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: Text(
                          "🎤 Cantando: ${currentSinger['user']} - $songName",
                          style: const TextStyle(
                            color: Color(0xFF00FFFF),
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 50),
                  Expanded(
                    child: _currentLyrics.isEmpty
                        ? const Center(
                            child: Text(
                              "Esperando pista...",
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 30,
                              ),
                            ),
                          )
                        : Stack(
                            alignment: Alignment.center,
                            children: [
                              ListView.builder(
                                controller: _lrcScrollController,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _currentLyrics.length,
                                itemBuilder: (context, index) {
                                  final entry = _currentLyrics.entries
                                      .elementAt(index);
                                  final keys = _currentLyrics.keys.toList();
                                  int nextIdx = keys.indexWhere(
                                    (k) => k > _currentAudioPosition,
                                  );
                                  int activeIdx = nextIdx == -1
                                      ? keys.length - 1
                                      : nextIdx - 1;
                                  if (activeIdx < 0) activeIdx = 0;

                                  final isActive = index == activeIdx;
                                  final isPassed = index < activeIdx;

                                  return Container(
                                    height: 80.0,
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    child: Text(
                                      entry.value,
                                      style: TextStyle(
                                        color: isActive
                                            ? const Color(0xFF39FF14)
                                            : (isPassed
                                                  ? Colors.white38
                                                  : Colors.white70),
                                        fontSize: isActive ? 34 : 26,
                                        fontWeight: isActive
                                            ? FontWeight.w900
                                            : FontWeight.normal,
                                        shadows: isActive
                                            ? [
                                                const Shadow(
                                                  color: Color(0xFF39FF14),
                                                  blurRadius: 15,
                                                ),
                                              ]
                                            : [],
                                      ),
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  );
                                },
                              ),
                              if (_countdown > 0)
                                AnimatedOpacity(
                                  duration: const Duration(milliseconds: 150),
                                  opacity: _countdown > 0 ? 1.0 : 0.0,
                                  child: Container(
                                    padding: const EdgeInsets.all(40),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF0A0A0A,
                                      ).withValues(alpha: 0.9),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF39FF14),
                                        width: 5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(
                                            0xFF39FF14,
                                          ).withValues(alpha: 0.4),
                                          blurRadius: 50,
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      _countdown.toString(),
                                      style: const TextStyle(
                                        fontSize: 140,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF39FF14),
                                        shadows: [
                                          Shadow(
                                            color: Color(0xFF39FF14),
                                            blurRadius: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white10),
          Expanded(
            flex: 3,
            child: Container(
              color: const Color(0xFF101010),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(15),
                    color: const Color(0xFF1A1A1A),
                    width: double.infinity,
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "📺 NODO TV (WEBSOCKET)",
                              style: TextStyle(
                                color: Color(0xFFB026FF),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              onPressed: _showTvInstaller,
                              icon: const Icon(
                                Icons.search,
                                color: Color(0xFF39FF14),
                              ),
                              tooltip: 'Buscar e instalar en Google TV',
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _tvSyncUrl,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontFamily: 'Consolas',
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white10),
                  Container(
                    padding: const EdgeInsets.all(20),
                    color: Colors.black,
                    child: Column(
                      children: [
                        const Text(
                          "REACCIÓN DEL PÚBLICO",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        ValueListenableBuilder<Map<String, int>>(
                          valueListenable: KaraokeCore().votesNotifier,
                          builder: (context, votes, _) {
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _buildStatBadge(
                                  '👏',
                                  votes['👏'] ?? 0,
                                  const Color(0xFF00FFFF),
                                ),
                                _buildStatBadge(
                                  '🔥',
                                  votes['🔥'] ?? 0,
                                  const Color(0xFFFF3366),
                                ),
                                _buildStatBadge(
                                  '💩',
                                  votes['💩'] ?? 0,
                                  const Color(0xFFFFAA00),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(15),
                    color: const Color(0xFF1A1A1A),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "SIGUIENTES EN LA COLA",
                          style: TextStyle(
                            color: Color(0xFF39FF14),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.qr_code_2,
                            color: Color(0xFF00FFFF),
                            size: 30,
                          ),
                          onPressed: () => _showQrModal(context),
                          tooltip: 'Mostrar Código QR',
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                      valueListenable: KaraokeCore().queueNotifier,
                      builder: (context, queue, _) {
                        return ListView.builder(
                          itemCount: queue.length,
                          itemBuilder: (context, index) {
                            final req = queue[index];
                            final songName = req['song']
                                .toString()
                                .replaceAll('\\', '/')
                                .split('/')
                                .last
                                .replaceAll(
                                  RegExp(r'\.mp3$', caseSensitive: false),
                                  '',
                                );
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: const Color(
                                  0xFF39FF14,
                                ).withAlpha(50),
                                child: const Icon(
                                  Icons.person,
                                  color: Color(0xFF39FF14),
                                ),
                              ),
                              title: Text(
                                req['user'],
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                songName,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              trailing: Text(
                                "#${index + 1}",
                                style: const TextStyle(color: Colors.white38),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    color: Colors.black,
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FFFF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                      ),
                      onPressed: () => KaraokeCore().popNextSong(),
                      child: const Text(
                        "LLAMAR AL SIGUIENTE ⏭️",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatBadge(String emoji, int count, Color color) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 32)),
        const SizedBox(height: 5),
        Text(
          count.toString(),
          style: TextStyle(
            color: color,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class TvDeploymentDialog extends StatefulWidget {
  final TvAdbDeploymentService service;

  const TvDeploymentDialog({super.key, required this.service});

  @override
  State<TvDeploymentDialog> createState() => _TvDeploymentDialogState();
}

class _TvDeploymentDialogState extends State<TvDeploymentDialog> {
  List<TvAdbTarget> _targets = const [];
  bool _busy = false;
  String _status = 'Activa Depuración inalámbrica en Google TV.';

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Buscando Google TV por ADB/mDNS…';
    });
    try {
      final targets = await widget.service.discover();
      if (!mounted) return;
      setState(() {
        _targets = targets;
        _status = targets.isEmpty
            ? 'No se encontró TV. Activa Opciones de desarrollador → '
                  'Depuración inalámbrica.'
            : '${targets.length} destino(s) detectado(s).';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Error de radar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pair(TvAdbTarget target) async {
    final endpointController = TextEditingController(
      text: target.pairingEndpoint ?? '${target.host}:',
    );
    final codeController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Emparejar Google TV',
          style: TextStyle(color: Color(0xFF39FF14)),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'En la TV entra en Depuración inalámbrica → Emparejar '
                'dispositivo. Copia el IP:PUERTO y el código de 6 dígitos que '
                'muestra esa pantalla; ese puerto es distinto al de conexión.',
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: endpointController,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Consolas',
                ),
                decoration: const InputDecoration(
                  labelText: 'IP:puerto de emparejamiento',
                  hintText: '192.168.1.9:38791',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeController,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  letterSpacing: 5,
                ),
                decoration: const InputDecoration(
                  labelText: 'Código de vinculación',
                  labelStyle: TextStyle(color: Colors.white54),
                ),
                onSubmitted: (_) => Navigator.pop(dialogContext, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('EMPAREJAR'),
          ),
        ],
      ),
    );

    final endpoint = endpointController.text.trim();
    final code = codeController.text.trim();
    endpointController.dispose();
    codeController.dispose();

    if (confirmed != true || code.isEmpty) return;
    if (!RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}:\d+$').hasMatch(endpoint)) {
      setState(() => _status = 'IP:puerto de emparejamiento inválido.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Emparejando $endpoint…';
    });
    try {
      await widget.service.pair(endpoint: endpoint, code: code);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'TV emparejada. Actualizando radar…';
      });
      await _scan();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Emparejamiento fallido: $e';
      });
    }
  }

  Future<void> _addManualEndpoint() async {
    final controller = TextEditingController(text: '192.168.1.');
    final endpoint = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF121212),
        title: const Text(
          'Conexión ADB manual',
          style: TextStyle(color: Color(0xFF00FFFF)),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'Consolas'),
          decoration: const InputDecoration(
            labelText: 'IP:puerto que muestra la TV',
            hintText: '192.168.1.40:5555',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('AÑADIR'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (endpoint == null || !endpoint.contains(':')) return;
    setState(() {
      _targets = [
        ..._targets,
        TvAdbTarget(
          endpoint: endpoint.trim(),
          name: 'Google TV manual',
          state: TvAdbTargetState.discoverable,
        ),
      ];
    });
  }

  Future<void> _install(TvAdbTarget target) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Preparando instalación…';
    });
    try {
      await widget.service.buildInstallAndLaunch(
        target: target,
        onProgress: (message) {
          if (mounted) setState(() => _status = message);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _status = 'Instalación fallida: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B0D10),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF39FF14)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.live_tv, color: Color(0xFF39FF14), size: 32),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DEPLOY GOOGLE TV',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                            letterSpacing: 2,
                          ),
                        ),
                        Text(
                          'Compila, instala y abre DJ Studio Karaoke',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _scan,
                    tooltip: 'Buscar TV',
                    icon: const Icon(Icons.search, color: Color(0xFF39FF14)),
                  ),
                  IconButton(
                    onPressed: _busy ? null : _addManualEndpoint,
                    tooltip: 'IP manual',
                    icon: const Icon(Icons.add_link, color: Color(0xFF00FFFF)),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: const Text(
                  'TV: Ajustes → Sistema → Información → pulsa “Compilación” '
                  '7 veces → Opciones de desarrollador → Depuración '
                  'inalámbrica → Emparejar dispositivo.\n'
                  'La primera vez pulsa 🔑 en la TV listada y escribe el '
                  'IP:PUERTO y el código de la pantalla; recién después usa '
                  'INSTALAR Y ABRIR.',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _targets.isEmpty
                    ? Center(
                        child: _busy
                            ? const CircularProgressIndicator(
                                color: Color(0xFF39FF14),
                              )
                            : const Icon(
                                Icons.tv_off,
                                color: Colors.white24,
                                size: 72,
                              ),
                      )
                    : ListView.separated(
                        itemCount: _targets.length,
                        separatorBuilder: (_, _) =>
                            const Divider(color: Colors.white10),
                        itemBuilder: (context, index) {
                          final target = _targets[index];
                          final needsPairing =
                              target.state == TvAdbTargetState.pairingRequired;
                          return ListTile(
                            leading: Icon(
                              needsPairing ? Icons.lock : Icons.tv,
                              color: needsPairing
                                  ? const Color(0xFFFFAA00)
                                  : const Color(0xFF39FF14),
                            ),
                            title: Text(
                              target.name,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              target.endpoint,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontFamily: 'Consolas',
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _busy ? null : () => _pair(target),
                                  tooltip: 'Emparejar con código de la TV',
                                  icon: const Icon(
                                    Icons.key,
                                    size: 20,
                                    color: Color(0xFFFFAA00),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                ElevatedButton.icon(
                                  onPressed: _busy || needsPairing
                                      ? null
                                      : () => _install(target),
                                  icon: const Icon(
                                    Icons.install_mobile,
                                    size: 17,
                                  ),
                                  label: const Text('INSTALAR Y ABRIR'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFF111820),
                child: Row(
                  children: [
                    if (_busy) ...[
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00FFFF),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                          color: Color(0xFF00FFFF),
                          fontFamily: 'Consolas',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
