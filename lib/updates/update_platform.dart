import 'dart:io';

import 'package:flutter/services.dart';

import 'update_release.dart';

class UpdatePlatform {
  final channel = MethodChannel(
    Platform.isAndroid ? 'pikmelo/updates' : 'pikmelo/system_media',
  );
  Future<Map<String, dynamic>> info() async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>('updateInfo') ?? {},
  );
  Future<void> requestPermission() =>
      channel.invokeMethod('requestInstallPermission');
  Map<String, dynamic> arguments(
    String path,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) => {
    'path': path,
    'size': artifact.size,
    'sha256': artifact.sha256,
    'abi': artifact.abi,
    'version': release.version,
    'versionCode': release.versionCode,
  };
  Future<void> verify(
    String path,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) => channel.invokeMethod('verifyUpdate', arguments(path, release, artifact));
  Future<void> install(
    String path,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) =>
      channel.invokeMethod('installUpdate', arguments(path, release, artifact));
  Future<void> openRelease(Uri url) =>
      channel.invokeMethod('openRelease', {'url': url.toString()});
}
