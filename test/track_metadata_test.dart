import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/library/models/track.dart';
import 'package:pikmelo_player/library/ui/track_details.dart';
import 'package:pikmelo_player/artwork/embedded_resources.dart';
import 'package:pikmelo_player/infrastructure/storage/media_files.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/infrastructure/server/sync_page.dart';
import 'package:pikmelo_player/library/library_repository.dart';

void main() {
  test('file deletion waits for metadata readers and rejects new reads during deletion', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pikmelo-read-lock-',
    );
    final file = await File('${directory.path}/audio.media')
        .writeAsBytes([1, 2, 3]);
    final descriptor = file.openSync();
    final release = Completer<void>();
    var closed = false;
    try {
      final files = MediaFiles();
      final reading = files.readSafely(file.path, () async {
        await release.future;
        descriptor.closeSync();
        closed = true;
      });
      final deleting = files.delete(file.path);
      await Future<void>.delayed(Duration.zero);
      expect(await file.exists(), isTrue);
      expect(
        () => files.readSafely(file.path, () async {}),
        throwsA(isA<FileSystemException>()),
      );
      release.complete();
      await Future.wait([reading, deleting]);
      expect(await file.exists(), isFalse);
    } finally {
      if (!closed) descriptor.closeSync();
      if (!release.isCompleted) release.complete();
      await directory.delete(recursive: true);
    }
  });

  test(
    'local WAV properties come from the audio contents with a media extension',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pikmelo-metadata-',
      );
      try {
        final file = File('${directory.path}/audio.media');
        await file.writeAsBytes(waveFixture());
        final resource = await readEmbeddedResources(file.path, MediaFiles());
        expect(resource.metadata['format'], 'wav');
        expect(resource.metadata['sample_rate'], 44100);
        expect(resource.metadata['channels'], 1);
        expect(resource.metadata['bits_per_sample'], 16);
        expect(resource.metadata['duration_ms'], 100);
        expect(resource.metadata['album'], isNull);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('local projection overrides stale synced metadata and invalidates on file change', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pikmelo-metadata-cache-',
    );
    final store = await LocalLibraryStore.open(
      databasePath: '${directory.path}/library.sqlite',
    );
    try {
      final uri = Uri.parse('https://example.com');
      final file = File('${directory.path}/audio.media');
      await file.writeAsBytes(waveFixture());
      final data = {
        'id': 'one',
        'title': 'Song',
        'album': 'stale album',
        'size': await file.length(),
        'duration_ms': 90000,
      };
      store.applySyncPages(uri, [
        PikmeloSyncPage(
          changedTracks: [data],
          playlists: [],
          deletedTracks: [],
          deletedPlaylists: [],
          cursor: 'base',
          hasMore: false,
          fullSnapshot: true,
          reset: false,
          revision: 1,
        ),
      ]);
      store.saveOfflineMedia(
        serverUri: uri,
        expectedGeneration: store.generationFor(uri),
        trackId: 'one',
        track: data,
        file: file,
      );
      final resource = await readEmbeddedResources(file.path, store.files);
      store.saveLocalMetadata(file.path, resource.metadata);
      final track = LibraryRepository(store).tracks(uri).single;
      expect(track.parsedLocally, isTrue);
      expect(track.album, isNull);
      expect(track.duration, const Duration(milliseconds: 100));
      expect(store.tracks(uri).single['album'], 'stale album');
      await file.setLastModified(DateTime.utc(2000));
      expect(store.localMetadata(file.path), isNull);
      store.completeFileDeletion(file.path);
      expect(store.localMetadata(file.path), isNull);
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });

  test('track reads typed server metadata and retains its original JSON', () {
    final data = <String, dynamic>{
      'id': 'one',
      'title': ' Song ',
      'album': ' Album ',
      'artist': ' Singer ',
      'duration_ms': 185500,
      'format': 'flac',
      'bitrate_kbps': 900,
      'sample_rate': 48000,
      'channels': 2,
      'bits_per_sample': 24,
    };
    final track = Track.fromJson(data);
    expect(track.title, 'Song');
    expect(track.album, 'Album');
    expect(track.subtitle, 'Singer · Album');
    expect(track.duration, const Duration(milliseconds: 185500));
    expect(track.sampleRate, 48000);
    expect(track.bitsPerSample, 24);
    expect(track.toJson(), data);
  });
  test('legacy and malformed fields remain unavailable without fabricated durations', () {
    for (final value in [
      null,
      '',
      '123',
      -1,
      0,
      double.nan,
      double.infinity,
      1e30,
    ]) {
      final track = Track.fromJson({
        'id': 'one',
        'album': 12,
        'artist': [],
        'duration_ms': value,
        'bitrate_kbps': value,
      });
      expect(track.duration, isNull);
      expect(track.bitrateKbps, isNull);
      expect(track.album, isNull);
      expect(track.artist, isNull);
      expect(track.title, '未命名曲目');
    }
  });
  test(
    'playlist totals identify missing values and count repeated entries',
    () {
      final track = Track.fromJson({'id': 'one', 'duration_ms': 61000});
      expect(playlistDurationLabel([track, track]), '总时长 2:02');
      expect(playlistDurationLabel([track, null]), '已知时长 1:01 · 1 首时长未知');
      expect(playlistDurationLabel([null]), '时长未知');
      expect(playlistDurationLabel([]), '');
    },
  );
  testWidgets(
    'track details displays album and technical fields at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final track = Track.fromJson({
        'id': 'one',
        'title': 'Song',
        'album': 'Album',
        'duration_ms': 185000,
        'format': 'flac',
        'bitrate_kbps': 900,
        'sample_rate': 48000,
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTrackDetails(context, track),
                child: const Text('详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Album'), findsOneWidget);
      expect(find.textContaining('3:05'), findsOneWidget);
      expect(find.textContaining('FLAC'), findsOneWidget);
      expect(find.textContaining('48000 Hz'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Uint8List waveFixture() {
  const size = 8820;
  final data = ByteData(44 + size);
  void text(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      data.setUint8(offset + index, value.codeUnitAt(index));
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
