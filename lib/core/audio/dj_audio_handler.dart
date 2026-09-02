import 'package:audio_service/audio_service.dart';

late DjAudioHandler globalAudioHandler;

Future<void> initGlobalAudioService() async {
  globalAudioHandler = await AudioService.init(
    builder: () => DjAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.djstudio.player.channel.audio',
      androidNotificationChannelName: 'DjStudio Playback',
      // 🛠️ FIX ARQUITECTÓNICO: Se elimina androidNotificationOngoing.
      // Al mantener StopForegroundOnPause en false, la notificación
      // asume el estado persistente automáticamente sin romper la aserción de compilación.
      androidStopForegroundOnPause: false,
    ),
  );
}

class DjAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // Callbacks inyectados desde Riverpod
  void Function()? onPlayPause;
  void Function()? onNext;
  void Function()? onPrevious;
  void Function(Duration)? onSeek;

  DjAudioHandler() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  @override
  Future<void> play() async => onPlayPause?.call();

  @override
  Future<void> pause() async => onPlayPause?.call();

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  void updateOsMetadata({required String title, required Duration duration}) {
    mediaItem.add(
      MediaItem(
        id: title,
        album: 'DjStudio Master',
        title: title,
        duration: duration,
      ),
    );
  }

  void updateOsPlaybackState(bool isPlaying, Duration position) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        playing: isPlaying,
        updatePosition: position,
        processingState: AudioProcessingState.ready,
      ),
    );
  }
}
