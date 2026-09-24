# Kite App

Mac 和 iPhone 共用一个 SwiftUI 工程、一个多平台 target。

```
app/
├── Kite.xcodeproj
│   └── xcshareddata/xcschemes/Kite.xcscheme   共享 scheme，命令行和 Xcode 用同一个
└── Kite/                                      源码和资源
```

布局：一个会话就是一个窗口组（`Workspace`，在 `Tiles.swift`）：有哪些窗口、Mac 上怎么排、聚焦哪个。Mac 把它们排成卡片（`TileViews.swift`），按住卡片标题栏拖出去，它脱离布局变成跟着指针的圆，落到别的卡片上时用占位预览放下后的排布；iPhone 一次显示聚焦的那个，页签切换（`PhoneLayout.swift`）。Mac 主窗口左边是侧边栏（会话列表和底部的 action 区，拖右边的缝调宽度，拖到很窄收成一列图标，⌃⌘S 切换），会话从侧边栏拖到主窗口外面分离成独立窗口（`DetachedSession.swift`），关掉后回到主窗口。卡片和缝上不拖窗口，拖窗口交给侧边栏这些空白处（`MouseDragArea.swift`）。红绿灯按钮那一条多高、让出多宽，从 AppKit 的安全区读（`WindowChrome.swift`），不写死。尺寸和颜色集中在 `Theme.swift`。

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
