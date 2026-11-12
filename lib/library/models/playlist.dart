class Playlist {
  factory Playlist.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'The playlist response did not include an ID.',
      );
    }
    return Playlist._(
      id,
      Map.unmodifiable(json),
      _trackIds(json['track_ids']),
      _trackIds(json['unavailable_track_ids']),
    );
  }

  const Playlist._(
    this.id,
    this._json,
    this.trackIds,
    this.unavailableTrackIds,
  );

  final String id;
  final Map<String, dynamic> _json;
  final List<String> trackIds;
  final List<String> unavailableTrackIds;

  String get name => _json['name'] as String? ?? '未命名歌单';
  String? get coverId {
    final value = _json['cover_id'];
    return value is String && value.isNotEmpty ? value : null;
  }
  bool get readOnly => _json['read_only'] == true;
  bool get subscriptionInvalid => _json['subscription_status'] == 'invalid';

  Map<String, dynamic> toJson() => Map.of(_json);

  static List<String> _trackIds(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.any((item) => item is! String)) {
      throw const FormatException('Expected playlist track IDs to be strings.');
    }
    return List<String>.unmodifiable(value);
  }
}
