import 'package:flutter/material.dart';

import '../../shared/widgets/music_artwork.dart';
import '../playback_controller.dart';

Future<void> showPlaybackQueue(
  BuildContext context,
  PlaybackController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: QueueContents(controller: controller),
    ),
  ),
);

class QueuePage extends StatelessWidget {
  const QueuePage({super.key, required this.controller});
  final PlaybackController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放队列')),
    body: QueueContents(controller: controller),
  );
}

class QueueContents extends StatelessWidget {
  const QueueContents({super.key, required this.controller, this.onClose});
  final PlaybackController controller;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '播放队列',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: '收起队列',
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(
          child: controller.queue.isEmpty
              ? const Center(child: Text('播放队列为空'))
              : ListView.builder(
                  itemCount: controller.queue.length,
                  itemBuilder: (context, index) {
                    final item = controller.queue[index];
                    return ListTile(
                      selected: index == controller.currentIndex,
                      selectedTileColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.1),
                      leading: MusicArtwork(title: item.track.title, size: 40),
                      title: Text(
                        item.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.track.artist ?? '本地音频',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: index == controller.currentIndex
                          ? const Icon(Icons.equalizer, size: 18)
                          : null,
                      onTap: () => controller.jump(index),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
