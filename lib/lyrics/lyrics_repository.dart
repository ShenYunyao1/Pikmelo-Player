import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../artwork/embedded_resources.dart';
import '../infrastructure/storage/local_library_store.dart';
import '../infrastructure/storage/media_files.dart';
import '../library/models/track.dart';
import 'lrc_parser.dart';
import '../shared/diagnostics.dart';
import 'models/lyric_document.dart';

class LyricsRepository {
  LyricsRepository({this.readEmbedded = readEmbeddedResources});
  final Future<EmbeddedResources> Function(String, MediaFiles) readEmbedded;
  final _requests = <String, Future<LyricDocument?>>{};
  final _retryAfter = <String, DateTime>{};
  Future<LyricDocument?> load({
    required String scope,
    required Track track,
    required String? path,
    required LocalLibraryStore store,
    required String retryToken,
    required bool Function() allowed,
    required Future<String?> Function() fetchServer,
  }) {
    if (!allowed()) return Future.value();
    final stat = path != null && !store.files.isDocument(path)
        ? FileStat.statSync(path)
        : null;
    final key = sha256
        .convert(
          utf8.encode(
            '$scope|${jsonEncode(track.toJson())}|$path|${stat?.size}|${stat?.modified}|$retryToken',
          ),
        )
        .toString();
    final existing = _requests[key], retry = _retryAfter[key];
    if (existing != null && (retry == null || DateTime.now().isBefore(retry))) {
      Diagnostics.event('lyrics.memory.hit');
      return existing;
    }
    if (_requests.length >= 32) {
      _retryAfter.remove(_requests.keys.first);
      _requests.remove(_requests.keys.first);
    }
    _retryAfter.remove(key);
    final elapsed = Stopwatch()..start();
    var retryable = false;
    final future = _load(
      scope,
      track,
      path,
      store,
      allowed,
      fetchServer,
      () => retryable = true,
    );
    _requests[key] = future;
    void retryLater() {
      if (identical(_requests[key], future)) {
        _retryAfter[key] = DateTime.now().add(const Duration(minutes: 1));
      }
    }

    future.then<void>((value) {
      if (value == null || retryable) retryLater();
      if (Diagnostics.enabled) {
        Diagnostics.event('lyrics.loaded', {
          'track': Diagnostics.identifier(track.id),
          'source': value?.source.name,
          'cues': value?.cues.length ?? 0,
          'ms': elapsed.elapsedMilliseconds,
        });
      }
    }, onError: (Object _, StackTrace _) => retryLater());
    return future;
  }

  Future<LyricDocument?> _load(
    String scope,
    Track track,
    String? path,
    LocalLibraryStore store,
    bool Function() allowed,
    Future<String?> Function() fetchServer,
    void Function() retryable,
  ) async {
    var localFailed = false;
    if (path != null) {
      var cached = store.localLyrics(path);
      if (cached == null) {
        try {
          final resource = await readEmbedded(path, store.files);
          if (!allowed()) return null;
          if (resource.readSucceeded) {
            store.saveLocalLyrics(path, resource.lyrics);
            cached = {'text': resource.lyrics};
          } else {
            localFailed = true;
            retryable();
          }
        } catch (_) {
          localFailed = true;
          retryable();
        }
      }
      if (!allowed()) return null;
      try {
        final document = parseLyrics(
          cached?['text'] is String ? cached!['text'] as String : null,
          LyricsSource.embedded,
        );
        if (document != null) return document;
      } on FormatException {
        localFailed = true;
        retryable();
      }
    }
    if (!allowed()) return null;
    final serverKey =
        'server_lyrics_${sha256.convert(utf8.encode('$scope|${track.id}')).toString()}';
    final revision = sha256
        .convert(utf8.encode(jsonEncode(track.toJson())))
        .toString();
    String? text = track.lyrics;
    if (text == null) {
      try {
        final cached = jsonDecode(store.setting(serverKey) ?? '{}') as Map;
        if (cached['revision'] == revision) text = cached['text'] as String?;
        Diagnostics.event('lyrics.server_cache.read', {'hit': text != null});
      } catch (_) {
        /* Fetch uncached lyrics. */
      }
    }
    if (text == null) {
      try {
        Diagnostics.event('lyrics.server.fetch');
        text = await fetchServer();
        if (!allowed()) return null;
        if (text != null) {
          Diagnostics.event('lyrics.server_cache.write', {
            'chars': text.length,
          });
          store.saveSetting(
            serverKey,
            jsonEncode({'revision': revision, 'text': text}),
          );
        }
      } catch (_) {
        if (!allowed()) return null;
        throw const LyricsUnavailable();
      }
    }
    if (!allowed()) return null;
    try {
      final document = parseLyrics(text, LyricsSource.server);
      if (document != null) return document;
    } on FormatException {
      throw const LyricsUnavailable();
    }
    if (localFailed) throw const LyricsUnavailable();
    return null;
  }
}
