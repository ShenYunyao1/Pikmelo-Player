import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../playback_controller.dart';

class VolumeButton extends StatelessWidget {
  const VolumeButton({super.key, required this.controller});
  final PlaybackController controller;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '音量',
    icon: Icon(
      controller.volume == 0
          ? Icons.volume_off_rounded
          : Icons.volume_up_rounded,
    ),
    onPressed: () {
      final box = context.findRenderObject()! as RenderBox;
      final anchor = box.localToGlobal(Offset.zero);
      showDialog<void>(
        context: context,
        useSafeArea: false,
        barrierColor: Colors.transparent,
        barrierLabel: '关闭音量',
        builder: (context) {
          final size = MediaQuery.sizeOf(context);
          final safe = MediaQuery.paddingOf(context);
          final height = math.min(260.0, size.height - safe.vertical - 16);
          final left = (anchor.dx - 24).clamp(
            8.0,
            math.max(8.0, size.width - 104),
          );
          final top = (anchor.dy - height - 8).clamp(
            safe.top + 8,
            math.max(safe.top + 8, size.height - safe.bottom - height - 8),
          );
          return Stack(
            children: [
              Positioned(
                left: left.toDouble(),
                top: top.toDouble(),
                width: 96,
                height: height,
                child: Material(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(20),
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 8,
                      ),
                      child: Column(
                        children: [
                          Text('${controller.volume.round()}%', maxLines: 1),
                          const SizedBox(height: 8),
                          Expanded(
                            child: RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                value: controller.volume,
                                max: 100,
                                onChanged: controller.setVolume,
                                semanticFormatterCallback: (value) =>
                                    '音量 ${value.round()}%',
                              ),
                            ),
                          ),
                          const Icon(Icons.volume_up_rounded, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
