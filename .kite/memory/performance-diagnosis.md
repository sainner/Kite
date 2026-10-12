---
name: performance-diagnosis
description: 动画卡顿怎么量：帧间隔对照、真机 Time Profiler、用户双击的单次启动测量版、滚动软边失效的诊断，Mac 的结论不能外推到 iPhone
metadata:
  node_type: memory
  type: reference
  originSessionId: 19e18107-9859-4070-a429-82a37c6d6214
  modified: 2026-10-12T09:39:55.609Z
---

- 卡顿先量再改：用 `CADisplayLink` 记下动作后一两秒的帧间隔，每做一次换一种组合对照，一次只用一种组合。手感只能说明卡不卡，说明不了卡在哪。
- iPhone 的卡顿要在真机上量，Mac 上的结论不能外推。2026-10-11 同一个发送卡顿：Mac 上是控制区的逐帧动画；iPhone 上是对话里 `UITextView` 反复量尺寸，每次卡 200–500ms。真实触摸（交互玻璃）的开销，Mac 上的自动发送也测不到。
- 真机 Time Profiler：`xcrun xctrace record --template 'Time Profiler' --device <ID> --launch -- com.sainner.kite`。`--attach` 按进程名或进程号都找不到进程（2026-10-11，Xcode 27.2）。
  - 导出 `time-profile` 表后，调用栈在 `tagged-backtrace` 元素里。
  - `potential-hangs` 表直接列出 250ms 以上的卡顿。
- 探针日志写到 App 的缓存目录，用 `devicectl device copy from` 取回，见 [App 入口](../../app/README.md#预览和验证)。
- 对照开了编译优化的版本时，加 `SWIFT_OPTIMIZATION_LEVEL=-O` 并单独指定 `-derivedDataPath`，不搅乱日常的增量缓存。
- 动画“跳”而帧间隔看着正常时，逐帧记动画自己的进度（位置、距离）和旁边内容的位置对照。2026-10-11 发送的点阵波就是这样查出的：它从发送时刻开始计时，发送那次排版近百毫秒，第一帧跳过 12 格，比对话滑动早约 100 毫秒。
- Mac 上量窗口类动画：Debug 版加启动参数钩子自动执行动作，用 `CADisplayLink` 记主线程帧间隔；沙盒 App 写不出容器，结果 POST 到本机端口取回；自己窗口的像素经 `dlsym` 调 `CGWindowListCreateImage` 抓，不需要录屏权限。单次测量受指针位置和其他会话活动影响，同一份代码中位丢帧会在 2 和 11 之间跳（2026-10-11）：等负载回落再测，至少跑 3 次看中位。
- Mac 上量滚动（滚动条跳、内容跳）：真实 App 里用 `CGEvent(scrollWheelEvent2Source:)` 带 `scrollWheelEventScrollPhase`（began/changed/ended）、窗口号字段，转成 `NSEvent` 后 `NSApp.sendEvent`，SwiftUI 会报真实的滚动相位；不要滚过头，回弹会改滑块长短。离屏窗口收不到这种滚轮事件，LazyVStack 还会把直接改 clip view 的偏移拉回去（2026-10-12）。内容跳不跳：人不动时记可见区顶上那个文本视图相对 clip view 的位置。探针日志用 `Logger` 写、`/usr/bin/log show` 取（zsh 自带的 `log` 会抢名字）。
- 窗口动画的画面瑕疵（露直角、被切）也这样抓真实 App 的逐帧像素，先于离屏夹具：2026-10-12 缩小露直角，单独渲染 `WindowSurface` 各种内容都正常，真实 App 截帧才看出是卡片之间的叠放次序。工作区里有别的会话未提交的改动时，探针放进 `git worktree`（链上 `app/Vendor`，单独 `-derivedDataPath`）构建，不碰共享工作区。
- 找逐帧开销在哪：测量版一次启动、运行中依次切换开关（关掉某一项逐帧更新），每项自动缩小、恢复几次，记主线程 CPU（`thread_info`）和丢帧，结果 POST 回本机；由用户在 Finder 双击打开（2026-10-12），同 bundle ID 的 Kite 要先退出，中途退出会留下收在停靠栏里的窗口。脚本反复 `open` 启动的测量不算数：用户看不到、系统不正常渲染（用户 2026-10-12 两次指出）；只截静止画面、导出视图层级时脚本启动可以。`.task` 里的探针会随视图重建被取消，得放进独立 Task。测量版先向接收端报到、等放行再跑；脚本在报到后把 Time Profiler 挂到最新的那个进程再放行，用户重开时要重新挂（2026-10-12 有一轮挂在了已退出的进程上，白录）。首帧、结束分开记：动作到 WindowMotion 开始计时、moving 翻回后 40ms 的主线程 CPU，加各视图 body 的计数。排布要分开测，一窗占满台面和一列两窗的开销来源完全不同。探针别交换 AppKit 自己的方法（2026-10-12 换掉 NSView 的 addSubview 记录挂了什么，测量版闪退），只在自己的视图子类里覆写。`xctrace --attach` 采不到 SwiftUI 模板的数据；`--launch` 按 bundle ID 启动的是已安装的正式版。
- 滚动软边不见了：导出 `NSScrollPocket` 的配方（Mirror 看 `v8LayerTree.model`，`ThinFilmPocket(hasFloatingElements: true)` 才模糊，`SoftPocket(hasFloatingElements: false)` 不模糊），再对每个登记的元素调 `_visibleFrameInCoordinateSpace:` 看位置。2026-10-12 下面那个窗口没软边，就是嵌套托管视图报的元素位置差了它在窗口里的偏移。
- 2026-10-12 查出的几个坑：SwiftUI 几何效果缩放 AppKit 视图会逐个改 frame/bounds，文本视图每帧重排重画；`NSViewRepresentable` 不实现 `sizeThatFits` 时按 Auto Layout 量 `fittingSize`，子树大就很贵；SwiftUI 的 `mask` 加在 AppKit 视图上按整块区域逐帧重画遮罩；`sublayerTransform` 连 `mask` 一起变换。
- 量改窗口宽度的开销先把窗口定窄：对话正文最宽 720 点（`Metrics.transcriptWidth`），窗口比它宽时拖缝、让位都不重排正文，新旧写法测不出差别（2026-10-12）。测量版等「长对话」按总高（几屏）判断，不按轮数：按需排版按人发的轮次分组，11 轮就有近 4 屏。
- 先分清是计算还是渲染：计数显示 body 和取样一次都没跑而开销还在，就是渲染，换成纯色对照即可确认。2026-10-11 卡片点阵就是这样查出的：整窗大小的着色器层随所在渲染层每帧重画。
- 改完要验证：用 Instruments 的 SwiftUI 模板数一次流式刷新或一次动作里重算了多少个 body，同时看 Time Profiler 里布局与渲染的耗时。只数 body 不够，body 没少跑开销也可能在排版和渲染上；真机和 Mac 分别量。
- SwiftUI 用几何效果移动容器时（`ignoredByLayout`、`visualEffect` 都一样），里面所有 `.frame(in: .global)` 和读 `Text.LayoutKey` 锚点的视图每帧重算，只读本地尺寸的不受影响（2026-10-11 离屏实测）。
- iPhone 上点阵取景框逐帧刷新约 60Hz，旁边的滚动是 120Hz，原因没查。用户看过认为点阵波 60 帧够用（2026-10-11），不必为它追 120Hz。

**Why:** 这次先在 Mac 上修好，再按 Mac 的思路改 iPhone，白改了两轮；真机录一次调用栈就定位了。
**How to apply:** 查动画性能时先说明要加什么探针、为什么，测完删掉；需要用户操作时一次说清要做几次、怎么做。协作要求见 [[feedback-ui-workflow]]，效果取舍见 [[feedback-interaction-quality]]。
