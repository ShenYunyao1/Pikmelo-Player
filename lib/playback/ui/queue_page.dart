import 'package:flutter/material.dart';

import '../../shared/widgets/music_artwork.dart';
import '../playback_controller.dart';
import '../../library/ui/track_details.dart';
import 'playback_controls.dart';

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
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  onReorderItem: controller.move,
                  itemCount: controller.queue.length,
                  itemBuilder: (context, index) {
                    final item = controller.queue[index];
                    return ListTile(
                      key: ObjectKey(item),
                      selected: index == controller.currentIndex,
                      selectedTileColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.1),
                      leading: MusicArtwork(
                        title: item.track.title,
                        size: 40,
                        artwork: controller.loadArtwork?.call(item),
                      ),
                      title: Text(
                        item.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          item.track.subtitle.isEmpty
                              ? '未知歌手'
                              : item.track.subtitle,
                          if (item.track.duration != null)
                            playbackTime(item.track.duration!),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (index == controller.currentIndex)
                            const Icon(Icons.equalizer, size: 18),
                          PopupMenuButton<String>(
                            tooltip: '队列曲目操作',
                            onSelected: (action) {
                              final currentIndex = controller.queue.indexOf(
                                item,
                              );
                              if (currentIndex < 0) return;
                              switch (action) {
                                case 'details':
                                  showTrackDetails(
                                    context,
                                    item.track,
                                    load: controller.loadMetadata == null
                                        ? null
                                        : () => controller.loadMetadata!(item),
                                  );
                                case 'up':
                                  controller.move(
                                    currentIndex,
                                    currentIndex - 1,
                                  );
                                case 'down':
                                  controller.move(
                                    currentIndex,
                                    currentIndex + 1,
                                  );
                                case 'remove':
                                  controller.remove(currentIndex);
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'details',
                                child: Text('曲目信息'),
                              ),
                              if (index > 0)
                                const PopupMenuItem(
                                  value: 'up',
                                  child: Text('上移'),
                                ),
                              if (index < controller.queue.length - 1)
                                const PopupMenuItem(
                                  value: 'down',
                                  child: Text('下移'),
                                ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('移出队列'),
                              ),
                            ],
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Tooltip(
                              message: '拖动调整顺序',
                              child: SizedBox(
                                width: 40,
                                height: 48,
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                          ),
                        ],
                      ),
                      onTap: () => controller.jump(index),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
