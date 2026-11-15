import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

enum LogLevel { error, warn, info, debug }

class AppLog {
  AppLog({this.fileBytes = 5 * 1024 * 1024}) : assert(fileBytes >= 512);

  static final instance = AppLog();
  final int fileBytes;
  static const fileCount = 4;
  LogLevel level = LogLevel.info;
  Directory? directory;
  String? lastError;
  final _queue = <String>[];
  final _secrets = <String>{};
  Future<void> _work = Future.value();
  Timer? _timer;
  int _dropped = 0;

  Future<void> initialize([Directory? root]) async {
    try {
      directory =
          root ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/PikmeloPlayer/logs',
          );
      await directory!.create(recursive: true);
      info('log.ready', {'level': level.name});
    } catch (error) {
      lastError = '日志目录初始化失败（${error.runtimeType}）';
    }
  }

  void registerSecret(String value) {
    if (value.length < 4) return;
    if (_secrets.length >= 128) _secrets.remove(_secrets.first);
    _secrets.add(value);
  }

  Object? _sanitize(Object? value, [String key = '']) {
    if (RegExp(
      r'api.?key|authorization|token|password|credential|secret',
      caseSensitive: false,
    ).hasMatch(key)) {
      return '[REDACTED]';
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _sanitize(entry.value, entry.key.toString()),
      };
    }
    if (value is Iterable) {
      return value.take(30).map((item) => _sanitize(item)).toList();
    }
    if (value == null || value is num || value is bool) return value;
    var text = value.toString();
    for (final secret in _secrets) {
      text = text.replaceAll(secret, '[REDACTED]');
    }
    text = text.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    text = text.replaceAllMapped(RegExp(r'https?://[^\s]+'), (match) {
      final uri = Uri.tryParse(match[0]!);
      return uri == null || !uri.hasAuthority || uri.host.isEmpty
          ? '[URL]'
          : '${uri.origin}${uri.path}';
    });
    return text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
  }

  void write(
    LogLevel severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    if (directory == null || severity.index > level.index) return;
    final record = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'level': severity.name,
      'event': _sanitize(event.length > 64 ? event.substring(0, 64) : event),
      'data': _sanitize(fields),
    };
    var line = jsonEncode(record);
    if (utf8.encode(line).length + 1 > min(fileBytes, 16 * 1024)) {
      record['data'] = {'truncated': true};
      line = jsonEncode(record);
    }
    if (_queue.length >= 512) {
      _queue.removeAt(0);
      _dropped++;
    }
    _queue.add('$line\n');
    _timer ??= Timer(const Duration(seconds: 1), () => unawaited(flush()));
  }

  void debug(String event, [Map<String, Object?> fields = const {}]) =>
      write(LogLevel.debug, event, fields);
  void info(String event, [Map<String, Object?> fields = const {}]) =>
      write(LogLevel.info, event, fields);
  void warn(String event, [Map<String, Object?> fields = const {}]) =>
      write(LogLevel.warn, event, fields);
  void error(String event, [Map<String, Object?> fields = const {}]) =>
      write(LogLevel.error, event, fields);

  File _file(int index) => File('${directory!.path}/app-$index.jsonl');

  Future<void> flush() {
    if (directory == null) return Future.value();
    _timer?.cancel();
    _timer = null;
    final lines = _queue.toList();
    _queue.clear();
    if (_dropped > 0) {
      lines.add(
        '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'level': 'warn', 'event': 'log.queue_overflow', 'dropped': _dropped})}\n',
      );
      _dropped = 0;
    }
    _work = _work
        .then((_) async {
          if (directory == null || lines.isEmpty) return;
          var size = await _file(0).exists() ? await _file(0).length() : 0;
          var buffer = BytesBuilder(copy: false);
          for (final line in lines) {
            final bytes = utf8.encode(line);
            if (size + buffer.length + bytes.length > fileBytes) {
              if (buffer.isNotEmpty) {
                await _file(0)
                    .writeAsBytes(buffer.takeBytes(), mode: FileMode.append);
              }
              await _rotate();
              size = 0;
            }
            buffer.add(bytes);
          }
          if (buffer.isNotEmpty) {
            await _file(0).writeAsBytes(
              buffer.takeBytes(),
              mode: FileMode.append,
              flush: true,
            );
          }
          lastError = null;
        })
        .catchError((Object error, StackTrace _) {
          lastError = '日志写入失败（${error.runtimeType}）';
        });
    return _work;
  }

  Future<void> _rotate() async {
    final oldest = _file(fileCount - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var index = fileCount - 2; index >= 0; index--) {
      final file = _file(index);
      if (await file.exists()) await file.rename(_file(index + 1).path);
    }
  }

  Future<({int bytes, List<String> lines})> snapshot() async {
    if (directory == null) return (bytes: 0, lines: <String>[]);
    await flush();
    final result = _work.then((_) async {
      if (directory == null) return (bytes: 0, lines: <String>[]);
      var bytes = 0;
      final lines = <String>[];
      for (var index = 0; index < fileCount; index++) {
        final file = _file(index);
        if (!await file.exists()) continue;
        final size = await file.length();
        bytes += size;
        if (lines.length >= 200) continue;
        final handle = await file.open();
        try {
          final start = max(0, size - 128 * 1024);
          await handle.setPosition(start);
          final text = utf8.decode(
            await handle.read(size - start),
            allowMalformed: true,
          );
          final records = const LineSplitter().convert(text);
          if (start > 0 && records.isNotEmpty) records.removeAt(0);
          lines.addAll(records.reversed.take(200 - lines.length));
        } finally {
          await handle.close();
        }
      }
      return (bytes: bytes, lines: lines);
    });
    _work = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> clear() async {
    if (directory == null) return;
    await flush();
    _work = _work
        .then((_) async {
          if (directory == null) return;
          for (var index = 0; index < fileCount; index++) {
            final file = _file(index);
            if (await file.exists()) await file.delete();
          }
        })
        .catchError((Object error, StackTrace _) {
          lastError = '日志清理失败（${error.runtimeType}）';
        });
    await _work;
  }
}
