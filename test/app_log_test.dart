import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/shared/app_log.dart';
import 'package:pikmelo_player/infrastructure/server/pikmelo_api_client.dart';

void main() {
  late Directory root;
  late AppLog log;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pikmelo-log-');
    log = AppLog(fileBytes: 1024);
    await log.initialize(root);
    await log.clear();
  });

  tearDown(() async {
    await log.flush();
    await root.delete(recursive: true);
  });

  test('selected severity includes more severe records', () async {
    log.level = LogLevel.warn;
    log.debug('excluded.debug');
    log.info('excluded.info');
    log.warn('included.warn');
    log.error('included.error');
    final lines = (await log.snapshot()).lines;
    expect(lines, hasLength(2));
    expect(lines.join(), contains('included.warn'));
    expect(lines.join(), contains('included.error'));
    expect(lines.join(), isNot(contains('excluded')));
  });

  test(
    'redacts credentials and URL credentials and query parameters',
    () async {
      log.level = LogLevel.debug;
      log.registerSecret('client-secret-123');
      log.debug('request', {
        'api_key': 'another-secret',
        'headers': {'Authorization': 'Bearer auth-secret'},
        'uri': Uri.parse('https://user:pass@example.com/sync?cursor=private'),
        'message': 'client-secret-123 Bearer bearer-secret',
      });
      final text = (await log.snapshot()).lines.join();
      for (final value in [
        'client-secret-123',
        'another-secret',
        'auth-secret',
        'bearer-secret',
        'user:pass',
        'cursor=private',
      ]) {
        expect(text, isNot(contains(value)));
      }
      expect(text, contains('https://example.com/sync'));
      expect(text, contains('[REDACTED]'));
    },
  );

  test(
    'rotates four bounded files and preserves newest records across restart',
    () async {
      log.level = LogLevel.debug;
      for (var index = 0; index < 80; index++) {
        log.debug('rotation.$index', {'payload': List.filled(160, 'x').join()});
      }
      await log.flush();
      final files = await root
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(4));
      var total = 0;
      for (final file in files) {
        final bytes = await file.length();
        expect(bytes, lessThanOrEqualTo(1024));
        total += bytes;
      }
      expect(total, lessThanOrEqualTo(4096));
      final snapshot = await log.snapshot();
      expect(snapshot.lines.first, contains('rotation.79'));
      expect(snapshot.lines.join(), isNot(contains('rotation.0"')));
      final restored = AppLog(fileBytes: 1024);
      await restored.initialize(root);
      final records = await restored.snapshot();
      expect(records.lines.join(), contains('rotation.79'));
      expect(records.bytes, lessThanOrEqualTo(4096));
    },
  );

  test('serializes concurrent flushes and bounds oversized records', () async {
    await Future.wait(
      List.generate(15, (index) async {
        log.info('parallel.$index', {'payload': List.filled(4000, '音').join()});
        await log.flush();
      }),
    );
    final snapshot = await log.snapshot();
    expect(snapshot.bytes, lessThanOrEqualTo(4096));
    expect(snapshot.lines.first, contains('parallel.14'));
    for (final line in snapshot.lines) {
      expect(jsonDecode(line), isA<Map>());
      expect(utf8.encode(line).length, lessThanOrEqualTo(1024));
    }
    await log.clear();
    expect((await log.snapshot()).bytes, 0);
  });

  test(
    'real API requests record statuses without logging the API key',
    () async {
      final logger = AppLog.instance;
      await logger.initialize(root);
      logger.level = LogLevel.debug;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.uri.path.endsWith('/health')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'version': 'test'}));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final client = PikmeloApiClient(
        serverUri: Uri.parse('http://127.0.0.1:${server.port}'),
        apiKey: 'private-integration-key',
      );
      try {
        expect((await client.checkHealth())['version'], 'test');
        expect(await client.fetchCover('missing'), isNull);
        final text = (await logger.snapshot()).lines.join('\n');
        expect(text, contains('network.request'));
        expect(text, contains('network.response'));
        expect(text, contains('network.http_error'));
        expect(text, contains('"status":200'));
        expect(text, contains('"status":404'));
        expect(text, isNot(contains('private-integration-key')));
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
        await logger.flush();
        logger.directory = null;
        logger.level = LogLevel.info;
      }
    },
  );

  test('reports a bounded queue overflow', () async {
    for (var index = 0; index < 600; index++) {
      log.info('overflow.$index');
    }
    final snapshot = await log.snapshot();
    expect(snapshot.lines.first, contains('log.queue_overflow'));
    expect(snapshot.lines.first, contains('88'));
  });
}
