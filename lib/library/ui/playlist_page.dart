import 'package:flutter/material.dart';

import '../../downloads/ui/downloads_page.dart';
import '../../playback/ui/player_bar.dart';
import '../../settings/connection_controller.dart';
import '../../settings/models/server_connection.dart';
import '../../shared/widgets/music_artwork.dart';
import '../models/playlist_entry.dart';
import 'track_details.dart';
import '../../playback/ui/playback_controls.dart';

class PlaylistPage extends StatelessWidget {
  const PlaylistPage({
    super.key,
    required this.controller,
    required this.playlistId,
    required this.serverKey,
    this.embedded = false,
  });
  final ConnectionController controller;
  final String playlistId;
  final String serverKey;
  final bool embedded;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final sameServer =
          ServerConnection.serverKey(controller.serverUri) == serverKey;
      final matches = controller.playlists.where(
        (playlist) => playlist.id == playlistId,
      );
      final playlist = sameServer && matches.isNotEmpty ? matches.first : null;
      final entries = playlist == null
          ? const <PlaylistEntry>[]
          : controller.entriesFor(playlistId);
      final firstDownloaded = entries.indexWhere(
        (entry) => entry.downloaded || entry.canDownload,
      );
      final content = playlist == null
          ? const Center(child: Text('歌单已更新或不可用，请返回曲库。'))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              itemCount: entries.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          MusicArtwork(
                            title: playlist.name,
                            artwork: controller.playlistArtwork(playlist.id),
                            size: embedded ? 64 : 88,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  playlist.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${entries.length} 首曲目 · ${entries.where((entry) => entry.downloaded).length} 首已下载',
                                ),
                                if (entries.isNotEmpty)
                                  Text(
                                    playlistDurationLabel(
                                      entries.map((entry) => entry.track),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: controller.busy || firstDownloaded < 0
                                ? null
                                : () => controller.playPlaylist(
                                    playlistId,
                                    firstDownloaded,
                                  ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('播放歌单'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                controller.busy ||
                                    !entries.any(
                                      (entry) =>
                                          entry.canDownload &&
                                          !entry.downloaded,
                                    )
                                ? null
                                : () {
                                    for (final entry in entries.where(
                                      (entry) =>
                                          entry.canDownload &&
                                          !entry.downloaded,
                                    )) {
                                      controller.enqueueDownload(entry.id);
                                    }
                                  },
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('下载歌单'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (!embedded)
                        Text(
                          controller.status,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (controller.error != null)
                        Text(
                          controller.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (entries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('歌单中暂无曲目'),
                        ),
                      const SizedBox(height: 12),
                    ],
                  );
                }
                final entryIndex = index - 1;
                final entry = entries[entryIndex];
                final status = switch (entry) {
                  PlaylistEntry(unavailable: true) => '暂不可用',
                  PlaylistEntry(downloaded: true) => '已下载',
                  PlaylistEntry(canDownload: true) => '可下载',
                  _ => '缺少下载信息',
                };
                final player = controller.playback;
                return ListenableBuilder(
                  listenable: player ?? controller,
                  builder: (context, _) {
                    final active =
                        player?.current?.track.id == entry.id &&
                        player?.current?.serverUri == controller.serverUri;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      selected: active,
                      onLongPress: entry.track == null
                          ? null
                          : () => showTrackDetails(
                              context,
                              entry.track!,
                              load: () => controller.metadataFor(entry.id),
                            ),
                      selectedTileColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.12),
                      onTap:
                          (entry.downloaded || entry.canDownload) &&
                              !controller.busy
                          ? () =>
                                controller.playPlaylist(playlistId, entryIndex)
                          : null,
                      leading: entry.unavailable
                          ? const Icon(Icons.cloud_off_outlined)
                          : MusicArtwork(
                              title: entry.track?.title ?? '',
                              size: 40,
                              artwork: controller.artworkFor(entry.id),
                            ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.track?.title ?? '不可用曲目',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 52,
                            child: Text(
                              entry.track?.duration == null
                                  ? '—'
                                  : playbackTime(entry.track!.duration!),
                              textAlign: TextAlign.end,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        entry.track?.subtitle.isNotEmpty == true
                            ? entry.track!.subtitle
                            : status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 48,
                            height: 48,
                            child:
                                controller.playback != null &&
                                    (entry.downloaded || entry.canDownload)
                                ? IconButton(
                                    tooltip: '加入播放队列',
                                    onPressed: controller.busy
                                        ? null
                                        : () {
                                            controller.appendToQueue(entry.id);
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                                  const SnackBar(
                                                    content: Text('已加入播放队列'),
                                                  ),
                                                );
                                          },
                                    icon: const Icon(Icons.playlist_add),
                                  )
                                : null,
                          ),
                          SizedBox(
                            width: 48,
                            height: 48,
                            child: entry.downloaded
                                ? const Tooltip(
                                    message: '已下载',
                                    child: Icon(Icons.check_circle, size: 20),
                                  )
                                : entry.canDownload
                                ? IconButton(
                                    tooltip: '下载曲目',
                                    onPressed: controller.busy
                                        ? null
                                        : () => controller.enqueueDownload(
                                            entry.id,
                                          ),
                                    icon: const Icon(Icons.download_outlined),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
      if (embedded) return content;
      return Scaffold(
        appBar: AppBar(
          title: const Text('歌单'),
          actions: [
            IconButton(
              tooltip: '下载管理',
              icon: const Icon(Icons.download_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DownloadsPage(controller: controller),
                ),
              ),
            ),
            IconButton(
              tooltip: '同步曲库',
              onPressed: controller.busy ? null : controller.refresh,
              icon: const Icon(Icons.sync),
            ),
          ],
        ),
        body: content,
        bottomNavigationBar: controller.playback == null
            ? null
            : PlayerBar(controller: controller.playback!),
      );
    },
  );
}
