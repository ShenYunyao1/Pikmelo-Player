import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pikmelo_player/infrastructure/storage/local_library_store.dart';
import 'package:pikmelo_player/settings/media_storage_controller.dart';
import 'package:pikmelo_player/updates/github_update_service.dart';
import 'package:pikmelo_player/updates/update_controller.dart';
import 'package:pikmelo_player/updates/update_platform.dart';
import 'package:pikmelo_player/updates/update_release.dart';

final _certificate = List.filled(64, 'a').join();
Map<String, dynamic> _manifest(List<int> bytes) => {
  'schema': 1,
  'version': '1.0.1',
  'versionCode': 101,
  'packageName': 'top.shenyunyao.pikmelo_player',
  'signerSha256': _certificate,
  'artifacts': [
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64'])
      {
        'platform': 'android',
        'abi': abi,
        'name': 'Pikmelo-Player-1.0.1-$abi.apk',
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Transport cases intentionally use a real loopback HTTP server.
  HttpOverrides.global = null;
  test('ABI selection follows the device preference and rejects missing architectures', () {
    final release = UpdateRelease.fromJson(
      _manifest([1, 2]),
      page: GitHubUpdateService.releasesPage,
      downloadBase: GitHubUpdateService.releasesPage,
    );
    expect(release.select(['x86_64', 'arm64-v8a']).abi, 'x86_64');
    expect(release.select(['arm64-v8a', 'armeabi-v7a']).abi, 'arm64-v8a');
    expect(release.select(['armeabi-v7a']).abi, 'armeabi-v7a');
    expect(() => release.select(['x86']), throwsFormatException);
  });
  test('manifest rejects duplicate architectures and path traversal', () {
    final json = _manifest([1, 2]);
    (json['artifacts'] as List)[0]['name'] = '../update.apk';
    expect(
      () => UpdateRelease.fromJson(
        json,
        page: GitHubUpdateService.releasesPage,
        downloadBase: GitHubUpdateService.releasesPage,
      ),
      throwsFormatException,
    );
    final duplicate = _manifest([1, 2]);
    (duplicate['artifacts'] as List).add(
      (duplicate['artifacts'] as List).first,
    );
    expect(
      () => UpdateRelease.fromJson(
        duplicate,
        page: GitHubUpdateService.releasesPage,
        downloadBase: GitHubUpdateService.releasesPage,
      ),
      throwsFormatException,
    );
  });

  group('GitHub transport', () {
    late HttpServer server;
    late Directory root;
    late GitHubUpdateService service;
    late Uri origin;
    final bytes = List.generate(100, (index) => index);
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = Uri.parse('http://127.0.0.1:${server.port}/');
      root = await Directory.systemTemp.createTemp('pikmelo-update-');
      service = GitHubUpdateService(apiBase: origin);
    });
    tearDown(() async {
      service.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    void serve({bool corrupt = false, bool wrongDigest = false}) {
      server.listen((request) async {
        final manifest = _manifest(bytes);
        if (request.uri.path == '/releases/latest') {
          request.response.write(
            jsonEncode({
              'tag_name': 'v1.0.1',
              'assets': [
                {'name': 'updates.json'},
                for (final item in manifest['artifacts'] as List)
                  {
                    'name': item['name'],
                    'size': item['size'],
                    'digest':
                        'sha256:${wrongDigest ? _certificate : item['sha256']}',
                  },
              ],
            }),
          );
        } else if (request.uri.path.endsWith('updates.json')) {
          request.response.write(jsonEncode(manifest));
        } else {
          request.response.add(corrupt ? List.filled(bytes.length, 0) : bytes);
        }
        await request.response.close();
      });
    }

    test(
      'checks public release metadata and verifies the downloaded bytes',
      () async {
        serve();
        final release = (await service.latest())!;
        final artifact = release.select(['arm64-v8a']);
        final file = await service.download(
          release,
          artifact,
          root,
          onProgress: (_) {},
        );
        expect(await file.readAsBytes(), bytes);
        expect(file.path, endsWith(artifact.name));
      },
    );
    test('corrupt APK is rejected and its partial file is removed', () async {
      serve(corrupt: true);
      final release = (await service.latest())!;
      await expectLater(
        service.download(
          release,
          release.select(['x86_64']),
          root,
          onProgress: (_) {},
        ),
        throwsFormatException,
      );
      expect(await root.list().toList(), isEmpty);
    });
    test('GitHub asset digest must agree with the manifest', () async {
      serve(wrongDigest: true);
      await expectLater(service.latest(), throwsFormatException);
    });
    test('missing release returns no available update', () async {
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });
      expect(await service.latest(), isNull);
    });
  });

  group('Update controller', () {
    late LocalLibraryStore store;
    late MediaStorageController storage;
    late Directory root;
    late UpdateController controller;
    late _Platform platform;
    late _Service service;
    var mobile = false;
    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'pikmelo-update-controller-',
      );
      store = await LocalLibraryStore.open(databasePath: ':memory:');
      store.saveSetting('automatic_updates', 'false');
      mobile = false;
      storage = MediaStorageController(
        store,
        networkReader: () async => {'connected': true, 'cellular': mobile},
      );
      service = _Service();
      platform = _Platform(root.path);
      controller = UpdateController(service: service, platform: platform);
    });
    tearDown(() async {
      await controller.shutdown();
      await storage.shutdown();
      store.close();
      await root.delete(recursive: true);
    });
    test('version check offers only a strictly newer release', () async {
      platform.code = 101;
      await controller.initialize(storage);
      expect(controller.release, isNull);
      expect(controller.message, '已是最新版本');
      expect(service.downloads, 0);
    });
    test('manual update verifies before installation and persists recovery metadata', () async {
      await controller.initialize(storage);
      await controller.downloadAndInstall();
      expect(platform.operations, ['verify', 'install']);
      expect(controller.phase, UpdatePhase.installing);
      expect(store.setting('pending_app_update'), isNotEmpty);
    });
    test(
      'permission requirement opens settings and avoids premature installation',
      () async {
        platform.permission = false;
        await controller.initialize(storage);
        await controller.downloadAndInstall();
        expect(platform.operations, ['verify', 'permission']);
        expect(controller.phase, UpdatePhase.permission);
      },
    );
    test('prohibit cellular policy blocks update downloads', () async {
      mobile = true;
      storage.setMobilePolicy(MobileDownloadPolicy.prohibit);
      await controller.initialize(storage);
      await controller.downloadAndInstall();
      expect(service.downloads, 0);
      expect(controller.phase, UpdatePhase.failed);
      expect(platform.operations, isEmpty);
    });
    test('signature validation failure prevents installation', () async {
      platform.rejectSignature = true;
      await controller.initialize(storage);
      await controller.downloadAndInstall();
      expect(platform.operations, ['verify']);
      expect(controller.phase, UpdatePhase.failed);
    });
    test('automatic update executes once when enabled and permitted', () async {
      store.saveSetting('automatic_updates', 'true');
      await controller.initialize(storage);
      expect(service.downloads, 1);
      expect(platform.operations, ['verify', 'install']);
      expect(store.setting('last_update_attempt'), '101');
    });
  });
}

class _Service extends GitHubUpdateService {
  int downloads = 0;
  final release = UpdateRelease.fromJson(
    _manifest([1, 2]),
    page: GitHubUpdateService.releasesPage,
    downloadBase: Uri.parse(
      'https://github.com/ShenYunyao1/Pikmelo-Player/releases/download/v1.0.1/',
    ),
  );
  @override
  Future<UpdateRelease?> latest() async => release;
  @override
  Future<File> download(
    UpdateRelease release,
    UpdateArtifact artifact,
    Directory directory, {
    required void Function(int received) onProgress,
  }) async {
    downloads++;
    return File('${directory.path}/${artifact.name}').writeAsBytes([1, 2]);
  }
}

class _Platform extends UpdatePlatform {
  _Platform(this.directory);
  final String directory;
  final operations = <String>[];
  int code = 100;
  bool permission = true;
  bool rejectSignature = false;
  @override
  Future<Map<String, dynamic>> info() async => {
    'platform': 'android',
    'version': '1.0.0',
    'versionCode': code,
    'abis': ['x86_64', 'arm64-v8a'],
    'directory': directory,
    'signerSha256': _certificate,
    'canInstall': permission,
    'installStatus': 'idle',
  };
  @override
  Future<void> verify(
    String path,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) async {
    operations.add('verify');
    if (rejectSignature) throw const FormatException('签名无效');
  }

  @override
  Future<void> install(
    String path,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) async {
    operations.add('install');
  }

  @override
  Future<void> requestPermission() async {
    operations.add('permission');
  }
}
