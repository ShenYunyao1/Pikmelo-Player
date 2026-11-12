import '../../library/models/track.dart';

enum DownloadStatus { queued, downloading, paused, completed, failed }

class DownloadTask {
  const DownloadTask({
    required this.track,
    required this.status,
    this.received = 0,
    this.error,
  });

  final Track track;
  final DownloadStatus status;
  final int received;
  final String? error;

  DownloadTask withState(
    DownloadStatus status, {
    int? received,
    String? error,
  }) => DownloadTask(
    track: track,
    status: status,
    received: received ?? this.received,
    error: error,
  );
}
