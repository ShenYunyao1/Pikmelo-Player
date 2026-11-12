# Android 包体分析

记录日期为 2026-11-12。

## 排查与处理

- [x] 拆包核对架构、运行时、代码和音频解码库。
- [x] 核对 Flutter 官方体积说明与分架构构建方式。
- [x] 生成 release 优化构建，并按 CPU 架构拆分。
- [x] 核对实际体积、签名、架构与调试资源。
- [ ] 安装 release 构建并验证播放与系统控制。

之前的安装链接对应 `app-debug.apk`，大小为 231628250 字节，即 220.90 MiB，同时打包了 armeabi-v7a、arm64-v8a 和 x86_64 三套原生库。

按 APK 内条目的压缩后大小计算，Flutter 调试引擎三套合计约 106.92 MiB，Dart kernel 与 isolate 快照约 30.05 MiB，Vulkan 验证库约 14.53 MiB，三套 libmpv 解码库约 17.98 MiB。完整 APK 还包含其他条目与 ZIP 容器空间。

## 优化构建结果

使用以下命令生成对应架构的安装包。

```powershell
flutter build apk --release --split-per-abi
```

| 架构 | 文件 | 大小 |
|---|---|---|
| ARM64 | app-arm64-v8a-release.apk | 27631937 字节，26.35 MiB |
| ARM 32 位 | app-armeabi-v7a-release.apk | 24356701 字节，23.23 MiB |
| x86_64 | app-x86_64-release.apk | 29869683 字节，28.49 MiB |

文件均位于 `build/app/outputs/flutter-apk/`。ARM64 包比原多架构调试包缩小约 88.1%。

ARM64 包中的主要原生库为 Flutter 引擎约 11.22 MiB、AOT 应用代码约 6.00 MiB、libmpv 约 5.93 MiB、SQLite 约 1.67 MiB。每个 APK 仅包含对应架构，调试 kernel、isolate 快照和 Vulkan 验证库已移除。

ARM64 包通过 apksigner 校验，最低 Android API 为 24，targetSdk 为 35。当前 release 构建沿用工程已有的 Android Debug 测试签名，发布签名按交付阶段配置。

2026-11-12 接入自定义目录与按需播放后重新生成上述三个 release APK，均通过 apksigner 校验。x86_64 release 已在 Android 15 / API 35 模拟器安装并启动，设置页三种移动网络选项与禁止下载设置的进程重启恢复通过。播放与文档目录迁移已由 debug 原生集成用例验证，release 的完整播放及系统控制按 P6 继续验收。

[Flutter 官方体积分析](https://docs.flutter.dev/perf/app-size)、[Android 构建与架构拆分](https://docs.flutter.dev/deployment/android)
