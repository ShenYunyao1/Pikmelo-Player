import 'dart:convert';

import 'package:crypto/crypto.dart';

class ServerConnection {
  ServerConnection(this.uri) {
    final isLocalHttp =
        uri.scheme == 'http' &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1');
    if ((!isLocalHttp && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError.value(
        uri,
        'serverUri',
        'Use an HTTPS server address.',
      );
    }
  }

  static final defaultUri = Uri.parse('https://music.shenyunyao.top:18443');

  final Uri uri;

  String get key => serverKey(uri);

  static String credentialFingerprint(String apiKey) =>
      sha256.convert(utf8.encode(apiKey)).toString();

  static String serverKey(Uri uri) {
    final normalizedPath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri
        .replace(path: normalizedPath, query: '', fragment: '')
        .toString();
  }
}
