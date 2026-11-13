import 'package:flutter/material.dart';

import '../../downloads/models/download_task.dart';
import '../connection_controller.dart';
import '../media_storage_controller.dart';
import 'connection_card.dart';
import '../../updates/ui/update_card.dart';
import '../../playback/models/playback_state.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.controller,
    required this.serverController,
    required this.keyController,
    required this.onConnect,
    required this.onDownloads,
  });
  final ConnectionController controller;
  final TextEditingController serverController;
  final TextEditingController keyController;
  final VoidCallback onConnect;
  final VoidCallback onDownloads;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ConnectionCard(
            controller: controller,
            serverController: serverController,
            keyController: keyController,
            onConnect: onConnect,
          ),
        ),
      ),
      const SizedBox(height: 24),
      ListTile(
        leading: const Icon(Icons.storage_outlined),
        title: const Text('下载与存储'),
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
          trailing: const Icon(Icons.folder_open),
          onTap: controller.busy || storage.busy
              ? null
              : () => _chooseDirectory(context, storage),
        ),
        if (storage.busy) ...[
          const LinearProgressIndicator(),
          Text('已处理 ${storage.migrated} 首曲目'),
        ],
        if (storage.error != null)
          Text(
            storage.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (storage.migrationPending && !storage.busy)
          TextButton(
            onPressed: controller.busy
                ? null
                : () => _changeDirectory(context, storage.directory, true),
            child: const Text('继续未完成的迁移'),
          ),
        ListTile(
          title: const Text('移动网络下载'),
          subtitle: const Text('已下载曲目可离线播放'),
          trailing: DropdownButton<MobileDownloadPolicy>(
            value: storage.mobilePolicy,
            items: const [
              DropdownMenuItem(
                value: MobileDownloadPolicy.allow,
                child: Text('允许下载'),
              ),
              DropdownMenuItem(
                value: MobileDownloadPolicy.playbackOnly,
                child: Text('仅播放前下载'),
              ),
              DropdownMenuItem(
                value: MobileDownloadPolicy.prohibit,
                child: Text('禁止下载'),
              ),
            ],
            onChanged: (value) {
              if (value != null) storage.setMobilePolicy(value);
            },
          ),
        ),
        ListTile(
          title: const Text('播放缓存上限'),
          subtitle: Text(
            '已使用 ${(storage.cacheBytes / (1024 * 1024)).toStringAsFixed(0)} MB，手动下载会永久保留',
          ),
          trailing: DropdownButton<int>(
            value: storage.cacheLimit,
            items: [
              for (final mb in {
                256,
                1024,
                4096,
                storage.cacheLimit ~/ (1024 * 1024),
              })
                DropdownMenuItem(
                  value: mb * 1024 * 1024,
                  child: Text(mb < 1024 ? '$mb MB' : '${mb ~/ 1024} GB'),
                ),
            ],
            onChanged: (value) {
              if (value != null) controller.setPlaybackCacheLimit(value);
            },
          ),
        ),
      ],
      ListTile(
        leading: const Icon(Icons.headphones_outlined),
        title: const Text('播放行为'),
        subtitle: Text(
          Theme.of(context).platform == TargetPlatform.windows
              ? '最小化继续播放，关闭窗口退出'
              : '支持后台与锁屏播放，断开耳机时暂停',
        ),
      ),
      if (controller.playback case final player?)
        ListenableBuilder(
          listenable: player,
          builder: (context, _) => Column(
            children: [
              SwitchListTile(
                title: const Text('启动时恢复播放队列'),
                subtitle: const Text('恢复当前曲目和进度，保持暂停'),
                value: controller.restorePlaybackEnabled,
                onChanged: controller.mediaStorage == null
                    ? null
                    : controller.setRestorePlayback,
              ),
              ListTile(
                title: const Text('播放模式'),
                trailing: DropdownButton<PlaybackMode>(
                  value: player.mode,
                  items: [
                    for (final mode in PlaybackMode.values)
                      DropdownMenuItem(
                        value: mode,
                        child: Text(switch (mode) {
                          PlaybackMode.sequence => '顺序播放',
                          PlaybackMode.repeatAll => '列表循环',
                          PlaybackMode.repeatOne => '单曲循环',
                          PlaybackMode.shuffle => '随机播放',
                        }),
                      ),
                  ],
                  onChanged: (mode) {
                    if (mode != null) player.setMode(mode);
                  },
                ),
              ),
              ListTile(
                title: Text('应用音量 ${player.volume.round()}%'),
                subtitle: Slider(
                  value: player.volume,
                  max: 100,
                  label: '${player.volume.round()}%',
                  onChanged: player.setVolume,
                ),
              ),
            ],
          ),
        ),
      if (controller.updates case final updates?)
        UpdateCard(controller: updates),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('Pikmelo Player'),
        subtitle: Text('Windows · Android\n本地音频与授权曲库同步'),
      ),
    ],
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
