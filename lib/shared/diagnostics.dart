import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Opt-in device tracing. Call sites pass counts, enum values and opaque IDs.
class Diagnostics {
  static const enabled = bool.fromEnvironment('PIKMELO_DIAGNOSTICS');

  static String identifier(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 12);

  static void event(String name, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    debugPrintSynchronously(
      '[PikmeloTrace] ${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': name, ...fields})}',
    );
  }

  static void watchFrames() {
    if (!enabled) return;
    var count = 0, slow = 0, worstBuild = 0, worstRaster = 0;
    SchedulerBinding.instance.addTimingsCallback((frames) {
      for (final frame in frames) {
        count++;
        final build = frame.buildDuration.inMicroseconds;
        final raster = frame.rasterDuration.inMicroseconds;
        if (build > 16667 || raster > 16667) slow++;
        if (build > worstBuild) worstBuild = build;
        if (raster > worstRaster) worstRaster = raster;
      }
      if (count < 120) return;
      event('frames', {
        'count': count,
        'over16ms': slow,
        'worstBuildUs': worstBuild,
        'worstRasterUs': worstRaster,
      });
      count = slow = worstBuild = worstRaster = 0;
    });
  }
}
