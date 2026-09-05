import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/tv_sync_server.dart';
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
  Map<Duration, String> _currentLyrics = {};
  Duration _currentAudioPosition = Duration.zero;
  StreamSubscription? _audioPositionSub;
  StreamSubscription? _audioCompletedSub;

  // 🛡️ MOTOR AISLADO: Jamás toca el player_provider
  final Player _player = Player();
  int _countdown = 0;

  String _tvSyncUrl = "Escaneando red...";
  int _lastTvSyncMs = 0;

  @override
  void initState() {
    super.initState();
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
        } catch (_) {}
      }
    });

    KaraokeCore().currentSingerNotifier.addListener(_onSingerChanged);
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
      setState(() => _tvSyncUrl = 'ws://$hostIp:55056');
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
    } else {
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
                        const Text(
                          "📺 NODO TV (WEBSOCKET)",
                          style: TextStyle(
                            color: Color(0xFFB026FF),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
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
