import 'package:flutter/material.dart';

import '../../library/ui/track_details.dart';
import '../../shared/widgets/music_artwork.dart';
import '../playback_controller.dart';
import 'playback_controls.dart';
import 'queue_page.dart';
import 'scrolling_track_text.dart';
import 'volume_button.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final item = controller.current;
      final error = controller.state.error ?? controller.systemError;
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '收起播放器',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          title: const Text('正在播放'),
          centerTitle: true,
          actions: [
            PopupMenuButton<String>(
              tooltip: '播放选项',
              onSelected: (value) {
                if (value == 'stop') controller.stop();
                if (value == 'details' && item != null) {
                  showTrackDetails(
                    context,
                    item.track,
                    load: controller.loadMetadata == null
                        ? null
                        : () => controller.loadMetadata!(item),
                  );
                }
              },
              itemBuilder: (_) => [
                if (item != null)
                  const PopupMenuItem(value: 'details', child: Text('曲目信息')),
                const PopupMenuItem(value: 'stop', child: Text('停止播放')),
              ],
            ),
          ],
        ),
        body: item == null
            ? Center(child: Text(error ?? '选择曲目开始播放，未下载曲目会先下载'))
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final artworkSize = (constraints.maxHeight * 0.378)
                        .clamp(108.0, 306.0)
                        .clamp(
                          0.0,
                          (constraints.maxWidth - 40).clamp(
                            0.0,
                            double.infinity,
                          ),
                        );
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Column(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  20,
                                  20,
                                  24,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Center(
                                      child: MusicArtwork(
                                        title: item.track.title,
                                        size: artworkSize,
                                        artwork: controller.loadArtwork?.call(
                                          item,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    KeyedSubtree(
                                      key: ValueKey(
                                        '${item.serverUri}#${item.track.id}',
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          ScrollingTrackText(
                                            text: item.track.title,
                                            style:
                                                theme.textTheme.headlineSmall!,
                                          ),
                                          const SizedBox(height: 4),
                                          ScrollingTrackText(
                                            text: item.track.artist ?? '',
                                            style: theme.textTheme.bodyLarge!,
                                          ),
                                          const SizedBox(height: 4),
                                          ScrollingTrackText(
                                            text: item.track.album ?? '',
                                            style: theme.textTheme.bodyMedium!,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      controller.loading ||
                                              controller.state.buffering
                                          ? '正在载入音频…'
                                          : '本地播放',
                                      style: theme.textTheme.labelMedium,
                                    ),
                                    if (error != null)
                                      Text(
                                        error,
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                    if (controller.loading)
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: TextButton(
                                          onPressed: controller.stop,
                                          child: const Text('取消播放准备'),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  PlaybackProgress(controller: controller),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.track.bitrateKbps == null
                                        ? '码率未知'
                                        : '${item.track.bitrateKbps} kbps',
                                    style: theme.textTheme.labelSmall,
                                    maxLines: 1,
                                  ),
                                  const SizedBox(height: 8),
                                  LayoutBuilder(
                                    builder: (context, constraints) {
                                      final extent =
                                          ((constraints.maxWidth - 64) / 6)
                                              .clamp(0.0, 48.0);
                                      return Row(
                                        children: [
                                          SizedBox(
                                            width: extent * 2,
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  width: extent,
                                                  child: VolumeButton(
                                                    controller: controller,
                                                  ),
                                                ),
                                                SizedBox(
                                                  width: extent,
                                                  child: PlaybackModeButton(
                                                    controller: controller,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            child: TransportControls(
                                              controller: controller,
                                              expanded: true,
                                              showMode: false,
                                              buttonExtent: extent,
                                            ),
                                          ),
                                          SizedBox(
                                            width: extent * 2,
                                            child: Row(
                                              children: [
                                                SizedBox(
                                                  width: extent,
                                                  child: IconButton(
                                                    tooltip: '播放队列',
                                                    icon: const Icon(
                                                      Icons.queue_music,
                                                    ),
                                                    onPressed: () =>
                                                        showPlaybackQueue(
                                                          context,
                                                          controller,
                                                        ),
                                                  ),
                                                ),
                                                SizedBox(
                                                  key: const ValueKey(
                                                    'player-action-placeholder',
                                                  ),
                                                  width: extent,
                                                  height: 48,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
      );
    },
  );
}
