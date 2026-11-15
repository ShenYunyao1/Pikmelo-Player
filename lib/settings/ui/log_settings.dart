import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/app_log.dart';
import '../connection_controller.dart';
import 'setting_choice.dart';

class LogSettings extends StatefulWidget {
  const LogSettings({super.key, required this.controller});
  final ConnectionController controller;

  @override
  State<LogSettings> createState() => _LogSettingsState();
}

class _LogSettingsState extends State<LogSettings> {
  late Future<({int bytes, List<String> lines})> _snapshot;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _snapshot = AppLog.instance.snapshot();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _snapshot,
    builder: (context, snapshot) {
      final log = AppLog.instance;
      final data = snapshot.data;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('记录级别'),
            subtitle: Text('${log.level.name} 及以上严重级别'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final selected = await chooseSetting(context, '记录级别', log.level, {
                for (final level in LogLevel.values) level: level.name,
              });
              if (selected == null || !mounted) return;
              widget.controller.setLogLevel(selected);
              setState(_reload);
            },
          ),
          ListTile(
            title: const Text('循环日志'),
            subtitle: Text(
              '${((data?.bytes ?? 0) / (1024 * 1024)).toStringAsFixed(2)} / 20 MB · 最近 200 条',
            ),
          ),
          if (log.directory != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(log.directory!.path),
            ),
          if (log.lastError != null || snapshot.hasError)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(log.lastError ?? '读取日志失败，请刷新重试。'),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  AppLog.instance.debug('logs.refresh');
                  setState(_reload);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('刷新日志'),
              ),
              OutlinedButton.icon(
                onPressed: data == null || data.lines.isEmpty
                    ? null
                    : () async {
                        AppLog.instance.debug('logs.copy', {
                          'lines': data.lines.length,
                        });
                        await Clipboard.setData(
                          ClipboardData(text: data.lines.reversed.join('\n')),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制最近日志')),
                        );
                      },
                icon: const Icon(Icons.copy),
                label: const Text('复制最近日志'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await log.clear();
                  if (mounted) setState(_reload);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空日志'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (snapshot.connectionState == ConnectionState.waiting)
            const LinearProgressIndicator()
          else if (data == null || data.lines.isEmpty)
            const Text('暂无日志')
          else
            for (final line in data.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(
                  line,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
        ],
      );
    },
  );
}
