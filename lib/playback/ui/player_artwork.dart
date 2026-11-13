import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../shared/widgets/music_artwork.dart';
import '../models/playback_item.dart';

/// Retains the current artwork request across playback position updates.
class PlayerArtwork extends StatefulWidget {
  const PlayerArtwork({
    super.key,
    required this.item,
    required this.size,
    required this.loadArtwork,
    this.revision = 0,
  });
  final PlaybackItem item;
  final double size;
  final Future<Uint8List?> Function(PlaybackItem)? loadArtwork;
  final int revision;
  @override
  State<PlayerArtwork> createState() => _PlayerArtworkState();
}

class _PlayerArtworkState extends State<PlayerArtwork> {
  Future<Uint8List?>? _request;
  DateTime? _retryAfter;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlayerArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.item, widget.item) ||
        oldWidget.loadArtwork != widget.loadArtwork ||
        oldWidget.revision != widget.revision ||
        (_retryAfter != null && !DateTime.now().isBefore(_retryAfter!))) {
      _load();
    }
  }

  void _load() {
    _retryAfter = null;
    final load = widget.loadArtwork;
    if (load == null) {
      _request = null;
      return;
    }
    final item = widget.item;
    final request = Future<Uint8List?>.sync(() => load(item));
    _request = request;
    void failed() {
      if (mounted && identical(_request, request)) {
        _retryAfter = DateTime.now().add(const Duration(minutes: 1));
      }
    }

    request.then<void>((bytes) {
      if (bytes == null) {
        failed();
      }
    }, onError: (Object error, StackTrace stack) => failed());
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: MusicArtwork(
      title: widget.item.track.title,
      size: widget.size,
      artwork: _request,
    ),
  );
}
