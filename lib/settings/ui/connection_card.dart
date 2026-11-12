import 'package:flutter/material.dart';

import '../connection_controller.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.controller,
    required this.serverController,
    required this.keyController,
    required this.onConnect,
  });

  final ConnectionController controller;
  final TextEditingController serverController;
  final TextEditingController keyController;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_sync_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '服务器连接',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Icon(
                  controller.connected
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  color: controller.connected ? const Color(0xFF55D6BE) : null,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: serverController,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                prefixIcon: Icon(Icons.dns_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              decoration: const InputDecoration(
                labelText: '播放器 API Key',
                prefixIcon: Icon(Icons.key_outlined),
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onConnect,
              icon: controller.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(controller.busy ? '更新连接' : '连接并同步'),
            ),
            const SizedBox(height: 12),
            Text(
              controller.status,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (controller.error != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
