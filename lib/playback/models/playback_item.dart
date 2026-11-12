import '../../library/models/track.dart';

class PlaybackItem {
  const PlaybackItem({
    required this.serverUri,
    required this.track,
    required this.path,
  });

  final Uri serverUri;
  final Track track;
  final String path;
}
