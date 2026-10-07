# Kite App

Mac、iPhone 和 iPad 共用一个 SwiftUI 工程、一个多平台 target。使用 Swift 6，最低 macOS 26、iOS 26；工程语言为简体中文。

客户端职责、跨端状态与业务边界见 [App 设计原则](../docs/App.md)。

## 代码地图

`Kite/` 是 Xcode 同步文件夹，增删、移动源码会自动反映到工程。各功能共用代码；窗口空间决定布局，输入方式决定交互尺寸与操作入口，系统 API 差异保留条件编译。

| 目录 | 职责 |
|---|---|
| `Kite/Application/` | App 启动、连接、远端数据与应用状态；`AppModel.swift` 管理工作区目录 |
| `Kite/Workspace/` | 工作区状态、窗口、侧栏、布局和拖动；`WorkArea.swift` 保存单个工作区状态 |
| `Kite/Conversation/` | 线程状态、消息、输入区、工具展示和会话配置；`WorkThread.swift` 保存单个线程状态 |
| `Kite/Files/` | 文件浏览、内容预览与资源引用 |
| `Kite/Plugins/` | 插件管理、实例设置、插件窗口与原生 Web 桥 |
| `Kite/Context/` | 上下文模板模型、目录与编辑器 |
| `Kite/UI/` | 主题、公共控件、点阵视觉语言、文本渲染与 Metal 动效 |
| `Kite/Resources/Generated/` | 生成的插件宿主页；源码在 `kited/web/plugin-host.ts` |
| `Kite.xcodeproj/` | 多平台工程、共享 scheme 与固定的 Swift Package 版本 |

## 编译和运行

仓库根目录运行 `./package-mac.command` 生成 Mac Release App 与独立安装包，`./install.command` 构建后安装 App，首次配置选择本机执行时安装后台服务。签名范围、系统要求和升级方式见 [macOS 安装与打包](../docs/macOS安装与打包.md)。

用 Xcode 打开 `app/Kite.xcodeproj`，选择 My Mac、iPhone 或 iPad 模拟器。首次使用 Xcode 时，若缺少 Metal Toolchain，先运行 `xcodebuild -downloadComponent MetalToolchain`。

仓库根目录的 `.kite/check` 会在 App 有改动时先重建插件宿主页，再编译两端。手动编译时也先生成资源：

```bash
cd kited
node_modules/.bin/bun run build:plugin-web
cd ..
xcodebuild -project app/Kite.xcodeproj -scheme Kite -destination 'generic/platform=macOS' -destination 'generic/platform=iOS Simulator' build -quiet
```

App 内嵌组网节点用的 `Vendor/TailscaleKit.xcframework` 不入库，由 `app/scripts/build-tailscalekit.sh` 从固定版本的 libtailscale 构建，需要 Go；`.kite/check` 和打包在缺少时自动构建。Mac 端只编 arm64。

生成的 `PluginHost.html` 随仓库提交，直接打开 Xcode 也能取得该资源。修改宿主页应编辑 `kited/web/plugin-host.ts` 后重新构建。

## 预览和验证

初始配置预览使用 Debug build 带 `--onboarding-preview` 启动，需要从测试机桌面反复启动时，编译参数使用 `KITE_PREVIEW_FLAGS=KITE_ONBOARDING_PREVIEW`。界面在真实工作机和数据上迭代。

Swift 类型、窗口排布、草稿交接、滚动与 WebKit 验证统一在 [手动验证目录](../kited/test/manual/README.md)。移动或拆分 Swift 文件时同步更新这些脚本引用的源码路径。

真机耗时用 Debug 构建里的 `TimingTrace` 记录：每次回到前台开始一轮，记下账号核验、组网节点上线、对端路径变化、各请求与事件流的耗时，并附带带时间的组网库日志。真机测完后取回：

```sh
xcrun devicectl device copy from --device <设备 ID> --domain-type appDataContainer \
  --domain-identifier com.sainner.kite --source Library/Caches/timing-trace.log --destination timing-trace.log
```

文件只追加，重装 App 不清空；同一进程内轮次递增，出现新的「第 1 轮」表示进程重新启动过。

工程使用自动签名。本机配置有效开发团队并连接测试 iPhone 或 iPad 后，按设备 ID 构建，再用 Xcode 或 `devicectl device install app` 安装、`devicectl device process launch` 打开。签名身份以工程当前配置和本机证书为准，不在文档复制一份机器状态。
