import 'package:flutter/material.dart';

import '../../shared/widgets/music_artwork.dart';
import '../playback_controller.dart';
import 'playback_controls.dart';
import 'queue_page.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.controller});
  final PlaybackController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final item = controller.current;
      final error = controller.state.error ?? controller.systemError;
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
                if (value == 'stop') controller.clear();
                if (value == 'volume') {
                  showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Row(
                            children: [
                              const Text('音量'),
                              Expanded(
                                child: Slider(
                                  label: '音量',
                                  value: controller.volume,
                                  max: 100,
                                  onChanged: controller.setVolume,
                                  semanticFormatterCallback: (value) =>
                                      '音量 ${value.round()}%',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'volume', child: Text('音量')),
                PopupMenuItem(value: 'stop', child: Text('停止播放')),
              ],
            ),
          ],
        ),
        body: item == null
            ? Center(child: Text(error ?? '选择曲目开始播放，未下载曲目会先下载'))
            : SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final artworkSize = (constraints.maxHeight * 0.42)
                        .clamp(120.0, 340.0)
                        .clamp(0.0, constraints.maxWidth - 40);
                    return SingleChildScrollView(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(
                                  child: MusicArtwork(
                                    title: item.track.title,
                                    size: artworkSize,
                                  ),
                                ),
                                const SizedBox(height: 28),
                                Text(
                                  item.track.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall,
                                ),
                                if (item.track.artist != null)
                                  Text(
                                    item.track.artist!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyLarge,
                                  ),
                                const SizedBox(height: 12),
                                Text(
                                  controller.loading ||
                                          controller.state.buffering
                                      ? '正在载入音频…'
                                      : '本地播放',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelMedium,
                                ),
                                if (error != null)
                                  Text(
                                    error,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                if (controller.loading)
                                  TextButton(
                                    onPressed: controller.clear,
                                    child: const Text('取消播放准备'),
                                  ),
                                const SizedBox(height: 20),
                                PlaybackProgress(controller: controller),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TransportControls(
                                        controller: controller,
                                        expanded: true,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '播放队列',
                                      icon: const Icon(Icons.queue_music),
                                      onPressed: () => showPlaybackQueue(
                                        context,
                                        controller,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('播放队列'),
                                  subtitle: Text(
                                    '${controller.queue.length} 首曲目',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () =>
                                      showPlaybackQueue(context, controller),
                                ),
                              ],
                            ),
                          ),
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
