import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:pikmelo_player/artwork/artwork_service.dart';
import 'package:pikmelo_player/artwork/embedded_resources.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';
import 'package:pikmelo_player/infrastructure/storage/media_files.dart';
import 'package:pikmelo_player/shared/widgets/music_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  late Uint8List png;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pikmelo-artwork-');
    png = await File('android/app/src/main/res/mipmap-mdpi/ic_launcher.png')
        .readAsBytes();
  });
  tearDown(() => directory.delete(recursive: true));

  testWidgets(
    'artwork shows images and clears the prior image while switching source',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MusicArtwork(title: 'Old', artwork: Future.value(png)),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      final next = Completer<Uint8List?>();
      await tester.pumpWidget(
        MaterialApp(
          home: MusicArtwork(title: 'New', artwork: next.future),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('N'), findsOneWidget);
      next.complete(null);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    },
  );

  test(
    'reads embedded picture and lyrics from audio with a media extension',
    () async {
      final file = File('${directory.path}/track.media');
      await file.writeAsBytes([
        73,
        68,
        51,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        0xff,
        0xfb,
        0x90,
        0x64,
        ...List.filled(830, 0),
      ]);
      replaceMetadata(
        file,
        Mp3Metadata()
          ..lyric = '[00:01.00]测试歌词'
          ..pictures = [Picture(png, 'image/png', PictureType.coverFront)],
      );
      // The dependency's writer omits USLT, so add the standard ID3v2.4 frame.
      final original = await file.readAsBytes();
      final lyrics = [
        3,
        ...ascii.encode('eng'),
        0,
        ...utf8.encode('[00:01.00]测试歌词'),
      ];
      List<int> syncSafe(int size) => [
        (size >> 21) & 127,
        (size >> 14) & 127,
        (size >> 7) & 127,
        size & 127,
      ];
      final frame = [
        ...ascii.encode('USLT'),
        ...syncSafe(lyrics.length),
        0,
        0,
        ...lyrics,
      ];
      final tagSize = original
          .sublist(6, 10)
          .fold(0, (value, byte) => (value << 7) | byte);
      await file.writeAsBytes([
        ...original.sublist(0, 6),
        ...syncSafe(tagSize + frame.length),
        ...frame,
        ...original.sublist(10),
      ]);
      final tags = await readEmbeddedResources(file.path, MediaFiles());
      expect(tags.cover, png);
      expect(tags.lyrics, '[00:01.00]测试歌词');
      const document = 'content://test/tree/music/document/song';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MediaFiles.android, (call) async {
        final values = Map<String, dynamic>.from(call.arguments as Map);
        switch (call.method) {
          case 'stat':
            return {document: await file.length()};
          case 'create':
            final target = File('${values['directory']}/${values['name']}');
            await target.create();
            return target.path;
          case 'copyTo':
            await file.copy(values['target'] as String);
            return null;
        }
        throw StateError('Unexpected call ${call.method}');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(MediaFiles.android, null),
      );
      final documentTags = await readEmbeddedResources(
        document,
        MediaFiles(),
        temporaryDirectory: () async => directory,
      );
      expect(documentTags.cover, png);
      expect(documentTags.lyrics, tags.lyrics);
      expect(
        await directory.list().where((entry) => entry is Directory).isEmpty,
        isTrue,
      );
    },
  );

  test('embedded cover wins and duplicate requests are merged', () async {
    var reads = 0;
    final service = ArtworkService(
      cacheDirectory: () async => directory,
      readEmbedded: (_, _) async {
        reads++;
        return EmbeddedResources(cover: png);
      },
    );
    Future<Uint8List?> load() => service.load(
      scope: 'account',
      revision: 'track',
      path: 'audio',
      coverId: 'cover',
      files: MediaFiles(),
      allowed: () => true,
      fetchCover: (_) async => throw StateError('Server must not be requested'),
    );
    final first = load();
    expect(identical(first, load()), isTrue);
    expect(await first, png);
    expect(reads, 1);
  });

  test('invalid embedded image falls back, server cache works offline and is isolated', () async {
    ArtworkService service() => ArtworkService(
      cacheDirectory: () async => directory,
      readEmbedded: (_, _) async =>
          EmbeddedResources(cover: Uint8List.fromList([1, 2, 3])),
    );
    var requests = 0;
    Future<Uint8List?> load(
      ArtworkService value,
      String scope, {
      bool offline = false,
    }) => value.load(
      scope: scope,
      revision: 'track',
      path: 'audio',
      coverId: 'cover',
      files: MediaFiles(),
      allowed: () => true,
      fetchCover: (_) async {
        requests++;
        return offline ? null : png;
      },
    );
    expect(await load(service(), 'first'), png);
    expect(await load(service(), 'first', offline: true), png);
    expect(requests, 1);
    expect(await load(service(), 'second', offline: true), isNull);
    expect(requests, 2);
  });

  test(
    'newly downloaded embedded cover overrides a cached server cover',
    () async {
      final service = ArtworkService(
        cacheDirectory: () async => directory,
        readEmbedded: (_, _) async => EmbeddedResources(cover: png),
      );
      var requests = 0;
      Future<Uint8List?> load(String? path) => service.load(
        scope: 'account',
        revision: 'track',
        path: path,
        coverId: 'cover',
        files: MediaFiles(),
        allowed: () => true,
        fetchCover: (_) async {
          requests++;
          return png;
        },
      );
      expect(await load(null), png);
      expect(await load('new-audio'), png);
      expect(requests, 1);
    },
  );

  test('authorization change discards an in-flight response', () async {
    var allowed = true;
    final service = ArtworkService(cacheDirectory: () async => directory);
    final result = await service.load(
      scope: 'account',
      revision: 'track',
      path: null,
      coverId: 'cover',
      files: MediaFiles(),
      allowed: () => allowed,
      fetchCover: (_) async {
        allowed = false;
        return png;
      },
    );
    expect(result, isNull);
    expect(await directory.list().isEmpty, isTrue);
  });

  test(
    'cover endpoint uses API key and handles missing and invalid images',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.headers.value('X-API-Key'), 'test-key');
        if (request.uri.path.endsWith('/missing')) {
          request.response.statusCode = 404;
        } else {
          expect(request.uri.path, '/api/v2/covers/image');
          request.response.add(png);
        }
        await request.response.close();
      });
      final client = PikmeloApiClient(
        serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'test-key',
      );
      addTearDown(client.close);
      expect(await client.fetchCover('image'), png);
      expect(await client.fetchCover('missing'), isNull);
      expect(
        await ArtworkService.validImage(Uint8List.fromList([1, 2, 3])),
        isFalse,
      );
    },
  );
}
