class PikmeloSyncPage {
  const PikmeloSyncPage({
    required this.changedTracks,
    required this.playlists,
    required this.deletedTracks,
    required this.deletedPlaylists,
    required this.cursor,
    required this.hasMore,
    required this.fullSnapshot,
    required this.reset,
    required this.revision,
  });

  final List<Map<String, dynamic>> changedTracks;
  final List<Map<String, dynamic>> playlists;
  final List<String> deletedTracks;
  final List<String> deletedPlaylists;
  final String cursor;
  final bool hasMore;
  final bool fullSnapshot;
  final bool reset;
  final int revision;

  factory PikmeloSyncPage.fromJson(Map<String, dynamic> json) {
    return PikmeloSyncPage(
      changedTracks: _objectList(json['changed_tracks'], 'changed_tracks'),
      playlists: _objectList(json['playlists'], 'playlists'),
      deletedTracks: _stringList(json['deleted_tracks'], 'deleted_tracks'),
      deletedPlaylists: _stringList(
        json['deleted_playlists'],
        'deleted_playlists',
      ),
      cursor: _stringValue(json['cursor'], 'cursor'),
      hasMore: _boolValue(json['has_more'], 'has_more'),
      fullSnapshot: _boolValue(json['full_snapshot'], 'full_snapshot'),
      reset: _boolValue(json['reset'], 'reset'),
      revision: _intValue(json['revision'], 'revision'),
    );
  }

  static List<Map<String, dynamic>> _objectList(Object? value, String field) {
    if (value is! List) {
      throw FormatException('Expected $field to be a list.');
    }
    return value
        .map((item) {
          if (item is! Map) {
            throw FormatException('Expected objects in $field.');
          }
          return Map<String, dynamic>.from(item);
        })
        .toList(growable: false);
  }

  static List<String> _stringList(Object? value, String field) {
    if (value is! List || value.any((item) => item is! String)) {
      throw FormatException('Expected $field to be a list of strings.');
    }
    return List<String>.from(value);
  }

  static String _stringValue(Object? value, String field) {
    if (value is! String) {
      throw FormatException('Expected $field to be a string.');
    }
    return value;
  }

  static bool _boolValue(Object? value, String field) {
    if (value is! bool) {
      throw FormatException('Expected $field to be a boolean.');
    }
    return value;
  }

  static int _intValue(Object? value, String field) {
    if (value is! int) {
      throw FormatException('Expected $field to be an integer.');
    }
    return value;
  }
}
