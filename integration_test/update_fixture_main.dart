// Release-signed fixture for validating upgrades with durable client data.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/infrastructure/storage/api_key_store.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/settings/models/server_connection.dart';
import 'package:pikmelo_player/main.dart' as application;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalLibraryStore.open();
  final uri = Uri.parse('https://upgrade-fixture.invalid');
  if (store.cursorFor(uri) == null) {
    const key = 'upgrade-fixture-key';
    await ApiKeyStore().saveConnection(ServerConnection(uri), key);
    store.bindCredentials(
      uri,
      ServerConnection.credentialFingerprint(key),
      adoptLegacy: true,
    );
    store.saveSelectedServer(uri);
    store.saveSetting('automatic_updates', 'false');
    store.saveSetting('mobile_download_policy', 'prohibit');
    store.saveSetting('playback_cache_limit', '${256 * 1024 * 1024}');
    final root = await getApplicationSupportDirectory();
    final media = File('${root.path}/upgrade-retention.media');
    await media.writeAsBytes(_wave());
    final track = {
      'id': 'upgrade-track',
      'title': '升级保留测试音频',
      'artist': '升级验收',
      'size': await media.length(),
    };
    store.applySyncPages(uri, [
      PikmeloSyncPage(
        changedTracks: [track],
        playlists: [
          {
            'id': 'upgrade-list',
            'name': '升级保留测试歌单',
            'track_ids': ['upgrade-track'],
          },
        ],
        deletedTracks: [],
        deletedPlaylists: [],
        cursor: 'upgrade-fixture',
        hasMore: false,
        fullSnapshot: true,
        reset: false,
        revision: 1,
      ),
    ]);
    store.saveOfflineMedia(
      serverUri: uri,
      expectedGeneration: store.generationFor(uri),
      trackId: 'upgrade-track',
      track: track,
      file: media,
    );
  }
  // Reinstalling this QA entry point prepares an existing formal baseline for
  // another upgrade run, using only its explicitly seeded test authorization.
  store.authorizeOfflineMedia(uri, 'upgrade-track', store.generationFor(uri));
  store.saveSetting('automatic_updates', 'false');
  store.close();
  await application.main();
}

Uint8List _wave() {
  const size = 44100 * 2 * 60;
  final data = ByteData(44 + size);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, size + 36, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 88200, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, size, Endian.little);
  return data.buffer.asUint8List();
}
