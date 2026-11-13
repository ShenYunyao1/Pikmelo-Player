import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/media_storage_controller.dart';
import 'github_update_service.dart';
import 'update_platform.dart';
import 'update_release.dart';

enum UpdatePhase {
  idle,
  checking,
  available,
  downloading,
  verifying,
  permission,
  installing,
  confirmation,
  installed,
  failed,
}

enum MobileUpdatePolicy { wifiOnly, allow }

class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  UpdateController({GitHubUpdateService? service, UpdatePlatform? platform})
    : service = service ?? GitHubUpdateService(),
      platform = platform ?? UpdatePlatform();
  final GitHubUpdateService service;
  final UpdatePlatform platform;
  MediaStorageController? _storage;
  Future<void>? _initialization;
  Future<void>? _work;
  Future<void>? _shutdown;
  Map<String, dynamic> _info = {};
  UpdateRelease? release;
  UpdatePhase phase = UpdatePhase.idle;
  String? message;
  bool automatic = true;
  MobileUpdatePolicy mobilePolicy = MobileUpdatePolicy.wifiOnly;
  int received = 0;
  int total = 0;
  int _revision = 0;
  bool _closed = false;
  bool _observing = false;
  bool _resuming = false;
  bool _automaticDownload = false;
  Timer? _timer;

  String get currentVersion => _info['version'] as String? ?? '读取中';
  int get currentCode => (_info['versionCode'] as num?)?.toInt() ?? 0;
  bool get android => _info['platform'] == 'android';
  bool get initialized => _info.isNotEmpty;
  bool get busy => {
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.verifying,
    UpdatePhase.installing,
  }.contains(phase);
  List<String> get abis =>
      List<String>.from(_info['abis'] as List? ?? const []);

  Future<void> initialize(MediaStorageController storage) {
    if (_closed) return Future.value();
    if (_initialization != null) return _initialization!;
    _storage = storage;
    storage.addListener(_networkChanged);
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
    return _initialization = _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _storage!.ready;
      if (_closed) return;
      automatic = _storage!.store.setting('automatic_updates') != 'false';
      final store = _storage!.store;
      final policy = store.setting('mobile_update_policy');
      mobilePolicy =
          policy == MobileUpdatePolicy.allow.name ||
              (policy == null &&
                  store.setting('mobile_download_policy') ==
                      MobileDownloadPolicy.allow.name)
          ? MobileUpdatePolicy.allow
          : MobileUpdatePolicy.wifiOnly;
      store.saveSetting('mobile_update_policy', mobilePolicy.name);
      _info = await platform.info();
      service.proxy = _info['proxy'] as String?;
      if (_closed) return;
      final pending = _storage!.store.setting('pending_app_update');
      if (pending != null && pending.isNotEmpty) {
        try {
          final value = jsonDecode(pending) as Map<String, dynamic>;
          final restored = UpdateRelease.fromJson(
            value['manifest'] as Map<String, dynamic>,
            page: Uri.parse(value['page'] as String),
            downloadBase: Uri.parse(value['downloadBase'] as String),
          );
          if (restored.versionCode > currentCode) {
            release = restored;
            phase = UpdatePhase.available;
          } else {
            _storage!.store.saveSetting('pending_app_update', '');
          }
        } on FormatException {
          _storage!.store.saveSetting('pending_app_update', '');
        }
      }
      _applyInstallStatus();
      _notify();
      if (phase == UpdatePhase.confirmation ||
          phase == UpdatePhase.installing) {
        _poll();
      } else {
        await check(automaticCheck: true);
      }
    } catch (error) {
      _failure(error);
    }
  }

  void setMobilePolicy(MobileUpdatePolicy value) {
    if (_closed || !initialized || mobilePolicy == value) return;
    mobilePolicy = value;
    _storage!.store.saveSetting('mobile_update_policy', value.name);
    _networkChanged();
    _notify();
  }

  bool get _networkAllowed {
    final storage = _storage;
    return storage != null &&
        storage.networkKnown &&
        storage.connected &&
        (!storage.cellular || mobilePolicy == MobileUpdatePolicy.allow);
  }

  void setAutomatic(bool value) {
    automatic = value;
    _storage?.store.saveSetting('automatic_updates', value.toString());
    if (!value && _automaticDownload) cancel();
    _notify();
  }

  Future<void> check({bool automaticCheck = false}) {
    if (_closed || !initialized || _work != null) return Future.value();
    return _run(() async {
      phase = UpdatePhase.checking;
      message = null;
      _notify();
      try {
        final latest = await service.latest();
        if (_closed) return;
        if (latest != null && latest.versionCode > currentCode) {
          release = latest;
          phase = UpdatePhase.available;
          if (android && latest.signerSha256 != _info['signerSha256']) {
            throw const FormatException('当前为开发签名版本，请先安装正式签名版本。');
          }
          _notify();
          final attempted =
              int.tryParse(
                _storage!.store.setting('last_update_attempt') ?? '',
              ) ??
              0;
          if (automaticCheck &&
              automatic &&
              android &&
              latest.versionCode > attempted &&
              await _allowed()) {
            await _downloadAndInstall(automaticRequest: true);
          }
        } else {
          phase = UpdatePhase.idle;
          message = latest == null ? '尚无正式发布版本' : '已是最新版本';
        }
      } catch (error) {
        _failure(error);
      }
      _notify();
    });
  }

  Future<void> downloadAndInstall() {
    if (_closed || _work != null || release == null) return Future.value();
    return _run(() => _downloadAndInstall(automaticRequest: false));
  }

  Future<void> _downloadAndInstall({required bool automaticRequest}) async {
    final version = ++_revision;
    final update = release!;
    _automaticDownload = automaticRequest;
    try {
      if (!android) {
        await platform.openRelease(update.page);
        return;
      }
      final artifact = update.select(abis);
      final directory = Directory(_info['directory'] as String);
      phase = UpdatePhase.verifying;
      _notify();
      final cached = await service.cached(artifact, directory);
      if (cached == null && !await _allowed()) {
        throw const FormatException('当前网络策略禁止下载更新，请连接 Wi-Fi 或调整移动网络策略。');
      }
      if (!_current(version)) return;
      phase = cached == null ? UpdatePhase.downloading : UpdatePhase.verifying;
      received = cached == null ? 0 : artifact.size;
      total = artifact.size;
      message = null;
      _notify();
      var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
      final file =
          cached ??
          await service.download(
            update,
            artifact,
            directory,
            onProgress: (bytes) {
              received = bytes;
              if (DateTime.now().difference(lastProgress).inMilliseconds >=
                      200 ||
                  received == total) {
                lastProgress = DateTime.now();
                _notify();
              }
            },
          );
      if (!_current(version)) return;
      phase = UpdatePhase.verifying;
      _notify();
      await platform.verify(file.path, update, artifact);
      if (!_current(version)) return;
      _storage!.store.saveSetting(
        'pending_app_update',
        jsonEncode({
          'manifest': update.toJson(),
          'page': update.page.toString(),
          'downloadBase': update.downloadBase.toString(),
        }),
      );
      _info = await platform.info();
      if (!_current(version)) return;
      if (_info['canInstall'] != true) {
        phase = UpdatePhase.permission;
        message = '请在系统设置中允许 Pikmelo Player 安装更新';
        _notify();
        await platform.requestPermission();
        return;
      }
      phase = UpdatePhase.installing;
      message = '正在提交系统安装，系统可能请求确认';
      _storage!.store.saveSetting(
        'last_update_attempt',
        update.versionCode.toString(),
      );
      _notify();
      await platform.install(file.path, update, artifact);
      if (_current(version)) _poll();
    } catch (error) {
      if (_current(version)) _failure(error);
    } finally {
      _automaticDownload = false;
      _notify();
    }
  }

  Future<bool> _allowed() async {
    final storage = _storage!;
    await storage.refreshNetwork();
    return _networkAllowed;
  }

  void _networkChanged() {
    if (!_closed && phase == UpdatePhase.downloading && !_networkAllowed) {
      cancel();
    }
  }

  void cancel() {
    _revision++;
    service.cancel();
    phase = release == null ? UpdatePhase.idle : UpdatePhase.available;
    message = '更新下载已取消，可稍后重试';
    _notify();
  }

  Future<void> _run(Future<void> Function() operation) {
    final work = operation();
    _work = work;
    work.whenComplete(() {
      if (identical(_work, work)) _work = null;
    });
    return work;
  }

  void _applyInstallStatus() {
    switch (_info['installStatus']) {
      case 'installed':
        phase = UpdatePhase.installed;
        message = '更新安装完成';
        if (release != null && release!.versionCode <= currentCode) {
          release = null;
        }
      case 'installing':
        phase = UpdatePhase.installing;
        message = '系统正在安装更新';
      case 'confirmation':
        phase = UpdatePhase.confirmation;
        message = '请在系统界面确认安装';
      case 'failed':
        phase = UpdatePhase.failed;
        message = _info['installMessage'] as String? ?? '安装失败，请重试';
    }
  }

  void _poll() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_resume()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_resume());
  }

  Future<void> _resume() async {
    if (_closed || _resuming || _work != null || !initialized) return;
    _resuming = true;
    try {
      _info = await platform.info();
      if (_closed) return;
      if (phase == UpdatePhase.permission && _info['canInstall'] == true) {
        await downloadAndInstall();
      } else if ({
        UpdatePhase.installing,
        UpdatePhase.confirmation,
      }.contains(phase)) {
        _applyInstallStatus();
        if (phase == UpdatePhase.installed || phase == UpdatePhase.failed) {
          _timer?.cancel();
        }
        _notify();
      }
    } catch (error) {
      _failure(error);
      _timer?.cancel();
    } finally {
      _resuming = false;
    }
  }

  bool _current(int revision) => !_closed && revision == _revision;
  void _failure(Object error) {
    if (_closed) return;
    phase = UpdatePhase.failed;
    message = switch (error) {
      PlatformException() => error.message ?? '系统更新操作失败',
      FormatException() => error.message,
      UpdateCancelled() => '更新下载已取消',
      _ => '更新操作失败，请检查网络、GitHub 访问和存储空间后重试',
    };
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> shutdown() => _shutdown ??= _close();
  Future<void> _close() async {
    _closed = true;
    _revision++;
    _timer?.cancel();
    _storage?.removeListener(_networkChanged);
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    service.dispose();
    await _work;
    await _initialization;
    super.dispose();
  }
}
