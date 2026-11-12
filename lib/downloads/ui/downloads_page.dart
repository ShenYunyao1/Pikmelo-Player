import 'package:flutter/material.dart';

import '../../settings/connection_controller.dart';
import '../../playback/ui/player_bar.dart';
import '../models/download_task.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  final ConnectionController controller;
  final bool embedded;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final manager = controller.downloads;
      final tasks = manager?.tasks ?? const <DownloadTask>[];
      final content = DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: '任务'),
                Tab(text: '已下载'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _taskList(
                    context,
                    tasks
                        .where(
                          (task) => task.status != DownloadStatus.completed,
                        )
                        .toList(),
                  ),
                  _taskList(
                    context,
                    tasks
                        .where(
                          (task) => task.status == DownloadStatus.completed,
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      if (embedded) return content;
      return Scaffold(
        bottomNavigationBar: controller.playback == null
            ? null
            : PlayerBar(controller: controller.playback!),
        appBar: AppBar(title: const Text('下载管理')),
        body: content,
      );
    },
  );

  Widget _taskList(BuildContext context, List<DownloadTask> tasks) {
    final manager = controller.downloads;
    return tasks.isEmpty
        ? const Center(child: Text('暂无下载任务，可在歌单中选择曲目下载。'))
        : ListView.separated(
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final task = tasks[index];
              final permanent =
                  controller.mediaStorage?.store.mediaPinned(
                    controller.serverUri,
                    task.track.id,
                  ) ??
                  true;
              final status = switch (task.status) {
                DownloadStatus.queued => '等待下载',
                DownloadStatus.downloading => '下载中',
                DownloadStatus.paused => '已暂停',
                DownloadStatus.completed =>
                  permanent ? '已完成 · 永久保留' : '已完成 · 播放缓存',
                DownloadStatus.failed => '失败',
              };
              final total = task.track.size ?? 0;
              final progress = task.status == DownloadStatus.completed
                  ? 1.0
                  : total > 0
                  ? (task.received / total).clamp(0.0, 1.0)
                  : null;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.track.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '$status · ${_bytes(task.received)} / ${_bytes(total)}',
                    ),
                    if (task.error != null)
                      Text(
                        task.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (task.status == DownloadStatus.completed &&
                            !permanent)
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () =>
                                      controller.enqueueDownload(task.track.id),
                            child: const Text('永久保留'),
                          ),
                        if (task.status == DownloadStatus.completed)
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () =>
                                      controller.playDownloaded(task.track.id),
                            child: const Text('播放'),
                          ),
                        if (task.status == DownloadStatus.downloading ||
                            task.status == DownloadStatus.queued)
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () => manager!.pause(task.track.id),
                            child: const Text('暂停'),
                          ),
                        if (task.status == DownloadStatus.paused ||
                            task.status == DownloadStatus.failed)
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () => manager!.resume(task.track.id),
                            child: Text(
                              task.status == DownloadStatus.failed
                                  ? '重试'
                                  : '继续',
                            ),
                          ),
                        if (task.status != DownloadStatus.completed)
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () => manager!.cancel(task.track.id),
                            child: const Text('取消'),
                          ),
                        TextButton(
                          onPressed: controller.busy
                              ? null
                              : () => manager!.remove(task.track.id),
                          child: const Text('删除本地文件'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
  }

  String _bytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}
