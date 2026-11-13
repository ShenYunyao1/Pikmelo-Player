import 'dart:convert';

import '../infrastructure/storage/local_library_store.dart';
import 'models/playlist.dart';
import 'models/playlist_entry.dart';
import 'models/track.dart';

class LibraryRepository {
  const LibraryRepository(this._store);

  final LocalLibraryStore _store;

  List<Playlist> playlists(Uri serverUri) =>
      List.unmodifiable(_store.playlists(serverUri).map(Playlist.fromJson));

  List<Track> tracks(Uri serverUri) {
    final offline = {
      for (final row in _store.offlineTracks(serverUri: serverUri))
        row['track_id'] as String: row['file_path'] as String,
    };
    return List.unmodifiable(
      _store.tracks(serverUri).map((json) {
        final track = Track.fromJson(json);
        final path = offline[track.id];
        final local =
            path != null &&
                !track.missing &&
                !track.removed &&
                _store.files.exists(path, track.size)
            ? _store.localMetadata(path)
            : null;
        return local == null
            ? track
            : Track.fromJson({...json, ...local, '_local_metadata': true});
      }),
    );
  }

  String? offlineSource(Uri uri, String id) {
    final row = _store.offlineMedia(uri, id);
    if (row == null) return null;
    final track = Track.fromJson(
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
    );
    if (track.missing || track.removed) return null;
    final path = row['file_path'] as String;
    return _store.files.exists(path, track.size) ? path : null;
  }

  List<PlaylistEntry> playlistEntries(Uri serverUri, Playlist playlist) {
    final metadata = {for (final track in tracks(serverUri)) track.id: track};
    final cached = {
      for (final row in _store.offlineTracks(serverUri: serverUri))
        row['track_id'] as String: row['file_path'] as String,
    };
    final unavailable = playlist.unavailableTrackIds.toSet();
    return List.unmodifiable(
      playlist.trackIds.map((id) {
        final track = metadata[id];
        final blocked =
            playlist.subscriptionInvalid ||
            unavailable.contains(id) ||
            track == null ||
            track.missing ||
            track.removed;
        final path = cached[id];
        return PlaylistEntry(
          id: id,
          track: track,
          unavailable: blocked,
          downloaded:
              !blocked && path != null && offlineSource(serverUri, id) != null,
        );
      }),
    );
  }
}
