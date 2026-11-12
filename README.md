# Pikmelo Player

基于 Flutter 的跨平台音乐播放器，首期目标为 Windows 和 Android。

界面采用深松绿与薄荷色 Material 3 主题。手机使用底部导航，Windows 使用侧栏与可收起队列，曲库支持本地搜索和已下载筛选。界面规格及实际截图见 [界面设计 V1](Docs/界面设计V1.md)。

## 当前实现

- 连接现有 Pikmelo Server 的 `/api/v2` REST API，使用 `X-API-Key`。
- 分页同步歌单和曲目，按服务器游标增量更新，并处理 reset 和 `SYNC_RESTART`。
- 使用本地 SQLite 事务提交整轮同步，安全保存 API Key。
- 下载媒体支持 HTTP Range/ETag 续传，并在下载完成后原子发布本地媒体文件。
- 下载管理支持串行队列、进度、暂停继续、取消重试和本地删除，重启或同步后的未完成任务恢复为暂停。
- 恢复上次选择的服务器与本地曲库，支持离线浏览歌单详情及曲目可用状态。
- 启动和回到前台时尝试同步，处理请求超时、429 重试、连接切换及凭据变化。
- 使用 media_kit 播放音频，支持未下载曲目播放前下载、歌单播放、下一首预下载和离线播放。
- 设置页可自定义音频目录，选择迁移已有音乐或仅影响新下载，Android 使用系统目录授权。
- 手动下载长期保留，播放缓存按容量回收，移动网络支持允许下载、仅播放前下载、禁止下载。
- 支持顺序、列表循环、单曲循环和随机模式，删除文件或授权变化时及时释放音源。
- 应用内封面优先读取已下载音频的内嵌图片，缺失时获取服务器封面，支持离线缓存与授权隔离。
- Android 支持前台媒体服务、后台与锁屏控制，以及音频焦点和耳机断开处理。
- Windows 支持系统媒体控制、媒体按键及进度定位，最小化继续播放，关闭窗口退出。
- 使用公开 GitHub Releases 检查版本，Android 按设备架构下载并验证正式签名，通过系统安装器完成更新。

键盘支持空格播放暂停、Ctrl+左方向键上一首、Ctrl+右方向键下一首。文本框保留输入行为。

## 模块结构

- `lib/app` 负责应用装配、主题和资源生命周期，`lib/main.dart` 提供启动入口。
- `lib/settings` 负责连接配置模型、连接控制器和表单。
- `lib/library` 负责曲目与歌单模型、本地曲库仓库及页面。
- `lib/sync` 与 `lib/downloads` 分别负责同步和媒体下载业务。
- `lib/playback` 负责共享播放控制、队列和播放器界面。
- `lib/artwork` 负责内嵌资源提取、封面来源选择和缓存，供曲库与播放器复用。
- `lib/updates` 负责 Releases 查询、版本比较、下载校验与更新状态，平台代码负责安装能力。
- `lib/infrastructure` 负责服务器协议、SQLite、系统凭据存储、原生音频后端及系统媒体适配。

详细阶段、任务清单和验证结果见 [整体开发计划](Docs/整体开发计划.md) 与 [自定义存储及按需播放](Docs/自定义存储与按需播放计划.md)。

## 运行

```powershell
flutter pub get
flutter run -d windows
flutter run -d <android-device-id>
```

在设置页的服务器连接中填写服务器 HTTPS 地址和播放器 API Key。Key 应在服务端网页中创建，并显式授权 `library:read`、`media:read` 和所需歌单。请勿将 Key 写入源码或提交到版本控制。

Android 工程使用本机 `D:\Android-SDK`，compileSdk 为 36，minSdk 为 24，targetSdk 为 35；Gradle 为 8.14.3。Windows CMake 配置已固定 ATL 根路径，使用 Visual Studio Professional 安装中的 ATL 头文件和库。

## 验证

正式安装包从 [GitHub Releases](https://github.com/ShenYunyao1/Pikmelo-Player/releases/latest) 下载，Android 按设备架构选择，Windows 解压 ZIP 后运行。Android 正式版固定项目专用签名，已有 debug 签名版本需先卸载再安装正式版。

本地发布构建通过 `PIKMELO_SIGNING_PROPERTIES` 指定工作区外的签名配置，然后执行 `flutter build apk --release --split-per-abi`。推送 `v版本号` 标签触发双平台构建，发布流程验证 Android 签名并生成 SHA-256 清单。操作与验收结果见 [自动更新与正式发布](Docs/自动更新与正式发布计划.md)，包体记录见 [Android 包体分析](Docs/Android包体分析.md)。

```powershell
flutter analyze
flutter test
flutter test integration_test/playback_smoke_test.dart -d windows
flutter test integration_test/playback_smoke_test.dart -d <android-device-id>
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
