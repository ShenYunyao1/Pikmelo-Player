import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../settings/models/server_connection.dart';

class ApiKeyStore {
  ApiKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<void> save(String serverKey, String apiKey) =>
      _storage.write(key: _storageKey(serverKey), value: apiKey);

  Future<String?> read(String serverKey) =>
      _storage.read(key: _storageKey(serverKey));

  Future<void> delete(String serverKey) =>
      _storage.delete(key: _storageKey(serverKey));

  Future<String?> readConnection(ServerConnection connection) async {
    for (final key in _connectionKeys(connection)) {
      final value = await read(key);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  Future<void> saveConnection(
    ServerConnection connection,
    String apiKey,
  ) async {
    await save(connection.key, apiKey);
    for (final legacyKey in _connectionKeys(connection).skip(1)) {
      await delete(legacyKey);
    }
  }

  Iterable<String> _connectionKeys(ServerConnection connection) {
    final raw = connection.uri.toString().replaceFirst(RegExp(r'/+$'), '');
    return {connection.key, raw, '$raw/'};
  }

  static String _storageKey(String serverKey) => 'pikmelo_api_key_$serverKey';
}
