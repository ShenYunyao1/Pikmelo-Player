import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';

import '../../playback/playback_controller.dart';
import 'playback_audio_session.dart';
import 'system_audio_handler.dart';

class SystemMediaService {
  static Future<SystemAudioHandler>? _androidHandler;
  static const _windows = MethodChannel('pikmelo/system_media');

  SystemMediaService._(this.handler, this._focus, this._subscription);

  final SystemAudioHandler handler;
  final PlaybackAudioSession? _focus;
  final StreamSubscription<PlaybackState>? _subscription;

  static Future<SystemMediaService> attach(
    PlaybackController controller, {
    required Future<void> Function() onExit,
  }) async {
    if (Platform.isAndroid) {
      final handler = await (_androidHandler ??= AudioService.init(
        builder: SystemAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'top.shenyunyao.pikmelo_player.playback',
          androidNotificationChannelName: '音乐播放',
          androidStopForegroundOnPause: false,
        ),
      ));
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      final focus = PlaybackAudioSession(
        controller: controller,
        setActive: session.setActive,
        interruptions: session.interruptionEventStream,
        becomingNoisy: session.becomingNoisyEventStream,
      );
      handler.attach(controller);
      return SystemMediaService._(handler, focus, null);
    }
    final handler = SystemAudioHandler()..attach(controller);
    if (!Platform.isWindows) {
      return SystemMediaService._(handler, null, null);
    }
    _windows.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'play':
          await handler.play();
        case 'pause':
          await handler.pause();
        case 'next':
          await handler.skipToNext();
        case 'previous':
          await handler.skipToPrevious();
        case 'stop':
          await handler.stop();
        case 'seek':
          await handler.seek(Duration(milliseconds: call.arguments as int));
        case 'close':
          await onExit();
      }
    });
    try {
      await _windows.invokeMethod<void>('initialize');
    } catch (_) {
      handler.attach(null);
      _windows.setMethodCallHandler(null);
      rethrow;
    }
    final subscription = handler.playbackState.listen((state) {
      final item = handler.mediaItem.value;
      unawaited(
        _windows
            .invokeMethod<void>('update', {
              'hasMedia':
                  item != null &&
                  state.processingState != AudioProcessingState.idle,
              'title': item?.title ?? '',
              'artist': item?.artist ?? '',
              'playing': state.playing,
              'duration': item?.duration?.inMilliseconds ?? 0,
              'position': state.updatePosition.inMilliseconds,
            })
            .catchError((Object error) {
              controller.reportSystemError('Windows 系统媒体状态更新失败，请重启应用后重试。');
            }),
      );
    });
    return SystemMediaService._(handler, null, subscription);
  }

  Future<void> dispose() async {
    handler.attach(null);
    await _focus?.dispose();
    await _subscription?.cancel();
    if (Platform.isWindows) {
      await _windows.invokeMethod<void>('dispose');
      _windows.setMethodCallHandler(null);
    }
  }
}
