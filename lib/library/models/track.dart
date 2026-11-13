class Track {
  factory Track.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('The track response did not include an ID.');
    }
    return Track._(id, Map.unmodifiable(json));
  }

  const Track._(this.id, this._json);

  final String id;
  final Map<String, dynamic> _json;

  String get title => _text('title') ?? '未命名曲目';
  String? get artist => _text('artist');
  String? get album => _text('album');
  String? get genre => _text('genre');
  String? get comment => _text('comment');
  String? get format => _text('format');
  bool get parsedLocally => _json['_local_metadata'] == true;
  int? get bitrateKbps => _positiveInteger('bitrate_kbps');
  int? get sampleRate => _positiveInteger('sample_rate');
  int? get channels => _positiveInteger('channels');
  int? get bitsPerSample => _positiveInteger('bits_per_sample');
  Duration? get duration {
    final milliseconds = _positiveInteger('duration_ms');
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  String get subtitle => [artist, album].whereType<String>().join(' · ');

  String? _text(String key) {
    final value = _json[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  int? _positiveInteger(String key) {
    final value = _json[key];
    return value is num &&
            value.isFinite &&
            value >= 1 &&
            value <= 9223372036854775
        ? value.toInt()
        : null;
  }

  String? get coverId {
    final value = _json['cover_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  int? get size => _json['size'] is int ? _json['size'] as int : null;
  bool get missing => _json['missing'] == true;
  bool get removed => _json['removed'] == true;

  Map<String, dynamic> toJson() => Map.of(_json);
}
