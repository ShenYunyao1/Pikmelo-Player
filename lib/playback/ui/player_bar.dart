import 'package:flutter/material.dart';

import 'player_artwork.dart';
import '../playback_controller.dart';
import 'now_playing_page.dart';
import 'playback_controls.dart';
import 'queue_page.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.controller});
  final PlaybackController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final item = controller.current;
      final error = controller.state.error ?? controller.systemError;
      if (item == null && error == null) return const SizedBox.shrink();
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (item != null)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 760;
                      final title = InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NowPlayingPage(controller: controller),
                          ),
                        ),
                        child: Row(
                          children: [
                            PlayerArtwork(
                              item: item,
                              size: 48,
                              loadArtwork: controller.loadArtwork,
                              revision: controller.artworkRevision?.call() ?? 0,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    item.track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    controller.loading
                                        ? '正在载入音频…'
                                        : item.track.artist ?? '本地播放',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                      return Row(
                        children: [
                          Expanded(flex: 3, child: title),
                          if (wide)
                            Expanded(
                              flex: 5,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TransportControls(controller: controller),
                                  PlaybackProgress(controller: controller),
                                ],
                              ),
                            )
                          else ...[
                            IconButton(
                              tooltip: controller.state.playing ? '暂停' : '播放',
                              onPressed: controller.loading
                                  ? null
                                  : controller.toggle,
                              icon: Icon(
                                controller.state.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                            IconButton(
                              tooltip: '下一首',
                              onPressed: controller.next,
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                          ],
                          if (wide) ...[
                            const SizedBox(width: 20),
                            const Icon(Icons.volume_up_outlined, size: 20),
                            SizedBox(
                              width: 110,
                              child: Slider(
                                label: '音量',
                                value: controller.volume,
                                max: 100,
                                semanticFormatterCallback: (value) =>
                                    '音量 ${value.round()}%',
                                onChanged: controller.setVolume,
                              ),
                            ),
                            IconButton(
                              tooltip: '播放队列',
                              icon: const Icon(Icons.queue_music),
                              onPressed: () =>
                                  showPlaybackQueue(context, controller),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
