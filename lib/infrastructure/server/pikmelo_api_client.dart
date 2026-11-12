import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../settings/models/server_connection.dart';

import 'sync_page.dart';

class PikmeloApiException implements Exception {
  const PikmeloApiException(
    this.statusCode,
    this.code,
    this.message, {
    this.retryAfter,
  });

  final int statusCode;
  final String code;
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => '$code: $message (HTTP $statusCode)';
}

class MediaDownloadResult {
  const MediaDownloadResult({
    required this.file,
    required this.etag,
    required this.bytesWritten,
  });

  final File file;
  final String? etag;
  final int bytesWritten;
}

class PikmeloApiClient {
  PikmeloApiClient({
    required Uri serverUri,
    required this._apiKey,
    HttpClient? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
    this.maxRetries = 2,
    this._retryDelay,
  }) : _serverUri = ServerConnection(serverUri).uri,
       _httpClient = httpClient ?? HttpClient() {
    _httpClient.connectionTimeout = requestTimeout;
  }

  final Uri _serverUri;
  final String _apiKey;
  final HttpClient _httpClient;
  final Duration requestTimeout;
  final int maxRetries;
  final Future<void> Function(Duration)? _retryDelay;
  final _closed = Completer<void>();

  Future<Map<String, dynamic>> checkHealth() => _getJsonUri(_apiUri('health'));

  Future<Uint8List?> fetchCover(String id) => _retry(() async {
    if (id.isEmpty || id.contains('/') || id.contains('\\')) {
      throw ArgumentError.value(id, 'id');
    }
    final request = await _httpClient
        .getUrl(_apiUri('covers/$id'))
        .timeout(requestTimeout);
    request.followRedirects = false;
    _setAuthHeaders(request);
    request.headers.set(HttpHeaders.acceptHeader, 'image/*');
    final response = await _timeout(request.close(), request);
    if (response.statusCode == 404) {
      await _timeout(response.drain<void>(), request);
      return null;
    }
    if (response.statusCode != 200) await _throwResponseError(response);
    final bytes = BytesBuilder(copy: false);
    await _timeout(() async {
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024) {
          request.abort();
          throw const FormatException('Cover exceeds size limit');
        }
        bytes.add(chunk);
      }
    }(), request);
    return bytes.takeBytes();
  });

  Future<PikmeloSyncPage> fetchSyncPage({
    String? cursor,
    int limit = 100,
  }) async {
    final uri = _apiUri('sync').replace(
      queryParameters: {
        'limit': '$limit',
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
    );
    return PikmeloSyncPage.fromJson(await _getJsonUri(uri));
  }

  Future<void> checkMediaAccess(String trackId) =>
      _retry(() => _checkMediaAccess(trackId));

  Future<void> _checkMediaAccess(String trackId) async {
    if (trackId.isEmpty || trackId.contains('/') || trackId.contains('\\')) {
      throw ArgumentError.value(trackId, 'trackId');
    }
    final request = await _httpClient
        .openUrl('HEAD', _apiUri('media/$trackId'))
        .timeout(requestTimeout);
    _setAuthHeaders(request);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await _timeout(request.close(), request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _throwResponseError(response);
    }
    await _timeout(response.drain<void>(), request);
  }

  Future<MediaDownloadResult> downloadMedia({
    required String trackId,
    required Directory directory,
    required int expectedBytes,
    String? resumeEtag,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    void Function(String? etag)? onEtag,
  }) async {
    if (trackId.isEmpty || trackId.contains('/') || trackId.contains('\\')) {
      throw ArgumentError.value(trackId, 'trackId');
    }
    await directory.create(recursive: true);
    final partialFile = File(
      '${directory.path}${Platform.pathSeparator}$trackId.part',
    );
    final completedFile = File(
      '${directory.path}${Platform.pathSeparator}$trackId-${DateTime.now().microsecondsSinceEpoch}.media',
    );
    var receivedBytes = await partialFile.exists()
        ? await partialFile.length()
        : 0;
    if (expectedBytes > 0 && receivedBytes > expectedBytes) {
      await partialFile.delete();
      receivedBytes = 0;
    }

    String? etag = resumeEtag;
    final initialLength = receivedBytes;
    while (expectedBytes <= 0 || receivedBytes < expectedBytes) {
      if (_closed.isCompleted) throw StateError('The API client is closed.');
      final request = await _httpClient
          .getUrl(_apiUri('media/$trackId'))
          .timeout(requestTimeout);
      _setAuthHeaders(request);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (receivedBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$receivedBytes-');
        if (etag != null && etag.isNotEmpty) {
          request.headers.set(HttpHeaders.ifRangeHeader, etag);
        }
      }

      final response = await _timeout(request.close(), request);
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await _throwResponseError(response);
      }

      final isPartial = response.statusCode == HttpStatus.partialContent;
      final range = isPartial ? _parseContentRange(response) : null;
      final responseEtag = response.headers.value(HttpHeaders.etagHeader);
      if (isPartial &&
          receivedBytes > 0 &&
          etag != null &&
          responseEtag != null &&
          responseEtag != etag) {
        await response.drain<void>();
        if (await partialFile.exists()) await partialFile.delete();
        receivedBytes = 0;
        etag = null;
        continue;
      }
      if (isPartial && (range == null || range.start != receivedBytes)) {
        throw const FormatException(
          'The server returned an invalid media range.',
        );
      }
      if (range != null && expectedBytes > 0 && range.total != expectedBytes) {
        throw const FormatException(
          'The media range total does not match the track size.',
        );
      }
      if (!isPartial) {
        await partialFile.writeAsBytes(const [], flush: true);
        receivedBytes = 0;
      }
      etag = responseEtag ?? etag;
      onEtag?.call(etag);
      final segmentLength = response.contentLength >= 0
          ? response.contentLength
          : range == null
          ? null
          : range.end - range.start + 1;
      final file = await partialFile.open(
        mode: receivedBytes > 0 ? FileMode.append : FileMode.write,
      );
      var segmentBytes = 0;
      try {
        await for (final bytes in response.timeout(requestTimeout)) {
          await file.writeFrom(bytes);
          segmentBytes += bytes.length;
          receivedBytes += bytes.length;
          onProgress?.call(
            receivedBytes,
            expectedBytes > 0 ? expectedBytes : range?.total,
          );
        }
        await file.flush();
      } finally {
        await file.close();
      }

      if (segmentLength != null && segmentBytes != segmentLength) {
        throw const HttpException(
          'The media response ended before its declared length.',
        );
      }
      if (range != null &&
          segmentLength != null &&
          range.end - range.start + 1 != segmentLength) {
        throw const FormatException(
          'The media range length does not match its response body.',
        );
      }
      if (range != null && range.total > 0 && receivedBytes > range.total) {
        throw const FormatException(
          'The downloaded media exceeds its declared size.',
        );
      }
      if (expectedBytes > 0 && receivedBytes > expectedBytes) {
        throw const FormatException(
          'The downloaded media exceeds the track size.',
        );
      }
      if (expectedBytes <= 0 && !isPartial) {
        break;
      }
      if (expectedBytes <= 0 && range != null && receivedBytes >= range.total) {
        break;
      }
      if (segmentBytes == 0) {
        throw const HttpException('The media server returned an empty range.');
      }
    }

    if (expectedBytes > 0 && receivedBytes != expectedBytes) {
      throw const HttpException(
        'The downloaded media size does not match the track.',
      );
    }
    if (_closed.isCompleted) throw StateError('The API client is closed.');
    await partialFile.rename(completedFile.path);
    return MediaDownloadResult(
      file: completedFile,
      etag: etag,
      bytesWritten: receivedBytes - initialLength,
    );
  }

  void close() {
    if (!_closed.isCompleted) _closed.complete();
    _httpClient.close(force: true);
  }

  Uri _apiUri(String endpoint) {
    final basePath = _serverUri.path.replaceFirst(RegExp(r'/+$'), '');
    return _serverUri.replace(path: '$basePath/api/v2/$endpoint');
  }

  Future<Map<String, dynamic>> _getJsonUri(Uri uri) =>
      _retry(() => _getJsonOnce(uri));

  Future<Map<String, dynamic>> _getJsonOnce(Uri uri) async {
    final request = await _httpClient.getUrl(uri).timeout(requestTimeout);
    _setAuthHeaders(request);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await _timeout(request.close(), request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _throwResponseError(response);
    }
    final body = await _timeout(utf8.decoder.bind(response).join(), request);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException(
        'The server returned an invalid JSON object.',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  void _setAuthHeaders(HttpClientRequest request) {
    request.headers.set('X-API-Key', _apiKey);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  }

  Future<void> _throwResponseError(HttpClientResponse response) async {
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(requestTimeout);
    var code =
        response.headers.value('X-Error-Code') ?? 'HTTP_${response.statusCode}';
    var message = response.reasonPhrase;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        code = decoded['code'] is String ? decoded['code'] as String : code;
        message = decoded['error'] is String
            ? decoded['error'] as String
            : message;
      }
    } on FormatException {
      if (body.isNotEmpty && body.length < 512) {
        message = body;
      }
    }
    throw PikmeloApiException(
      response.statusCode,
      code,
      message,
      retryAfter: _parseRetryAfter(response.headers.value('Retry-After')),
    );
  }

  Future<T> _timeout<T>(Future<T> operation, HttpClientRequest request) =>
      operation.timeout(
        requestTimeout,
        onTimeout: () {
          final error = TimeoutException(
            'The server request timed out.',
            requestTimeout,
          );
          request.abort(error);
          throw error;
        },
      );

  Future<T> _retry<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      if (_closed.isCompleted) throw StateError('The API client is closed.');
      try {
        return await operation();
      } on PikmeloApiException catch (error) {
        if (error.statusCode != 429 || attempt >= maxRetries) rethrow;
        await _waitForRetry(error.retryAfter ?? Duration(seconds: attempt + 1));
      }
    }
  }

  Future<void> _waitForRetry(Duration duration) async {
    Timer? timer;
    final elapsed = Completer<void>();
    final waiting = _retryDelay == null
        ? elapsed.future
        : _retryDelay(duration);
    if (_retryDelay == null) timer = Timer(duration, elapsed.complete);
    try {
      await Future.any([
        waiting,
        _closed.future.then<void>(
          (_) => throw StateError('The API client is closed.'),
        ),
      ]);
    } finally {
      timer?.cancel();
    }
  }

  static Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    try {
      final duration = HttpDate.parse(value).difference(DateTime.now().toUtc());
      return duration.isNegative ? Duration.zero : duration;
    } on HttpException {
      return null;
    }
  }

  static _MediaRange? _parseContentRange(HttpClientResponse response) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null
        ? null
        : RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null || match.group(3) == '*') {
      return null;
    }
    return _MediaRange(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }
}

class _MediaRange {
  const _MediaRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
}
