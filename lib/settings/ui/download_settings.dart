import 'package:flutter/material.dart';

import '../../downloads/models/download_task.dart';
import '../connection_controller.dart';
import '../media_storage_controller.dart';
import 'setting_choice.dart';

String mobileDownloadLabel(MobileDownloadPolicy policy) => switch (policy) {
  MobileDownloadPolicy.allow => '允许下载',
  MobileDownloadPolicy.playbackOnly => '仅播放前下载',
  MobileDownloadPolicy.prohibit => '禁止下载',
};

class DownloadSettings extends StatelessWidget {
  const DownloadSettings({
    super.key,
    required this.controller,
    required this.onDownloads,
  });
  final ConnectionController controller;
  final VoidCallback onDownloads;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('下载管理'),
          subtitle: Text(
            '${controller.downloads?.tasks.where((task) => task.status == DownloadStatus.completed).length ?? 0} 首已下载',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onDownloads,
        ),
        if (controller.mediaStorage case final storage?) ...[
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('媒体目录'),
            subtitle: Text(storage.directoryLabel),
            trailing: const Icon(Icons.chevron_right),
            onTap: controller.busy || storage.busy
                ? null
                : () => _chooseDirectory(context, storage),
          ),
          if (storage.busy) ...[
            const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('已处理 ${storage.migrated} 首曲目'),
            ),
          ],
          if (storage.error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                storage.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (storage.migrationPending && !storage.busy)
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => _changeDirectory(context, storage.directory, true),
              child: const Text('继续未完成的迁移'),
            ),
          ListTile(
            title: const Text('曲目移动网络行为'),
            subtitle: Text(
              '${mobileDownloadLabel(storage.mobilePolicy)}\n已下载曲目可离线播放',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final value = await chooseSetting(
                context,
                '曲目移动网络行为',
                storage.mobilePolicy,
                {
                  for (final policy in MobileDownloadPolicy.values)
                    policy: mobileDownloadLabel(policy),
                },
              );
              if (value != null && context.mounted) {
                storage.setMobilePolicy(value);
              }
            },
          ),
          ListTile(
            title: const Text('播放缓存上限'),
            subtitle: Text(
              '${storage.cacheLimit ~/ (1024 * 1024)} MB · 已使用 ${(storage.cacheBytes / (1024 * 1024)).toStringAsFixed(0)} MB\n手动下载长期保留',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final value = await chooseSetting(
                context,
                '播放缓存上限',
                storage.cacheLimit,
                {
                  for (final bytes in {
                    256 * 1024 * 1024,
                    1024 * 1024 * 1024,
                    4096 * 1024 * 1024,
                    storage.cacheLimit,
                  })
                    bytes: bytes < 1024 * 1024 * 1024
                        ? '${bytes ~/ (1024 * 1024)} MB'
                        : '${bytes / (1024 * 1024 * 1024)} GB',
                },
              );
              if (value != null && context.mounted) {
                controller.setPlaybackCacheLimit(value);
              }
            },
          ),
        ],
      ],
    ),
  );

  Future<void> _chooseDirectory(
    BuildContext context,
    MediaStorageController storage,
  ) async {
    try {
      final selected = await storage.store.files.chooseDirectory();
      if (selected == null || !context.mounted) return;
      final migrate = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('变更媒体目录'),
          content: const Text('迁移会逐首复制并校验音频，完成后清理原文件。也可以保留现有文件，仅将新下载保存到所选目录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('仅新下载'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('迁移已有音乐'),
            ),
          ],
        ),
      );
      if (migrate != null && context.mounted) {
        await _changeDirectory(context, selected, migrate);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开媒体目录，请检查目录权限。')));
      }
    }
  }

  Future<void> _changeDirectory(
    BuildContext context,
    String? directory,
    bool migrate,
  ) async {
    try {
      await controller.changeMediaDirectory(directory, migrate: migrate);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('目录变更未完成，请检查权限和空间后重试。')));
      }
    }
  }
}
