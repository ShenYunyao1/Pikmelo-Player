import 'package:flutter/material.dart';

import '../../playback/models/playback_state.dart';
import '../connection_controller.dart';
import 'setting_choice.dart';

String playbackModeLabel(PlaybackMode mode) => switch (mode) {
  PlaybackMode.sequence => '顺序播放',
  PlaybackMode.repeatAll => '列表循环',
  PlaybackMode.repeatOne => '单曲循环',
  PlaybackMode.shuffle => '随机播放',
};

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({super.key, required this.controller});
  final ConnectionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.playback]),
    builder: (context, _) => ListView(
      children: [
        if (controller.playback case final player?) ...[
          SwitchListTile(
            title: const Text('启动时恢复播放队列'),
            subtitle: const Text('恢复当前曲目和进度，保持暂停'),
            value: controller.restorePlaybackEnabled,
            onChanged: controller.mediaStorage == null
                ? null
                : controller.setRestorePlayback,
          ),
          ListTile(
            title: const Text('默认播放模式'),
            subtitle: Text(
              '${playbackModeLabel(player.defaultMode)}\n新建队列时采用，恢复队列时沿用保存模式',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final value = await chooseSetting(
                context,
                '默认播放模式',
                player.defaultMode,
                {
                  for (final mode in PlaybackMode.values)
                    mode: playbackModeLabel(mode),
                },
              );
              if (value != null && context.mounted) {
                player.setDefaultMode(value);
              }
            },
          ),
          ListTile(
            title: Text('应用音量 ${player.volume.round()}%'),
            subtitle: Slider(
              value: player.volume,
              max: 100,
              label: '${player.volume.round()}%',
              semanticFormatterCallback: (value) => '音量 ${value.round()}%',
              onChanged: player.setVolume,
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            Theme.of(context).platform == TargetPlatform.windows
                ? '最小化继续播放，关闭窗口退出'
                : '支持后台与锁屏播放，断开耳机时暂停',
          ),
        ),
      ],
    ),
  );
}
