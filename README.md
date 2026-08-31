# MuseReader

MuseReader 是一个 Flutter Android/iOS 只读谱面阅读器。它支持从系统文件选择器打开 `MSCX` 和 `MSCZ`，查看分页谱面、缩放/平移，并按谱面时间线播放和高亮音符；产品界面没有编辑、保存或导出功能。

## 当前功能

- Flutter Material 3 阅读界面，适配手机竖屏、横屏和平板宽度。
- `MSCZ` 使用 `META-INF/container.xml` 查找根 `MSCX`；`MSCX` 直接解析 XML。
- 播放位置使用整数微秒和单调时钟，音符事件同时保留 tick 与 `startUs/endUs`，拖动进度条、变速和分页都基于同一时间线。
- Android 使用 NDK/JNI 壳，iOS 使用 Objective-C/Swift bridging header；两个平台都优先请求 MuseScore 原生引擎，缺少引擎时才回退到 Dart 兼容解析器和系统音频合成器。
- 附带 `assets/demo/reader-demo.mscx`，安装后可以直接验证阅读和播放流程。

## 精确渲染架构

要满足所有 MuseScore 3.6.2 记谱语义的完全一致显示，不能在 Flutter 中重新实现排版器。原生适配器位于 [native/musescore_engine/muse_reader_engine.cpp](native/musescore_engine/muse_reader_engine.cpp)，按附件源码中的核心路径工作：

1. `MasterScore::loadMsc()` 读取 `MSCX/MSCZ`。
2. `MasterScore::doLayout()` 生成 MuseScore 原生页面布局。
3. `Score::print()` 将每页绘制成 PNG，Flutter 只负责显示和缩放。
4. `Score::renderMidi(..., expandRepeats=true, ...)` 生成展开反复后的事件流。
5. `Score::utick2utime()` 计算包含速度变化和反复偏移的微秒时间。

原生 JSON 的页面图像、音符时间戳和 `Note::pageBoundingRect()` 页内矩形共享同一 `MasterScore`，因此谱面高亮不会再经过第二套 Flutter 几何推算。适配器的 C ABI、Android JNI 与 iOS 调用入口已经接入工程，见 [native/musescore_engine/README.md](native/musescore_engine/README.md)。

仓库当前默认构建不携带 Qt 和 MuseScore 静态库，所以默认 APK/iOS bundle 使用兼容模式；这个模式用于开发、演示和基础 MSCX/MSCZ 读取，不能宣称对复杂连音、反复、字体和所有布局细节完全等同 MuseScore。要发布“完全精准”版本，必须为每个 Android ABI 和 iOS 架构构建匹配的 Qt 运行库、MuseScore `libmscore` 以及 freetype、qzip、audio 等依赖，再启用 `MUSE_READER_WITH_MUSESCORE`。单独链接附件中的桌面 `libmscore.a` 不够。

## 开发与验证

在仓库根目录执行：

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d <device-id>
```

默认平台构建：

```sh
flutter build apk --debug
flutter build ios --no-codesign
```

精确发布包建议同时使用 `--dart-define=MUSE_READER_REQUIRE_NATIVE=true`；如果目标 ABI 没有正确打包 MuseScore 核心，应用会明确报错而不会静默显示兼容排版：

```sh
flutter build apk --release --dart-define=MUSE_READER_REQUIRE_NATIVE=true
flutter build ios --release --no-codesign --dart-define=MUSE_READER_REQUIRE_NATIVE=true
```

本机 Qt5 适配器编译验证（路径按实际工具链调整）：

```sh
cmake -S native/musescore_engine -B build/muse_reader_engine \
  -DMUSE_READER_WITH_MUSESCORE=ON \
  -DMUSESCORE_SOURCE_DIR=/Volumes/Files/Github/MuseScore-3.6.2 \
  -DMUSESCORE_BUILD_DIR=/path/to/musescore/build \
  -DMUSESCORE_LIBRARIES="/path/to/all/required/static/libraries"
cmake --build build/muse_reader_engine --config Release
```

Android 可以把同一组 CMake 参数通过 Gradle 属性传入：

```sh
ORG_GRADLE_PROJECT_museReaderWithMuseScore=true \
ORG_GRADLE_PROJECT_museScoreSourceDir=/path/to/MuseScore-3.6.2 \
ORG_GRADLE_PROJECT_museScoreBuildDir=/path/to/target/musescore/build \
ORG_GRADLE_PROJECT_museScoreLibraries='/path/to/liblibmscore.a;/path/to/other/dependency.a' \
ORG_GRADLE_PROJECT_museReaderQtPrefixPath=/path/to/target/qt \
flutter build apk --release --dart-define=MUSE_READER_REQUIRE_NATIVE=true
```

Android 的 JNI 目标会自动链接 `muse_reader_engine_core`；iOS 的 Runner target 已包含 C ABI 源文件。启用精确核心时，还需要在平台工程中提供目标平台 Qt framework/so、头文件、资源文件和完整静态库列表，具体依赖由 MuseScore/Qt 工具链决定，不能用桌面库路径替代。

## 源码说明

- [lib/main.dart](lib/main.dart)：应用入口和主题。
- [lib/src/services/score_parser.dart](lib/src/services/score_parser.dart)：MSCX/MSCZ 兼容解析器。
- [lib/src/model/score_document.dart](lib/src/model/score_document.dart)：谱面模型、tempo map 和微秒时间线。
- [lib/src/playback/playback_controller.dart](lib/src/playback/playback_controller.dart)：播放、拖动、变速和高亮状态。
- [lib/src/ui/reader_page.dart](lib/src/ui/reader_page.dart)：只读阅读页及响应式播放栏。
- [android/app/src/main/kotlin/com/musereader/muse_reader/MainActivity.kt](android/app/src/main/kotlin/com/musereader/muse_reader/MainActivity.kt)：Android 文件选择、JNI 通道和音频回退。
- [ios/Runner/AppDelegate.swift](ios/Runner/AppDelegate.swift)：iOS 文件选择、C ABI 通道和音频回退。

附件中的 `BUILDING.md`、`BUILD_COMMANDS.md` 属于 MuseScore 源码本身的编译参考，不是 MuseReader 的产品需求；本项目只采用其中与构建 `libmscore` 有关的技术信息，不引入编辑器功能。

## 许可证

MuseScore 3.6.2 代码采用 GPLv2。启用并分发原生核心时请同时遵守 [NOTICE-MUSESCORE.md](NOTICE-MUSESCORE.md) 及附件源码中的许可证和源代码提供义务。
