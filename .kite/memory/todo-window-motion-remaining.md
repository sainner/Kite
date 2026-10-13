---
name: todo-window-motion-remaining
description: 窗口动画剩余开销：缩小首帧仍以 SwiftUI 整轮更新为主；Mac 原生对话拖缝每步约 19～21ms（30 帧）的构成、非连续排版的坑、两窗轮流重排原型可到 60 帧；iPad 原生对话拖缝约 21.5ms/步（外壳约 9.3ms），iPhone 未量
metadata:
  node_type: memory
  type: todo
  originSessionId: dc7b2909-8382-45f7-94f3-60a3899b24a9
  modified: 2026-10-13T17:30:00+09:00
---

来源：2026-10-11 多窗口缩小、恢复卡顿；2026-10-12 换成 NSTextView 正文后又卡。Mac 上正文、标题两侧单独托管、按图层变换，点阵和光标、交互不参与过渡（见 [[feedback-interaction-quality]]）。2026-10-13 一轮处理后（提交见 git log）：窗口常带 Auto Layout 引擎（`WindowLayoutEngine`），空画板静止主线程 28% → 17%、恢复窗口丢帧 11 → 1；空画板就此结束，用户不要限帧。

未解决：
- 缩小首帧：2026-10-13 Debug 一列两窗口，缩小首帧 84.5 → 77.5ms、整段主线程 240 → 218ms，恢复无变化。剩下的大头是 SwiftUI 处理排布改动的整轮更新（缩小约 46ms、恢复约 65ms），其次正文按新尺寸重排约 20～30ms、悬停重算约 6ms（在 SwiftUI 内部）。单看首帧时长不可靠（52～106ms 双峰，部分工作会推到计时之后），按整段主线程和丢帧判断。
- 拖缝调整大小：用户 2026-10-13 定为正文随时跟宽度重排（试过「指针动时定住、停下或松手再排」的方案说明后改回），接受约 30 帧；同日又说拖动时对话不必保持贴底，并让继续优化。-O、60Hz、左右两窗：每帧主线程约 27ms，拿掉对话约 10ms；对话在场的固定成本约 5ms、对话区改尺寸约 5ms、文字重排约 7ms，没有单独的元凶。对话区不改尺寸（定住）约 15ms、接近 60 帧。实测对帧率无效、未提交的：按行冻结、行内代码背景共用排版器、跳过文本视图光标区域重算、只挪位置时不重排、不发几何通知、关滚动条动画、拖缝时不切换可否点击；合并占位组按数据只省零点几毫秒；Codex 同日又排除了固定正文宿主根尺寸、标题只发语义变化、量高时不 setFrameSize、包一层原生容器、替换 VStack、geometryGroup、强制连续排版。
- 拖缝长回复（Codex 2026-10-13 完整 App 真实会话，-O、90 步、每轮清尺寸缓存测首见宽度）：短回复主线程约 2.6 秒/90 步、约 33ms 一帧；滚到含表格、代码的长回复约 4.9 秒、约 66ms。长回复里 TextKit 全文 `ensureLayout` 约 0.83 秒（每个新宽度只量一次，不是重复量），屏外附件内部布局约 0.74 秒；后者已改为屏外推迟改宽、滚入前补齐，降到约 4.1 秒、约 50ms。正文换成空占位仍约 1.2 秒/90 步（含滚动容器、输入区和舞台）。
- TextKit 视口裁切的正确性边界：把部分可见正文的视口裁到真实可见交集能省 10%～12%，但 LazyVStack 首次只露底部、或顶部被裁时改宽，会大面积错位缺字；保持「文首到可见底边」等正确的裁法没有稳定收益。判对错要在任何主动 ensure/cacheDisplay 之前比首次实际绘制与完整滚入参照，回归入口见 `kited/test/manual/README.md`。Apple 要求视口代理 override 调 super，不能靠截掉屏外 fragment 的 configure 回调省成本。原始测量在 `/private/tmp/kite-codex-perf-audit/`，引用前先确认还在。
- 拖动时只排看得见的（Claude 2026-10-13，分支 `claude/mac-native-transcript` 第四期）：自定义 NSTextContainer 按位置给行宽的做法真实 App 里反而更慢，放弃；改用 TextKit 2 非连续排版——改宽后从可见区上沿那段 `enumerateTextLayoutFragments(from:options: .ensuresLayout)` 排到下沿，上面没排的按 TextKit 估的高占位（估的位置可差上千点，列表按住可见区那截文字对齐，停下整段排准）。坑：往上补排的段会和已排的叠在一起、不推开，文本视图的视口不能越过排好的上沿；估的高带小数时贴底会逐像素抖，要取整。-O 两窗 90 步、与整段排同次启动逐像素一致：长回复 26.5 → 21ms/步、贴底（折叠长消息只排露出）22.5 → 20ms、工具行 19.6 → 19ms，帧间隔仍 33ms。剩余：窗口外壳约 9.4（SwiftUI 根约 3.5、窗口内容约 3）、正文和气泡量高各约 2～2.6、文本视图自己的视口排版约 1.6（`_updateContentSizeIfNeeded`、`locationForPositionInViewport`）、CA 提交约 1.5、代码和表格卡片（SwiftUI 托管）约 0.8ms 一张。测量版原型「两窗隔一帧轮流重排」三个场景都到 16.7ms 帧间隔（每步约 15ms），代价是每个窗口的正文 30Hz 跟宽度；用户随后选了重写外壳（见 [[decision-native-ui]]），这一原型没采用。
- 拖缝的预算与 AppKit 列表原型（Claude 2026-10-13，完整 App、-O、左右两窗、90 步，同一次启动交替）：对话换成同高空白每步 9.4ms、60 帧；对话在场但宽度定住 16.4～17.9ms（约一半帧超时）；原写法长回复场景 30.4ms、短消息场景 19ms。AppKit 滚动视图逐行托管现有行视图：短消息场景每步 36ms，所有行只挪位置不改宽也要 29ms——托管的 SwiftUI 行改宽约 0.8ms 一行、只挪位置约 0.2～0.3ms 一行，比整列一棵 SwiftUI 树（约 0.3ms 一个可见行）还贵。「列表换 AppKit、行仍托管 SwiftUI」不成立，拖动路径上的行必须不经 SwiftUI。
- iPad 宽屏拖缝（2026-10-13 真机 iPad Pro 12.9 第 5 代）：SwiftUI 对话每步 166～317ms；对话改 UIKit（分支 `claude/ios-uikit-ui`）后每步主线程约 21.5ms、帧间隔中位约 22ms，其中 SwiftUI 外壳（beginTransaction 加托管排版）约 9.3ms、对话自己（排列量高、文本视图的视口排版、单行字）约 9～10ms，16.7ms 要等外壳改原生，见 [[decision-native-ui]]。iPad 卡片和 iPhone 侧栏、底栏拉开时的窗口缩放（`WindowShell`）同样是对含 UITextView 的整块内容做几何效果，还没在真机上量；Mac 的结论不外推。

完成条件：上述各项处理或经用户确认不做；iPad、iPhone 的结论来自真机测量。测量方法见 [[performance-diagnosis]]。
