class UpdateArtifact {
  const UpdateArtifact({
    required this.abi,
    required this.name,
    required this.size,
    required this.sha256,
  });
  final String abi;
  final String name;
  final int size;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'platform': 'android',
    'abi': abi,
    'name': name,
    'size': size,
    'sha256': sha256,
  };
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.versionCode,
    required this.packageName,
    required this.signerSha256,
    required this.artifacts,
    required this.page,
    required this.downloadBase,
  });
  final String version;
  final int versionCode;
  final String packageName;
  final String signerSha256;
  final List<UpdateArtifact> artifacts;
  final Uri page;
  final Uri downloadBase;

  factory UpdateRelease.fromJson(
    Map<String, dynamic> json, {
    required Uri page,
    required Uri downloadBase,
  }) {
    final version = json['version'];
    final code = json['versionCode'];
    final package = json['packageName'];
    final certificate = json['signerSha256'];
    if (json['schema'] != 1 ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        code is! int ||
        code <= 0 ||
        code > 2100000000 ||
        package != 'top.shenyunyao.pikmelo_player' ||
        certificate is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(certificate) ||
        json['artifacts'] is! List) {
      throw const FormatException('更新清单格式无效。');
    }
    final artifacts = <UpdateArtifact>[];
    final abis = <String>{};
    for (final item in json['artifacts'] as List) {
      if (item is! Map || item['platform'] != 'android') continue;
      final abi = item['abi'];
      final name = item['name'];
      final size = item['size'];
      final hash = item['sha256'];
      if (abi is! String ||
          !{'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi) ||
          !abis.add(abi) ||
          name is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$').hasMatch(name) ||
          size is! int ||
          size <= 0 ||
          size > 256 * 1024 * 1024 ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('更新安装包信息无效。');
      }
      artifacts.add(
        UpdateArtifact(abi: abi, name: name, size: size, sha256: hash),
      );
    }
    if (artifacts.isEmpty) throw const FormatException('更新清单缺少安装包。');
    return UpdateRelease(
      version: version,
      versionCode: code,
      packageName: package as String,
      signerSha256: certificate,
      artifacts: List.unmodifiable(artifacts),
      page: page,
      downloadBase: downloadBase,
    );
  }

  UpdateArtifact select(List<String> supportedAbis) {
    for (final abi in supportedAbis) {
      final matches = artifacts.where((item) => item.abi == abi);
      if (matches.isNotEmpty) return matches.single;
    }
    throw const FormatException('该版本没有适合此设备架构的安装包。');
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'version': version,
    'versionCode': versionCode,
    'packageName': packageName,
    'signerSha256': signerSha256,
    'artifacts': artifacts.map((item) => item.toJson()).toList(),
  };
}
