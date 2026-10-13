# Kite App

Mac、iPhone 和 iPad 共用一个 SwiftUI 工程、一个多平台 target。使用 Swift 6，最低 macOS 26、iOS 26；工程语言为简体中文。

客户端职责、跨端状态与业务边界见 [App 设计原则](../docs/App.md)。

## 代码地图

`Kite/` 是 Xcode 同步文件夹，增删、移动源码会自动反映到工程。各端共用功能代码；布局与输入适配由界面组件处理，系统 API 差异使用条件编译。

| 目录 | 职责 |
|---|---|
| `Kite/Application/` | App 启动、连接、远端数据与应用状态；`AppModel.swift` 管理工作区目录 |
| `Kite/Workspace/` | 工作区状态、窗口、侧栏、布局和拖动；`WorkArea.swift` 保存单个工作区状态 |
| `Kite/Conversation/` | 线程状态、消息、输入区、工具展示和会话配置；`WorkThread.swift` 保存单个线程状态 |
| `Kite/Files/` | 文件浏览、内容预览与资源引用 |
| `Kite/Plugins/` | 插件管理、实例设置、插件窗口与原生 Web 桥 |
| `Kite/Context/` | 角色与上下文模板的模型、资源库页面与编辑器 |
| `Kite/UI/` | 主题、公共控件、点阵视觉语言、文本渲染与 Metal 动效 |
| `Kite/Resources/Generated/` | 生成的插件宿主页；源码在 `kited/web/plugin-host.ts` |
| `Kite.xcodeproj/` | 多平台工程、共享 scheme 与固定的 Swift Package 版本 |

侧栏入口在 `Workspace/Sidebar.swift`，列表、导航、页面和行组件分别在 `WorkspaceList.swift`、`SidebarNavigation.swift`、`SidebarPages.swift`、`SidebarRows.swift`。点阵的舞台状态、图形、帧计算与 SwiftUI 画布分别在 `UI/DotStage.swift`、`DotFigure.swift`、`DotField.swift`、`DotCanvas.swift`。

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

改界面时用 `app/scripts/preview-mac.sh` 快速预览：增量编译 Mac Debug 版，只退出本检出上次打开的预览，再另起一个实例打开新 build，主线和各工作树的预览可以同时开着；也可以在 Xcode 里直接运行 Debug。Debug 版不带 kited，直接连本机已安装的服务，不会重装或重启它，所以要先用 `./install.command` 装好一次。交付确认仍完整安装 Release。

`preview-mac.sh` 的参数原样传给 App。带 `--dock-preview` 打开停靠栏预览：用真实的停靠栏组件画各种窗口与活动状态下的头像，不建工作区、不发请求，头像签名取已连接工作机上的角色。

会话输入区有两版：Mac 宽屏是原生的 `MacControlsBar`，iPhone、iPad 和 Mac 窄窗口是 SwiftUI 的 `ThreadControls`。对照两版用下面几个启动参数，都只在 Debug 版生效，Release 版不认：

- `--swiftui-composer`：Mac 宽屏的会话窗口也用 SwiftUI 版输入区，同一个构建切新旧两版，对照行为或测量。原生台面上会话窗口的外框是原生的、只用原生输入区，这个开关要和 `--swiftui-stage` 一起用才起作用。
- `--composer-preview`：主窗口留空，另开一个窗口并排画两版输入区（左 SwiftUI、右原生），用一个不连工作机的草稿会话逐种状态切换，用来逐像素对照。再加 `--capture-port <端口>` 时依次把每种状态的窗口图和布局 POST 到本机这个端口，抓完退出；`--composer-no-glass` 两版都不画玻璃，`--composer-inactive` 抓 App 不在前台时的样子，深色加 `-KiteAppearance dark`。

宽屏台面（卡片、缝、拖动和窗口动画）也有两版：Mac 是原生的 `StageView`，iPad 是 SwiftUI 的 `SwiftUITilesLayer`。对照用：

- `--swiftui-stage`：Mac 也用 SwiftUI 版台面，同一个构建切新旧两版。
- `--stage-preview`：主窗口留空，另开一个窗口并排画两版台面（左 SwiftUI、右原生），各用一个造出来的工作区，按同样的步骤改排布（缩小、展开、空台面、恢复、拖动预览、展开停靠栏）。加 `--capture-port <端口>` 时每一步等动画走完、缩小和恢复途中再各抓几帧，窗口图和两格位置 POST 到本机这个端口，抓完退出；`-stageHover swiftui|native` 把窗口挪到指针底下，让指针停在那一边的卡片上，比悬停露出的窗口按钮；深色加 `-KiteAppearance dark`。每一步还在进程里问几处点落在哪个视图上（hitTest，不发事件）；最后在原生会话窗口里用模型的接口摆出操作栏、拖缝、引用跳转、发送，各抓一张并导出读屏树，再拆掉两边看原生台面有没有漏。

状态圆环和停靠栏头像的脉冲在 Mac 上是图层动画（`ContextRingLayers`、`DockPulseLayers`），iPhone、iPad 仍逐帧画 SwiftUI 版。`--ring-preview` 另开一个窗口，左边是 SwiftUI 版各阶段、各进度的那一帧，右边是图层版停在同一处，加 `--capture-port <端口>` 时抓图后退出。

初始配置预览使用 Debug build 带 `--onboarding-preview` 启动，需要从测试机桌面反复启动时，编译参数使用 `KITE_PREVIEW_FLAGS=KITE_ONBOARDING_PREVIEW`。界面在真实工作机和数据上迭代。

Swift 类型、窗口排布、草稿交接、滚动与 WebKit 验证统一在 [手动验证目录](../kited/test/manual/README.md)。移动或拆分 Swift 文件时同步更新这些脚本引用的源码路径。

真机耗时用 Debug 构建里的 `TimingTrace` 记录：每次回到前台开始一轮，记录首分钟内的账号核验、组网节点上线、对端路径变化、各请求与事件流耗时，并附带带时间的组网库日志。真机测完后取回：

```sh
xcrun devicectl device copy from --device <设备 ID> --domain-type appDataContainer \
  --domain-identifier com.sainner.kite --source Library/Caches/timing-trace.log --destination timing-trace.log
```

文件位于 App 的缓存目录，记录以追加方式写入；同一进程内轮次递增。需要保留的测量结果及时取回，不把缓存文件当作长期记录。

工程使用自动签名。本机配置有效开发团队并连接测试 iPhone 或 iPad 后，按设备 ID 构建，再用 Xcode 或 `devicectl device install app` 安装、`devicectl device process launch` 打开。签名身份以工程当前配置和本机证书为准，不在文档复制一份机器状态。

## 界面性能约定

宽对象只通过摘要属性暴露给宽视图。读整个 transcript、布局或模型的视图尽量小：窗口、标题栏和控制区只读 `WorkThread` 摘出的几项（如 `hasTranscript`），对话正文由 `ThreadTranscript` 单独读。

放进环境的闭包和对象建好就不再换。环境一变，SwiftUI 要把它推给子树里每个 UIKit 视图，对话里每段字都是一个 `UITextView`，真机上一次就是几十毫秒；`PaneRow` 的横滑动作、`DrawerMotion` 的 `openSidebar` 都这样处理。

逐帧变化的量只在叶子视图读，排版用的量不随动画进度变。窗口内容按停着的样子排一次，运动交给合成层变换（`WindowMotion`、`CompactWindow`）；读 `.frame(in: .global)` 或 `Text.LayoutKey` 的视图在几何效果移动容器时每帧重算。
