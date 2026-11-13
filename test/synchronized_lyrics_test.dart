import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/artwork/synchronized_lyrics.dart';

List<int> _integer(int n) => [
  (n >> 24) & 255,
  (n >> 16) & 255,
  (n >> 8) & 255,
  n & 255,
];
List<int> _safe(int n) => [
  (n >> 21) & 127,
  (n >> 14) & 127,
  (n >> 7) & 127,
  n & 127,
];
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pikmelo-sylt-');
  });
  tearDown(() => directory.delete(recursive: true));
  Future<String?> read(
    List<int> payload, {
    int version = 3,
    bool audio = true,
  }) async {
    final frame = [
      ...ascii.encode(version == 2 ? 'SLT' : 'SYLT'),
      if (version == 2)
        ..._integer(payload.length).skip(1)
      else
        ...version == 4 ? _safe(payload.length) : _integer(payload.length),
      if (version != 2) ...[0, 0],
      ...payload,
    ];
    final file = await File('${directory.path}/sample.media').writeAsBytes([
      73,
      68,
      51,
      version,
      0,
      0,
      ..._safe(frame.length),
      ...frame,
      if (audio) ...[255, 251, 144, 100, ...List.filled(830, 0)],
    ]);
    return readSynchronizedLyrics(file);
  }

  for (final version in [2, 3, 4]) {
    test('ID3v2.$version synchronized timestamps use milliseconds', () async {
      expect(
        await read([
          3,
          ...ascii.encode('eng'),
          2,
          1,
          0,
          ...utf8.encode('line'),
          0,
          ..._integer(1234),
        ], version: version),
        '[00:01.234]line',
      );
    });
  }
  test('UTF16 little endian with descriptors decodes Chinese', () async {
    List<int> wide(String value) => [
      255,
      254,
      ...value.codeUnits.expand((unit) => [unit & 255, unit >> 8]),
      0,
      0,
    ];
    expect(
      await read([
        1,
        ...ascii.encode('zho'),
        2,
        1,
        ...wide('描述'),
        ...wide('第一句'),
        ..._integer(1000),
      ]),
      '[00:01.000]第一句',
    );
  });
  test('MPEG frame timestamps convert using audio header', () async {
    expect(
      await read([
        3,
        ...ascii.encode('eng'),
        1,
        1,
        0,
        ...utf8.encode('line'),
        0,
        ..._integer(100),
      ]),
      '[00:02.612]line',
    );
  });
  test(
    'frame timestamps without audio information preserve plain text',
    () async {
      expect(
        await read([
          3,
          ...ascii.encode('eng'),
          1,
          1,
          0,
          ...utf8.encode('plain'),
          0,
          ..._integer(100),
        ], audio: false),
        'plain',
      );
    },
  );
  test(
    'syllable fragments with newline markers are grouped as lines',
    () async {
      expect(
        await read([
          3,
          ...ascii.encode('eng'),
          2,
          1,
          0,
          ...utf8.encode('\nHello '),
          0,
          ..._integer(1000),
          ...utf8.encode('world'),
          0,
          ..._integer(1200),
          ...utf8.encode('\nNext'),
          0,
          ..._integer(2000),
        ]),
        '[00:01.000]Hello world\n[00:02.000]Next',
      );
    },
  );
  test(
    'truncated frames and unsupported units safely yield no lyrics',
    () async {
      expect(
        await read([
          3,
          ...ascii.encode('eng'),
          2,
          1,
          0,
          ...utf8.encode('line'),
          0,
          0,
        ]),
        isNull,
      );
      expect(
        await read([
          3,
          ...ascii.encode('eng'),
          0,
          1,
          0,
          ...utf8.encode('line'),
          0,
          ..._integer(1000),
        ]),
        isNull,
      );
    },
  );
}
