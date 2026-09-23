# Kite App

Mac 和 iPhone 共用一个 SwiftUI 工程、一个多平台 target。

```
app/
├── Kite.xcodeproj
│   └── xcshareddata/xcschemes/Kite.xcscheme   共享 scheme，命令行和 Xcode 用同一个
└── Kite/                                      源码和资源
```

布局：Mac 上左边侧边栏、右边一组卡片，卡片的排布见 `Tiles.swift`；iPhone 上会话窗口铺满屏幕，侧边栏和 action 栏从边上拉出来，见 `PhoneLayout.swift`。尺寸和颜色集中在 `Theme.swift`。

## 约定

- 工程照 Xcode 自带的「多平台 App」模板的设置写成，不用 XcodeGen 这类生成工具。`Kite/` 是同步文件夹：在里面加、删、挪文件，工程自动跟上，不用改 `project.pbxproj`。
- 两端共用代码，差异用 `#if os(macOS)`、`#if os(iOS)` 分开。
- Swift 6 语言模式，数据竞争在编译时报错；模板默认是 5。默认隔离在主线程（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），和模板一致。
- 开发语言是简体中文（`zh-Hans`），界面文字直接写中文。
- 最低 macOS 26、iOS 26。只支持 iPhone，要 iPad 时把 `TARGETED_DEVICE_FAMILY` 改成 `1,2`。
- Mac 版开沙盒，允许对外连网（连 kited）、只读用户选中的文件，和模板一致。
- Bundle ID 是 `com.sainner.kite`。

## 编译和运行

`.kite/check` 在 `app/` 有改动时编译两端，出错时列出文件和行号。手动编译：

```bash
xcodebuild -project app/Kite.xcodeproj -scheme Kite -destination 'generic/platform=macOS' -destination 'generic/platform=iOS Simulator' build -quiet
```

运行用 Xcode 打开 `app/Kite.xcodeproj`，选 My Mac 或一台 iPhone 模拟器。

## 签名

本机 Xcode 还没有登录开发者账号：Mac 版是临时签名（ad-hoc），自己编译自己用没问题；iOS 只能跑模拟器。装到 iPhone、走 TestFlight、把 Mac 版给别人都要付费开发者账号，登录后在工程里设 `DEVELOPMENT_TEAM`。
