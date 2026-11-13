import 'dart:async';

import 'package:flutter/material.dart';

import '../../downloads/ui/downloads_page.dart';
import '../../playback/ui/player_bar.dart';
import '../../playback/ui/playback_controls.dart';
import '../../playback/ui/queue_page.dart';
import '../../settings/connection_controller.dart';
import '../../settings/models/server_connection.dart';
import '../../settings/ui/settings_view.dart';
import '../../shared/widgets/music_artwork.dart';
import '../models/playlist.dart';
import '../models/playlist_entry.dart';
import 'playlist_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});
  final ConnectionController controller;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _serverController = TextEditingController(
    text: ServerConnection.defaultUri.toString(),
  );
  final _keyController = TextEditingController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  int _destination = 0;
  bool _downloadedOnly = false;
  bool _showQueue = true;
  String _query = '';
  String? _playlistId;
  String? _playlistServer;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreConnection());
  }

  Future<void> _restoreConnection() async {
    final restored = await widget.controller.initialize();
    if (mounted &&
        restored != null &&
        _serverController.text == ServerConnection.defaultUri.toString() &&
        _keyController.text.isEmpty) {
      _serverController.text = restored.serverUri.toString();
      _keyController.text = restored.apiKey ?? '';
      if (restored.apiKey != null) unawaited(widget.controller.refresh());
    }
  }

  Future<void> _connect() async {
    final server = _serverController.text;
    final key = _keyController.text;
    await widget.controller.connectAndSync(server, key);
    if (mounted &&
        widget.controller.connected &&
        _destination == 2 &&
        _serverController.text == server &&
        _keyController.text == key) {
      setState(() {
        _destination = 0;
        _playlistId = null;
      });
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _keyController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(Playlist playlist, bool desktop) {
    final server = ServerConnection.serverKey(widget.controller.serverUri);
    if (desktop) {
      setState(() {
        _query = '';
        _searchController.clear();
        _playlistId = playlist.id;
        _playlistServer = server;
      });
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistPage(
            controller: widget.controller,
            playlistId: playlist.id,
            serverKey: server,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 840;
        final player = widget.controller.playback;
        final title = ['曲库', '下载', '设置'][_destination];
        final content = switch (_destination) {
          1 => DownloadsPage(controller: widget.controller, embedded: true),
          2 => SettingsView(
            controller: widget.controller,
            serverController: _serverController,
            keyController: _keyController,
            onConnect: _connect,
            onDownloads: () => setState(() => _destination = 1),
          ),
          _ => _library(desktop),
        };
        return Scaffold(
          appBar: AppBar(
            title: Text(desktop ? 'Pikmelo Player' : title),
            actions: [
              if (_destination == 0)
                IconButton(
                  tooltip: '同步曲库',
                  onPressed: widget.controller.busy
                      ? null
                      : widget.controller.refresh,
                  icon: const Icon(Icons.sync_rounded),
                ),
              if (desktop && constraints.maxWidth >= 1200 && player != null)
                IconButton(
                  tooltip: '显示播放队列',
                  onPressed: () => setState(() => _showQueue = !_showQueue),
                  icon: const Icon(Icons.queue_music),
                ),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: Row(
              children: [
                if (desktop)
                  NavigationRail(
                    minExtendedWidth: 208,
                    extended: constraints.maxWidth >= 1200,
                    selectedIndex: _destination,
                    onDestinationSelected: (index) =>
                        setState(() => _destination = index),
                    leading: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Icon(Icons.graphic_eq_rounded, size: 32),
                    ),
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.library_music_outlined),
                        selectedIcon: Icon(Icons.library_music),
                        label: Text('曲库'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.download_outlined),
                        selectedIcon: Icon(Icons.download),
                        label: Text('下载'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                Expanded(child: content),
                if (desktop &&
                    constraints.maxWidth >= 1200 &&
                    _showQueue &&
                    player != null)
                  SizedBox(
                    width: 264,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: QueueContents(
                        controller: player,
                        onClose: () => setState(() => _showQueue = false),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (player != null) PlayerBar(controller: player),
              if (!desktop)
                NavigationBar(
                  selectedIndex: _destination,
                  onDestinationSelected: (index) =>
                      setState(() => _destination = index),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.library_music_outlined),
                      selectedIcon: Icon(Icons.library_music),
                      label: '曲库',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.download_outlined),
                      selectedIcon: Icon(Icons.download),
                      label: '下载',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: '设置',
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _library(bool desktop) {
    final controller = widget.controller;
    final query = _query.trim().toLowerCase();
    final playlists = controller.playlists.where((playlist) {
      final entries = controller.entriesFor(playlist.id);
      final visible = _downloadedOnly
          ? entries.where((entry) => entry.downloaded)
          : entries;
      if (_downloadedOnly && visible.isEmpty) return false;
      return query.isEmpty ||
          playlist.name.toLowerCase().contains(query) ||
          visible.any(
            (entry) =>
                (entry.track?.title.toLowerCase().contains(query) ?? false) ||
                ((entry.track?.artist?.toLowerCase().contains(query) ??
                        false) ||
                    (entry.track?.album?.toLowerCase().contains(query) ??
                        false)),
          );
    }).toList();
    final hasSelection =
        desktop &&
        query.isEmpty &&
        _playlistId != null &&
        _playlistServer == ServerConnection.serverKey(controller.serverUri) &&
        playlists.any((playlist) => playlist.id == _playlistId);
    final grid = playlists.isEmpty
        ? Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.library_music_outlined, size: 56),
                    const SizedBox(height: 16),
                    Text(
                      controller.playlists.isEmpty ? '连接音乐库，开始收听' : '没有匹配的歌单',
                    ),
                    if (controller.playlists.isEmpty) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => setState(() => _destination = 2),
                        icon: const Icon(Icons.add_link),
                        label: const Text('连接音乐库'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 180).floor().clamp(2, 5);
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: hasSelection ? 0.95 : 0.78,
                ),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  final count = controller
                      .entriesFor(playlist.id)
                      .where((entry) => entry.downloaded)
                      .length;
                  return Semantics(
                    button: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _open(playlist, desktop),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: LayoutBuilder(
                                builder: (context, box) => MusicArtwork(
                                  title: playlist.name,
                                  artwork: controller.playlistArtwork(
                                    playlist.id,
                                  ),
                                  size: box.maxWidth,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            '${playlist.trackIds.length} 首曲目 · $count 首已下载',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (desktop)
                Text('曲库', style: Theme.of(context).textTheme.headlineMedium),
              Text(
                controller.status,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (controller.error != null)
                Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (controller.busy) const LinearProgressIndicator(),
              const SizedBox(height: 16),
              TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                decoration: InputDecoration(
                  hintText: '搜索歌单、曲目、歌手或专辑',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() {
                            _searchController.clear();
                            _query = '';
                            _searchFocus.requestFocus();
                          }),
                        ),
                  isDense: true,
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: !_downloadedOnly,
                    onSelected: (_) => setState(() => _downloadedOnly = false),
                  ),
                  ChoiceChip(
                    label: const Text('已下载'),
                    selected: _downloadedOnly,
                    onSelected: (_) => setState(() => _downloadedOnly = true),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        if (hasSelection) ...[
          SizedBox(
            height: MediaQuery.sizeOf(context).height < 800 ? 150 : 210,
            child: grid,
          ),
          Expanded(
            child: PlaylistPage(
              controller: controller,
              playlistId: _playlistId!,
              serverKey: _playlistServer!,
              embedded: true,
            ),
          ),
        ] else
          Expanded(
            child: query.isEmpty || playlists.isEmpty
                ? grid
                : _searchResults(playlists, desktop, query),
          ),
      ],
    );
  }

  Widget _searchResults(List<Playlist> playlists, bool desktop, String query) {
    final tracks = <String, ({Playlist playlist, PlaylistEntry entry})>{};
    for (final playlist in playlists) {
      for (final entry in widget.controller.entriesFor(playlist.id)) {
        if (_downloadedOnly && !entry.downloaded) continue;
        if ((entry.track?.title.toLowerCase().contains(query) ?? false) ||
            ((entry.track?.artist?.toLowerCase().contains(query) ?? false) ||
                (entry.track?.album?.toLowerCase().contains(query) ?? false))) {
          tracks.putIfAbsent(
            entry.id,
            () => (playlist: playlist, entry: entry),
          );
        }
      }
    }
    final matchedPlaylists = playlists
        .where((playlist) => playlist.name.toLowerCase().contains(query))
        .toList();
    final matches = tracks.values.toList();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: matchedPlaylists.length + matches.length,
      itemBuilder: (context, index) {
        if (index < matchedPlaylists.length) {
          final playlist = matchedPlaylists[index];
          return ListTile(
            leading: MusicArtwork(
              title: playlist.name,
              size: 44,
              artwork: widget.controller.playlistArtwork(playlist.id),
            ),
            title: Text(playlist.name),
            subtitle: const Text('歌单'),
            onTap: () => _open(playlist, desktop),
          );
        }
        final match = matches[index - matchedPlaylists.length];
        final entry = match.entry;
        return ListTile(
          leading: MusicArtwork(
            title: entry.track!.title,
            size: 44,
            artwork: widget.controller.artworkFor(entry.id),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  entry.track!.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (entry.track!.duration != null)
                Text(
                  playbackTime(entry.track!.duration!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          subtitle: Text(
            '${entry.track!.subtitle.isEmpty ? match.playlist.name : entry.track!.subtitle} · ${entry.downloaded ? '已下载' : '未下载'}',
          ),
          onTap:
              (entry.downloaded || entry.canDownload) && !widget.controller.busy
              ? () => widget.controller.playDownloaded(entry.id)
              : () => _open(match.playlist, desktop),
          trailing: entry.canDownload && !entry.downloaded
              ? IconButton(
                  tooltip: '下载曲目',
                  onPressed: widget.controller.busy
                      ? null
                      : () => widget.controller.enqueueDownload(entry.id),
                  icon: const Icon(Icons.download_outlined),
                )
              : null,
        );
      },
    );
  }
}
