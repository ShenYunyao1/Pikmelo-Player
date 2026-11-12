import 'track.dart';

class PlaylistEntry {
  const PlaylistEntry({
    required this.id,
    required this.track,
    required this.unavailable,
    required this.downloaded,
  });

  final String id;
  final Track? track;
  final bool unavailable;
  final bool downloaded;

  bool get canDownload =>
      !unavailable && track?.size != null && track!.size! >= 0;
}
