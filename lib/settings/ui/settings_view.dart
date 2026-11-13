import 'package:flutter/material.dart';

import '../connection_controller.dart';
import '../../updates/ui/update_card.dart';
import '../../updates/update_platform.dart';
import 'connection_card.dart';
import 'download_settings.dart';
import 'playback_settings.dart';

enum _Section { server, downloads, playback, about }

class SettingsView extends StatefulWidget {
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
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  _Section? _section;
  static const _labels = {
    _Section.server: '服务器配置',
    _Section.downloads: '下载行为',
    _Section.playback: '播放行为',
    _Section.about: '关于',
  };
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller,
      widget.controller.playback,
      widget.controller.updates,
    ]),
    builder: (context, _) {
      final controller = widget.controller;
      final storage = controller.mediaStorage;
      final player = controller.playback;
      final updates = controller.updates;
      final content = switch (_section) {
        _Section.server => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ConnectionCard(
              controller: controller,
              serverController: widget.serverController,
              keyController: widget.keyController,
              onConnect: widget.onConnect,
            ),
          ],
        ),
        _Section.downloads => DownloadSettings(
          controller: controller,
          onDownloads: widget.onDownloads,
        ),
        _Section.playback => PlaybackSettings(controller: controller),
        _Section.about => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              title: const Text('Pikmelo Player'),
              subtitle: Text('Windows · Android'),
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('项目仓库'),
              subtitle: const Text('ShenYunyao1 / Pikmelo-Player'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                try {
                  await UpdatePlatform().openRepository();
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('无法打开项目仓库，请检查浏览器配置。')),
                    );
                  }
                }
              },
            ),
            if (updates != null) UpdateCard(controller: updates),
          ],
        ),
        null => ListView(
          children: [
            for (final section in _Section.values)
              ListTile(
                leading: Icon(switch (section) {
                  _Section.server => Icons.cloud_outlined,
                  _Section.downloads => Icons.download_outlined,
                  _Section.playback => Icons.headphones_outlined,
                  _Section.about => Icons.info_outline,
                }),
                title: Text(_labels[section]!),
                subtitle: Text(switch (section) {
                  _Section.server =>
                    '${controller.serverUri.host} · ${controller.connected ? '已连接' : '未连接'}',
                  _Section.downloads =>
                    storage == null
                        ? '媒体目录、移动网络与缓存'
                        : '${mobileDownloadLabel(storage.mobilePolicy)} · ${storage.cacheLimit ~/ (1024 * 1024)} MB',
                  _Section.playback =>
                    player == null
                        ? '队列恢复与默认播放模式'
                        : '${controller.restorePlaybackEnabled ? '恢复队列' : '不恢复队列'} · ${playbackModeLabel(player.defaultMode)}',
                  _Section.about =>
                    updates?.release != null
                        ? '发现新版本 ${updates!.release!.version}'
                        : '当前版本 ${updates?.currentVersion ?? '信息暂不可用'}',
                }),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(() => _section = section),
              ),
          ],
        ),
      };
      return PopScope(
        canPop: _section == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _section != null) setState(() => _section = null);
        },
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              children: [
                if (_section != null)
                  Row(
                    children: [
                      IconButton(
                        tooltip: '返回设置',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => _section = null),
                      ),
                      Expanded(
                        child: Text(
                          _labels[_section]!,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                Expanded(
                  child: KeyedSubtree(key: ValueKey(_section), child: content),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
