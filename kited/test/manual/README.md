# 手动验证

这些验证需要真实组网服务、Swift 编译器、原生界面、WKWebView 或模型订阅，不计入 `small` / `medium` 的数量与耗时预算；其中哪些由 `.kite/check` 自动运行见 `kited/scripts/check.ts`。以下命令从仓库根目录运行；原生界面与 Swift 验证需要 macOS 和 Xcode 开发工具。

## 运行时验证

先按 [工作机开发入口](../../README.md#启动服务) 安装依赖，再在仓库根目录选择项目固定的 Bun：

```bash
export PATH="$PWD/kited/node_modules/.bin:$PATH"
```

| 入口 | 验证内容 | 命令 |
| --- | --- | --- |
| `verify-directory-app.ts` | 真实 DEBUG AppModel 的两机目录汇总、离线隔离、按工作区操作、旧响应丢弃及目录摘要保留布局；仅手动运行 | `bun kited/test/manual/verify-directory-app.ts --app /path/Kite.app` |
| `verify-plugin-management.ts` | Swift 配置编辑与真实后端往返、授权和版本冲突 | `bun kited/test/manual/verify-plugin-management.ts` |
| `verify-remote-workspace-swift.ts` | 真实后端工作区与跨工作机项目身份的 Swift 解码、目录同步 | `bun kited/test/manual/verify-remote-workspace-swift.ts` |
| `verify-resource-reference-swift.ts` | 文件、diff 和网页引用经过 Markdown 与编码转换后仍正确 | `bun kited/test/manual/verify-resource-reference-swift.ts` |
| `verify-dot-canvas-swift.ts` | 真实 DotField 浮动、闪烁与空白帧交接的颜色连续性 | `bun kited/test/manual/verify-dot-canvas-swift.ts` |
| `verify-dot-background-swift.ts` | 真实 SwiftUI preference 在窗口点阵启用、停用与移除时的自动占用交接 | `bun kited/test/manual/verify-dot-background-swift.ts` |
| `verify-compact-pane-stack-swift.ts` | Mac 窄窗口紧凑布局（SwiftUI 的 CompactPaneStack）一行窗口横滑松手后的焦点切换与原生按钮命中、保活窗口的环境动作、外壳控制区接回源环境后的 keyboardShown、PanePresence 随停稳翻转；横滑状态 PaneRow 与 iOS 的原生一行窗口共用；仅手动运行 | `bun kited/test/manual/verify-compact-pane-stack-swift.ts` |
| `verify-card-sheet-sizing-swift.ts` | 同一次真实 SwiftUI sheet 随生产 CardSheet 内容增减长高、缩短；只读取窗口尺寸，仅手动运行 | `bun kited/test/manual/verify-card-sheet-sizing-swift.ts` |
| `verify-transcript-swift.ts` | 显示投影 JSON 的 Swift 解码、思考和工具结果关联 | `bun kited/test/manual/verify-transcript-swift.ts` |
| `verify-window-dock.ts` | 窗口拖动、停靠、宽窄视口切换、临时收起与状态恢复；内容区窄时拖到外缘把离这条边远的窗口腾进停靠栏，放不下两张时这条边不算落点；拖缝与侧栏改宽只改相邻窗口、挤到最小尺寸后同次拖回复原、松手不吸附与比例持久化。`AudioLevel`、`PaneTimeline` 由夹具给最小定义 | `bun kited/test/manual/verify-window-dock.ts` |
| `verify-dock-hover-label-swift.ts` | 生产 source/host 将短/长中文停靠提示绘到内容矩形 mask 外；36/16 点图标旁保持自然大小与垂直居中，底边提示进入窗口留白，nil source 移除提示；一个关闭动画的离屏场景，不测 hover 时序，仅手动运行 | `bun kited/test/manual/verify-dock-hover-label-swift.ts` |
| `verify-mac-selectable-text-swift.ts` | Mac 生产 NSTextView（TextKit 2，ProseTextView）的跨段选区与 Markdown 原文复制、行内代码像素、按宽度量高、流式追加、链接、真实滚动裁切视口，以及原生代码卡片附件屏外改宽后滚入时的尺寸、展开/横滑状态和跨附件选区；七个离屏场景，仅手动运行 | `bun kited/test/manual/verify-mac-selectable-text-swift.ts` |
| `verify-represented-root-swift.ts` | 生产 `RepresentedRoot` 截住里面托管视图（岛）的约束失效：屏上小窗口里岛的 `TimelineView(.animation)` 按帧走，外面 representable 所在的 SwiftUI 根不再每帧整轮重排；对照换成普通 `NSView`，外面每帧重排；同一个 `RepresentedRoot` 里的普通子视图逐帧标排版，`layout()` 仍按帧被调。挡系统改了约束上报的路径后外面又每帧重排（性能退回）或岛停住不动；仅手动运行 | `bun kited/test/manual/verify-represented-root-swift.ts` |
| `verify-plugin-web.ts` | 真实 WKWebView 与 MCP Apps SDK 的隔离和生命周期 | `bun kited/test/manual/verify-plugin-web.ts`；iOS 加 `--ios <模拟器 UDID>` |

`PluginWebProbe.swift` 是 `verify-plugin-web.ts` 编译和启动的原生探针，不单独运行。其余 Swift 文件是同名验证使用的夹具；`command.ts` 提供共用子进程执行入口。

`verify-compact-pane-stack-swift.ts` 把生产的 `CompactPaneStack.swift`（Mac 窄窗口的紧凑布局）连同 `WindowMotion.swift`、`HostedContent.swift`、`CompactPaneHeader.swift`、`PaneControlSwipe.swift` 一起编译，`Pane`、`WindowLayout`、`DrawerMotion`、`PanePresence` 等由夹具给最小定义；两页模型放在离屏 `NSHostingView` 里，外面按 `CompactWindow` 的接法套 `CompactPaneHeaderHost`。一个场景顺序验证：直接调环境里 `paneSwipe` 的 `track`、`end` 横滑松手后焦点换到相邻窗口，`WindowMotion` 停稳后新窗口的原生 `NSButton` 从宿主可命中、换走的窗口平移到宿主之外；相邻窗口建出时拿到的 `paneSwipe` 在它成为当前窗口后仍能横滑切回；外壳控制区整份接回源窗口环境后仍读到外壳写入的 `keyboardShown`，并能用源环境里的 `paneSwipe` 横滑切换；`PanePresence` 拖动中对露出来的相邻窗口为在屏，停稳后换走的窗口翻成不在屏。不发真实手势、不验证点阵与抽屉、不截图、不打开或操作用户 App；脚本可接受 `CompactPaneStack.swift` 的路径作为第一个参数，用于编译保留的回归快照。

`verify-mac-selectable-text-swift.ts` 把生产的 `MacProseTextView.swift`（`ProseTextView`、`ProseRowCoordinator`）、`SelectableMarkdown.swift` 与它们遵循、继承的 `TextKitMeasuring.swift`、`ProseTextCoordinator.swift`、`TextKitDecorations.swift`、`PlatformText.swift`、`BlockAttachment.swift` 与 Mac 原生卡片 `MacBlockCards.swift`、`MacTextControls.swift`、`NativeButton.swift`、`ModelTracking.swift` 连同 `Theme.swift`、`Markdown.swift`、`MarkdownTable.swift`、`Dots.swift`、`BlockCard.swift`、`InlineCode.swift`、`ReferenceViews.swift` 等一起编进 .app 包，颜色资源用 actool 编成 Assets.car；提示条、宿主模型、语法高亮（`CodeHighlighter` 原样返回）、读屏文案（`TranscriptSpeech` 的两句）与 SwiftUI 版卡片的按钮样式由夹具给最小定义；原生代码卡片、折叠和横向滚动使用生产实现。文本视图按原生对话行和表格卡片的配法（`ProseTextView.makeReadOnly`、`ProseRowCoordinator`）放进夹具里的一个表示视图（`MarkdownProse`），摆在离屏 `NSWindow` 的 `NSHostingView` 里，按 `TextKitMeasuring.measure` 量高。前五个场景顺序验证：`setSelectedRange` 跨段落、标题、引用后经 `writeSelection` 复制出保留段间空行和 Markdown 标记的原文（写到单独命名的 pasteboard，不碰用户剪贴板），合成鼠标拖选跨过标题；深度 1 到 3 的列表项和段落里，行内代码的背景像素连成一块包住字形、颜色是 `Theme.codeBackground` 叠在白底上（挡 3aac1c4 修的制表位画偏）；360→240→360 三种宽度下 frame 高等于 TextKit 排出来的高、末行不越界、改回同宽同高；流式追加时 `textStorage` 仍是同一对象、`didProcessEditing` 的编辑范围只在旧串末尾、前面的选区不动、高度跟着长；左键从 `contentView` 命中文本视图后点网页链接和文件引用各到 `openURL` 一次，点普通文字不触发。离屏无边框窗口不激活 App 成不了 key，鼠标事件按 `NSWindow` 的命中结果直接交给文本视图，拖动与松开预先放进事件队列；不验证右键与操作栏、上浮动画、深色外观和滚轮穿透。第一个参数可指定一份 `app/Kite` 的副本目录，用于编译保留的回归快照或判别力核验。另外两个滚动场景分别验证：AppKit 基类 visibleRect 非空但与正文 bounds 不相交时产品报告空视口，部分露出时保留整段视口（不裁视口的配法，表格卡片用），长段滚走再返回的行几何、绘制和选区不变；附件容器里的原生代码卡片（`CodeCardView`）展开、在卡片里真实的 `NSScrollView` 横滑到 160 pt 后，完全屏外改宽仍更新 TextKit 占位、保留同一卡片对象并隐藏，真实 clip bounds 通知使仅露出 80 pt 的附件在首帧对齐卡片尺寸、显示并绘出内容，回原宽保持展开、横滑、原生身份及跨附件 Markdown 复制。离屏窗口成不了 key，展开调卡片里「显示全部 N 行」那个 `TextButton` 的 `accessibilityPerformPress()`，不合成鼠标事件，再以 TextKit 高度增加和该按钮隐藏确认状态；不重写折叠逻辑，不设置卡片固定高度。附件场景不验证语法高亮、卡片按钮的悬停按下与倾斜、表格卡片、读屏树或实际鼠标输入路径，不测 CPU 或真实滚轮手势。不验证原生对话列表（`TranscriptListView`）的按需建行、视口裁切（`clipsViewport`）和拖缝时的近似量高。

`verify-represented-root-swift.ts` 把生产的 `RepresentedRoot.swift` 和夹具一起编译：窗口根是在 `placeSubviews` 里计数的自定义 `Layout`，里面一个 `NSViewRepresentable`（`sizeThatFits` 返回给的大小），它的视图是 `RepresentedRoot` 的子类，岛是 `NSHostingView`，设置同生产的 `StageIsland`（`sizingOptions`、`safeAreaRegions` 为空），在 `TimelineView` 的内容闭包里计数。每个场景开一个 320×200 的浮动无边框测试窗口，等 1 秒稳定后记 2 秒，按每秒 40 帧放宽阈值。夹具必须在 `NSApp.run` 的事件循环里跑：自己用 `RunLoop.main.run(mode:before:)` 转时，对照场景里外面的根每帧重排四五百次，和 App 里每帧一次对不上。需要已解锁的图形会话，测试窗口不在屏上或没有 display link 时明确失败，不跳过。第一个参数可指定一份 `RepresentedRoot.swift` 快照做判别力核验：把被拦的方法改名（不截）时第一个场景外面每帧重排，去掉排版里自己更新约束那一步（截了不补）时岛停住。不读屏幕像素，不验证点击、读屏和真实台面里的岛。

`verify-card-sheet-sizing-swift.ts` 使用真实 SwiftUI sheet 验证共享弹窗随内容增减调整高度、超长内容受屏幕可用范围限制，且始终使用同一窗口。测试窗口透明且不接收鼠标，只读取窗口尺寸；不涵盖登录服务、实际滚动手势或视觉验收。第一个参数可指定包含完整控件定义的 `CardControls.swift` 快照，此时替代生产控件文件参与编译。

`verify-directory-app.ts` 接收已经编译的 macOS DEBUG App 包或可执行文件，不自行编译。它在临时目录启动两个真实 kited，经本机代理控制 SSE 断线与 HTTP 响应交接，在原生进程运行真实 `AppModel`；子进程期限 35 秒。登录与托管目录是隔离夹具，不连接公网账号或 Tailnet、不使用 Keychain。这验证 `clearAccountConnections()` 后的旧响应丢弃，不证明真实撤销会自动触发原生 App 收口，也不涵盖 iPhone 界面验收。

## 性能测量

改完界面后，在真实 App、真实工作区里重跑一组固定场景，量每帧主线程和帧间隔，和之前的结果或另一份代码对比。App 里的那一半是 `app/Kite/Verification/PerfProbe.swift`（Mac 的部分在 `PerfProbe+Mac.swift`，iPhone 的在 `PerfProbe+Phone.swift`），只编进测量版（`KITE_PREVIEW_FLAGS=KITE_LAYOUT_AUDIT`），Release 和普通 Debug 都没有。`measure-perf.ts` 编测量版（`-O`，单独的 `build/perf-mac`、`build/perf-ios`，不搅日常的增量缓存）、启动、收结果、出表；分析在 `perf-analysis.ts`。

```bash
bun kited/test/manual/measure-perf.ts mac drag-work sidebar idle-empty --lock <锁文件>
bun kited/test/manual/measure-perf.ts mac drag-work --repeat 3 --variant 'top=-perfScrollTop 0' --trace
bun kited/test/manual/measure-perf.ts mac drag-work --base ../Kite-base --repeat 3
bun kited/test/manual/measure-perf.ts mac drag-work --compare build/perf/mac-20261014-022706
bun kited/test/manual/measure-perf.ts ipad --device <设备 ID> drag-bottom sidebar
bun kited/test/manual/measure-perf.ts iphone --device <设备 ID> drawer swipe keyboard
```

测量版带 `-perfScene <场景>` 启动，等 `-perfAutoStart` 秒（脚本给 8），摆好台面、等会话的历史读完，自己做完场景；也可以在 Xcode 里给这些启动参数手动跑。拖缝和侧栏每一轮 90 步、每帧一步，Mac 默认两轮、iPad 三轮。

| 场景 | 平台 | 做什么 | 表里看什么 |
| --- | --- | --- | --- |
| `drag-bottom` | Mac、iPad | 左右分栏的缝从可拖范围正中按正弦来回摆一趟，两个窗口都窄于对话最大宽度，正文每步都重排；对话停在底部 | 每步主线程（整轮除以步数）、每帧主线程 p90、帧间隔中位和 p90、超过 20ms 的步数、松手后 1.2 秒的主线程 |
| `drag-work` | Mac | 同上，最后一个工具行滚到顶上 | 同上 |
| `drag-long` | Mac | 同上，嵌卡片（代码、表格）最多的那段回复滚到顶上 | 同上 |
| `drag-fold` | Mac | 同上，本地造一次压缩、展开摘要和原文，滚到分界 | 同上 |
| `drag-running` | Mac | 同上，加一个在跑的工具调用、会话改成在跑，停在底部 | 同上 |
| `drag-actions` | Mac | 同上，工具行那一段，可见区上半截开着操作栏 | 同上 |
| `sidebar` | Mac、iPad | 对话停在底部，经模型逐帧改侧栏宽度（同拖侧栏的边），在可拖范围正中按正弦来回摆；台面贴着侧栏的那一列跟着改宽 | 同拖缝，另有「改了宽的步数」确认台面真的跟着变 |
| `motion` | Mac、iPad | 台面上最后一个窗口缩小、恢复，各 4 次 | 动作到第一帧、这之间的主线程、到动画走完的主线程、丢帧、最长一帧 |
| `drawer` | iPhone | 紧凑布局开着窗口，经抽屉模型（同点按钮）拉开、收起侧栏各 4 次，再拉开、收起底栏各 4 次；每次记 0.8 秒 | 同 `motion` |
| `pull` | iPhone | 手指拉侧栏：经拉手的处理每帧挪一截，0.2 秒拖到侧栏宽的 6 成后按这个速度甩开，再往回拖甩回，各 4 次；每次记 1 秒 | 同 `motion` |
| `swipe` | iPhone | 控制区横滑：经一行窗口的横滑处理 0.2 秒滑过 0.45 屏宽后松手，换到相邻窗口再滑回来，各 4 次；开测前等一行窗口都预热好 | 同 `motion` |
| `keyboard` | iPhone | 当前窗口的输入框接焦点、放焦点，键盘升降各 4 次；每次记 1 秒 | 同 `motion` |
| `idle-normal`、`idle-empty`、`idle-ring`、`idle-pulse`、`idle-sweep` | Mac | 什么也不改、全部缩小只剩空画板、标题栏圆环转着、停靠栏头像脉冲、对话里有个工具调用在跑（扫掠）；稳 3 秒后记 10 秒 | 主线程、整个进程的 CPU 占用 |
| `type` | Mac | 最左边一个已建好代理的会话里每 100ms 打一个字，3 轮各 20 个，每轮后清空 | 每键主线程（到键后第 4 帧）、键后最长一帧 |
| `send` | Mac | 每轮打完发出去；消息只排进本地、不发给工作机，每轮后撤掉 | 发送后的首帧、前 300ms 和 1.5 秒的主线程、帧间隔 |

不给场景时跑这个平台的全部。选项：

- `--repeat N`：每个场景、每个变体启动几次。单次受负载、指针位置影响，判断改动至少跑 3 次看中位。
- `--variant 名=参数`：同一个测量版带另一组启动参数作为对照变体，如 `-perfScrollTop 0`；`--base <检出目录>` 用另一个检出编一份测量版作对照变体（那个检出也要有测量代码，`app/Vendor` 要链好）。各变体按场景交替启动，同一时段的负载对它们一样；比新旧代码优先用这两个，比 `--compare` 和旧结果比更可靠。iPad、iPhone 一次只装得下一份测量版，不支持 `--base`。
- `--trace`：每次附一份 Time Profiler（Mac 挂到测量版进程上，iPad 由 xctrace 启动），只算测量区间（测量版打的 Points of Interest 区间 `measure`）里的主线程样本，按关键词分：每个样本归到给的次序里第一个在栈上出现的关键词，都没有的归「其他」，各项加起来等于合计；拖缝、侧栏摊到每步。`--keywords a,b` 换关键词，里层的放前面，显示周期、CA 提交这类包着一切的放最后，默认的一组见脚本开头。
- `--lock <文件>`：编译和每次测量都用 `lockf` 拿着这把锁，和同时编译、测量的其他检出排队；iPad 从装测量版到测完重开整段拿着锁。整条命令已经套在同一把锁的 `lockf` 里时不要再给，会自己等自己。
- `--workspace <ID>`：临时切到这个工作区再测，不存盘；不给就测 App 打开时选中的工作区。
- `--threads a,b`：台面上只摆这几个会话（会话 id），其余缩进停靠栏，这几个按次序从停靠栏恢复，测完写回。不给时台面上的会话窗口不到两个，就按停靠栏的次序恢复到两个。排布存在共用的 UserDefaults 里，别的 Kite、别的测量版都可能改过，比较前后两次时给同一组会话。
- `--window 宽x高`：Mac 测量窗口的大小，默认 1200x924，左右两个窗口都窄于对话最大宽度（720）；窗口宽于它时拖缝不重排正文，测不出差别。
- `--pairs N`：缩小恢复和 iPhone 各场景每次启动做几次，默认 4。
- `--rounds N`、`--no-build`、`--out <目录>`、`--compare <结果目录>`：每次测几轮、用上次编好的测量版、结果放哪、和之前一次的 `summary.json` 逐项对比。

结果默认在 `build/perf/<平台>-<时间>/`：`summary.md` 是各张表（同一场景、同一变体的所有次数取中位，主要一项附最小到最大），`summary.json` 供以后 `--compare`，每次启动一个目录，有测量版的 `report.json`（逐帧原始数据；`stageAtStart` 是摆台面之前台面上有哪些会话，和上一次不同说明共用的排布被改过）、布置好和测完的截图、失败时当时的截图、启动时的负载，`--trace` 时还有 trace 和导出的表。基线和历次值得留的结论记在项目记忆 `todo-window-motion-remaining`，不写在这里。

注意：

- 测量版和用户的 Kite 共用 bundle ID、登录和 UserDefaults。测量版测完把改过的排布（`KiteWindowLayout.*`）和窗口位置写回原样再自己退出，报告里列出写回了哪些；测量进行中别在自己的 Kite 里改排布，会被写回覆盖。脚本只结束自己启动的那个测量版（按可执行文件路径认），主检出和别的检出里开着的 Kite 都不碰。
- 测量不留副作用：发送只排进本地，台面上的状态（在跑、压缩、操作栏）是本地造的；草稿会话发送会真的建代理，打字和发送只用已建好代理的会话。
- Mac 要在已解锁、有人登录的图形会话里跑：测量版会跳到最前、窗口改成测量大小，测量中别动鼠标键盘。脚本放行前会按进程号把测量版请到最前，测量版开测时再查一次；不在最前或窗口被挡住时系统不正常出图，这一次判为没测成，不进表。别的检出正在编译时先等它编完（最多 3 分钟）。
- iPad、iPhone 要连着、解锁，脚本先查锁屏，锁着就跳过。装上去的测量版替换掉设备上原来那份 Kite（同一个 bundle ID），测完不带测量参数重开 Kite（它让设备不自动锁屏）；不带 `-perfScene` 时测量版和平常一样。iPhone 的场景要工作区开着窗口（紧凑布局），横滑要一行里不止一个窗口，键盘要当前窗口有输入框。
- 测量代码不在 `.kite/check` 的编译里。改了它用到的接口（`WindowLayout` 的拖缝、`TranscriptListView` 的行、`ThreadWindowView` 等）时测量版可能编不过，跑测量时一并修。产品代码里的挂钩：`KiteApp` 建好模型后交给 `PerfProbe.arm`，`WorkThread.send` 开头问 `PerfProbe.hold`，iPhone 的紧凑布局出现时把抽屉、一行窗口登记给 `PerfProbe.drawer`、`PerfProbe.row`（`CompactShellView`、`CompactRowView`）。

## 真实订阅验收

升级 SDK、Claude Code 或模型接入后，需要用对应工作机上的真实订阅验收。Claude 验收先确认终端已登录，并清理测试进程继承的 `CLAUDE_*` 环境变量。假端点测试与 SDK 事件不能代替真实模型请求证据；验收结果保留在任务记录中，注明版本、环境和覆盖范围。

1. 在 App 创建代理，完成读取、修改、shell 与项目检查。核对工具调用和结果、增量显示、文件快照及历史引用；确认暴露的工具符合当前角色与授权。Claude 正常完成一轮后应保留进程，宿主能力不被 Claude 的内置工具或 hooks 重复执行。
2. 检查首轮、工具调用后和原生恢复后的实际上游请求。核对系统提示词与历史内容符合 [上下文模板](../../../docs/harness-上下文组装.md)，没有额外注入 Claude 的日期、环境、技能或项目记忆。高用量提示要区分客户端注入与服务端行为；仅观察 SDK 输出不能作出来源结论。
3. 在配置稳定且没有压缩的条件下，分别验证持续会话和停止后继续输入。确认原生恢复不重复提交输入，并分别记录首轮与后续轮次延迟；不从单次测量推断性能保证。
4. 按 [会话状态机](../../../docs/会话状态机.md) 和 [线程通知投递](../../../docs/线程通知投递.md) 验证停止、队列退回、配置与模型切换、授权撤销和恢复。实例归档与工作区归档的范围分别按 [工作机契约](../../../docs/kited.md) 验证。
5. 核对角色工具、插件授权和凭据访问；已撤销的能力必须被拒绝。项目 MCP 配置不应自动授予实例能力，新增授权在对应后端的生效边界内进入模型请求，规则见 [Bun 插件](../../../docs/Bun插件.md)。
6. 核对模型目录声明的最大上下文与本轮实际配置的上下文窗口。Claude 使用 SDK 提供的运行摘要，自研 harness 核对宿主请求配置；两者都不能只凭模型目录的上限推断本轮实际可用容量。
