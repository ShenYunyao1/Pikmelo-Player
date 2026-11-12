import 'dart:typed_data';

import 'package:flutter/material.dart';

class MusicArtwork extends StatelessWidget {
  const MusicArtwork({
    super.key,
    required this.title,
    this.size = 56,
    this.artwork,
  });
  final String title;
  final double size;
  final Future<Uint8List?>? artwork;

  @override
  Widget build(BuildContext context) {
    final seed = title.runes.fold(0, (value, rune) => value + rune);
    final colors = [
      const Color(0xFF315D50),
      const Color(0xFF345669),
      const Color(0xFF615448),
      const Color(0xFF4E4967),
    ];
    final placeholder = ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors[seed % colors.length], const Color(0xFF14221D)],
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          title.isEmpty ? '♫' : title.characters.first,
          style: TextStyle(
            fontSize: size * 0.38,
            fontWeight: FontWeight.w300,
            color: const Color(0xFFE2EEE7),
          ),
        ),
      ),
    );
    if (artwork == null) return placeholder;
    return FutureBuilder<Uint8List?>(
      future: artwork,
      builder: (context, snapshot) {
        final bytes = snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null;
        if (bytes == null) return placeholder;
        return ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(1, 1024),
              gaplessPlayback: false,
              errorBuilder: (_, _, _) => placeholder,
            ),
          ),
        );
      },
    );
  }
}
