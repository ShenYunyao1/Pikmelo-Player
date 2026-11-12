import 'package:flutter/material.dart';

import '../update_controller.dart';

class UpdateCard extends StatelessWidget {
  const UpdateCard({super.key, required this.controller});
  final UpdateController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final update = controller.release;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('应用更新', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text('当前版本 ${controller.currentVersion}'),
              if (update != null) Text('可用版本 ${update.version}'),
              if (controller.android)
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动更新'),
                  subtitle: const Text('启动时检查，遵循移动网络下载策略'),
                  value: controller.automatic,
                  onChanged: controller.setAutomatic,
                ),
              if (controller.message != null) Text(controller.message!),
              if (controller.phase == UpdatePhase.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: controller.total > 0
                      ? controller.received / controller.total
                      : null,
                ),
                Text(
                  '${(controller.received / 1048576).toStringAsFixed(1)} / ${(controller.total / 1048576).toStringAsFixed(1)} MB',
                ),
              ] else if (controller.busy)
                const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: controller.initialized && !controller.busy
                        ? controller.check
                        : null,
                    child: const Text('检查更新'),
                  ),
                  if (update != null)
                    FilledButton.tonal(
                      onPressed: controller.busy
                          ? null
                          : controller.downloadAndInstall,
                      child: Text(
                        controller.android
                            ? controller.phase == UpdatePhase.permission
                                  ? '授权并安装'
                                  : '下载并安装'
                            : '查看发布页',
                      ),
                    ),
                  if (controller.phase == UpdatePhase.downloading)
                    TextButton(
                      onPressed: controller.cancel,
                      child: const Text('取消下载'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
