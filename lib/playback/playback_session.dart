import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../infrastructure/storage/local_library_store.dart';
import '../library/library_repository.dart';
import 'models/playback_item.dart';
import 'models/playback_state.dart';
import 'playback_controller.dart';

class PlaybackSession {
  PlaybackSession({
    required this.store,
    required this.player,
    required this.scope,
    required this.serverUri,
    this.restoreQueue = true,
  }) {
    _restore();
    player.addListener(_save);
  }
  final LocalLibraryStore store;
  final PlaybackController player;
  final String scope;
  final Uri serverUri;
  final bool restoreQueue;
  String get _key => 'playback_session_${sha256.convert(utf8.encode(scope))}';
  bool get enabled => store.setting('restore_playback_session') != 'false';
  String? _structure;
  int _position = -2000;
  bool? _playing;

  void setEnabled(bool value) {
    store.saveSetting('restore_playback_session', '$value');
    if (!value) store.saveSetting(_key, '');
    _save(force: true);
  }

  void _restore() {
    try {
      final preferences =
          jsonDecode(store.setting('playback_preferences') ?? '{}') as Map;
      final mode = PlaybackMode.values.byName(
        preferences['mode'] as String? ?? 'sequence',
      );
      final volume = (preferences['volume'] as num? ?? 100).toDouble();
      if (!volume.isFinite) return;
      final raw = enabled && restoreQueue ? store.setting(_key) : null;
      final data = jsonDecode(raw == null || raw.isEmpty ? '{}' : raw) as Map;
      if (data.containsKey('schema') && data['schema'] != 1) return;
      final ids = List<String>.from(data['ids'] as List? ?? []);
      final selected = data['index'] as int? ?? 0;
      final library = LibraryRepository(store);
      final tracks = {
        for (final track in library.tracks(serverUri)) track.id: track,
      };
      final items = <PlaybackItem>[];
      var restoredIndex = -1;
      for (var index = 0; index < ids.length; index++) {
        final track = tracks[ids[index]];
        if (track == null || track.missing || track.removed) continue;
        final path = library.offlineSource(serverUri, track.id);
        if (path == null && (track.size == null || track.size! < 0)) continue;
        if (index == selected) restoredIndex = items.length;
        items.add(
          PlaybackItem(serverUri: serverUri, track: track, path: path ?? ''),
        );
      }
      final milliseconds = data['position'] as int? ?? 0;
      final duration = data['duration'] as int? ?? 0;
      if (milliseconds < 0 || duration < 0) return;
      final position = restoredIndex < 0
          ? 0
          : duration > 0
          ? milliseconds.clamp(0, duration)
          : milliseconds;
      player.restoreQueue(
        items,
        index: restoredIndex < 0 ? 0 : restoredIndex,
        position: Duration(milliseconds: position),
        duration: Duration(milliseconds: restoredIndex < 0 ? 0 : duration),
        mode: mode,
        volume: volume,
      );
    } catch (_) {
      /* A malformed snapshot must not prevent library startup. */
    }
  }

  void _save({bool force = false}) {
    try {
      final preferences = jsonEncode({
        'mode': player.mode.name,
        'volume': player.volume,
      });
      final ids = player.queue
          .where((item) => item.serverUri == serverUri)
          .map((item) => item.track.id)
          .toList();
      final structure = jsonEncode({
        'ids': ids,
        'index': player.currentIndex,
        'preferences': preferences,
        'stopped': player.stopped,
      });
      final position = player.state.position.inMilliseconds;
      if (!force &&
          structure == _structure &&
          _playing == player.playRequested &&
          (position - _position).abs() < 2000) {
        return;
      }
      store.saveSetting('playback_preferences', preferences);
      if (enabled && restoreQueue) {
        store.saveSetting(
          _key,
          jsonEncode({
            'schema': 1,
            'ids': ids,
            'index': player.currentIndex,
            'position': position,
            'duration': player.state.duration.inMilliseconds,
          }),
        );
      }
      _structure = structure;
      _position = position;
      _playing = player.playRequested;
    } catch (_) {
      /* Keep playback available if persistence fails. */
    }
  }

  void dispose() {
    player.removeListener(_save);
    _save(force: true);
  }
}
