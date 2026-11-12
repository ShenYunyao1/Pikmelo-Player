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

  String get title => _json['title'] as String? ?? '未命名曲目';
  String? get artist => _json['artist'] as String?;
  int? get size => _json['size'] is int ? _json['size'] as int : null;
  bool get missing => _json['missing'] == true;
  bool get removed => _json['removed'] == true;

  Map<String, dynamic> toJson() => Map.of(_json);
}
