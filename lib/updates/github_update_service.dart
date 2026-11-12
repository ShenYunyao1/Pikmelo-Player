import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'update_release.dart';

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class GitHubUpdateService {
  GitHubUpdateService({Uri? apiBase})
    : apiBase =
          apiBase ??
          Uri.https('api.github.com', '/repos/ShenYunyao1/Pikmelo-Player/');
  final Uri apiBase;
  String? proxy;
  HttpClient? _downloadClient;
  final _clients = <HttpClient>{};
  int _generation = 0;
  bool _closed = false;
  static final releasesPage = Uri.https(
    'github.com',
    '/ShenYunyao1/Pikmelo-Player/releases',
  );

  bool _allowed(Uri uri) {
    if (apiBase.scheme == 'http' && apiBase.host == '127.0.0.1') {
      return uri.origin == apiBase.origin;
    }
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        {
          'api.github.com',
          'github.com',
          'objects.githubusercontent.com',
          'release-assets.githubusercontent.com',
        }.contains(uri.host);
  }

  HttpClient _client() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    client.findProxy = (uri) =>
        proxy ?? HttpClient.findProxyFromEnvironment(uri);
    return client;
  }

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_closed) throw const UpdateCancelled();
      if (!_allowed(uri)) throw const FormatException('更新地址不受信任。');
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Pikmelo-Player');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (location == null) throw const FormatException('更新下载重定向无效。');
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw HttpException('更新请求失败（${response.statusCode}）', uri: uri);
      }
      return response;
    }
    throw const FormatException('更新下载重定向过多。');
  }

  Future<Map<String, dynamic>?> _json(
    Uri uri, {
    bool missingAllowed = false,
  }) async {
    final client = _client();
    _clients.add(client);
    try {
      HttpClientResponse response;
      try {
        response = await _get(client, uri);
      } on HttpException catch (error) {
        if (missingAllowed && error.message == '更新请求失败（404）') return null;
        rethrow;
      }
      final data = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        if (data.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('更新响应过大。');
        }
        data.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('更新响应格式无效。');
      }
      return decoded;
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<UpdateRelease?> latest() async {
    final release = await _json(
      apiBase.resolve('releases/latest'),
      missingAllowed: true,
    );
    if (release == null) return null;
    if (release['draft'] == true || release['prerelease'] == true) return null;
    final tag = release['tag_name'];
    if (tag is! String ||
        !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
        release['assets'] is! List) {
      throw const FormatException('发布版本信息无效。');
    }
    final local = apiBase.scheme == 'http';
    final base = local
        ? apiBase.resolve('downloads/$tag/')
        : Uri.https(
            'github.com',
            '/ShenYunyao1/Pikmelo-Player/releases/download/$tag/',
          );
    final assets = (release['assets'] as List).whereType<Map>().toList();
    final manifests = assets.where((asset) => asset['name'] == 'updates.json');
    if (manifests.length != 1) throw const FormatException('该发布缺少更新清单。');
    final manifest = await _json(base.resolve('updates.json'));
    final parsed = UpdateRelease.fromJson(
      manifest!,
      page: local ? apiBase : Uri.parse('$releasesPage/tag/$tag'),
      downloadBase: base,
    );
    if (tag != 'v${parsed.version}') {
      throw const FormatException('版本标签与更新清单不一致。');
    }
    for (final item in parsed.artifacts) {
      final matches = assets.where((asset) => asset['name'] == item.name);
      if (matches.length != 1 ||
          matches.single['size'] != item.size ||
          (matches.single['digest'] != null &&
              matches.single['digest'] != 'sha256:${item.sha256}')) {
        throw const FormatException('发布资产与更新清单不一致。');
      }
    }
    return parsed;
  }

  Future<File> download(
    UpdateRelease release,
    UpdateArtifact artifact,
    Directory directory, {
    required void Function(int received) onProgress,
  }) async {
    final generation = ++_generation;
    final client = _client();
    _downloadClient?.close(force: true);
    _downloadClient = client;
    final target = File(
      '${directory.path}${Platform.pathSeparator}${artifact.name}',
    );
    final partial = File('${target.path}.part');
    IOSink? sink;
    try {
      await directory.create(recursive: true);
      final existing = await cached(artifact, directory);
      if (generation != _generation || _closed) throw const UpdateCancelled();
      if (existing != null) return existing;
      if (await target.exists()) await target.delete();
      final response = await _get(
        client,
        release.downloadBase.resolve(artifact.name),
      );
      if (response.contentLength >= 0 &&
          response.contentLength != artifact.size) {
        throw const FormatException('安装包大小不符。');
      }
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (generation != _generation || _closed) throw const UpdateCancelled();
        received += chunk.length;
        if (received > artifact.size) throw const FormatException('安装包超出预期大小。');
        sink.add(chunk);
        onProgress(received);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (generation != _generation || _closed) throw const UpdateCancelled();
      if (received != artifact.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              artifact.sha256) {
        throw const FormatException('安装包 SHA-256 校验失败。');
      }
      return await partial.rename(target.path);
    } catch (error) {
      if (generation != _generation || _closed) throw const UpdateCancelled();
      rethrow;
    } finally {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
      client.close(force: true);
      if (identical(_downloadClient, client)) _downloadClient = null;
    }
  }

  Future<File?> cached(UpdateArtifact artifact, Directory directory) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}${artifact.name}',
    );
    if (await file.exists() &&
        await file.length() == artifact.size &&
        (await sha256.bind(file.openRead()).first).toString() ==
            artifact.sha256) {
      return file;
    }
    return null;
  }

  void cancel() {
    _generation++;
    _downloadClient?.close(force: true);
  }

  void dispose() {
    _closed = true;
    cancel();
    for (final client in _clients) {
      client.close(force: true);
    }
  }
}
