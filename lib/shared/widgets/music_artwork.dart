import 'package:flutter/material.dart';

class MusicArtwork extends StatelessWidget {
  const MusicArtwork({super.key, required this.title, this.size = 56});
  final String title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final seed = title.runes.fold(0, (value, rune) => value + rune);
    final colors = [
      const Color(0xFF315D50),
      const Color(0xFF345669),
      const Color(0xFF615448),
      const Color(0xFF4E4967),
    ];
    return ExcludeSemantics(
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
  }
}
