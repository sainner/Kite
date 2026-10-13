---
name: performance-diagnosis
description: 动画卡顿怎么量：固定场景的测量入口和交替对照、帧间隔、真机 Time Profiler、临时探针的坑、滚动软边失效的诊断，Mac 的结论不能外推到 iPhone
metadata:
  node_type: memory
  type: reference
  originSessionId: 19e18107-9859-4070-a429-82a37c6d6214
  modified: 2026-10-14T09:00:00+09:00
---

- 卡顿先量再改：用 `CADisplayLink` 记下动作后一两秒的帧间隔，每做一次换一种组合对照，一次只用一种组合。手感只能说明卡不卡，说明不了卡在哪。
- 拖缝、侧栏改宽、缩小恢复、静息占用、打字发送这些固定场景，用 `kited/test/manual/measure-perf.ts` 重跑（用法见同目录 README 的「性能测量」，基线在 [[todo-window-motion-remaining]]）。比新旧代码用它的交替跑（`--base` 另一个检出、`--variant` 启动参数），不和旧结果文件硬比：单次测量受指针位置和其他会话活动影响，同一份代码中位丢帧会在 2 和 11 之间跳（2026-10-11），至少跑 3 次看中位。
- iPhone 的卡顿要在真机上量，Mac 上的结论不能外推。2026-10-11 同一个发送卡顿：Mac 上是控制区的逐帧动画；iPhone 上是对话里 `UITextView` 反复量尺寸，每次卡 200–500ms。真实触摸（交互玻璃）的开销，Mac 上的自动发送也测不到。
- 真机 Time Profiler：`xcrun xctrace record --template 'Time Profiler' --device <ID> --launch -- com.sainner.kite`。`--attach` 按进程名或进程号都找不到进程（2026-10-11，Xcode 27.2）。
  - 导出 `time-profile` 表后，调用栈在 `tagged-backtrace` 元素里。
  - `potential-hangs` 表直接列出 250ms 以上的卡顿。
- 探针日志写到 App 的缓存目录，用 `devicectl device copy from` 取回，见 [App 入口](../../app/README.md#预览和验证)。
- 自己另编对照用的版本时，加 `SWIFT_OPTIMIZATION_LEVEL=-O` 并单独指定 `-derivedDataPath`，不搅乱日常的增量缓存（测量入口就这样编）。
- 动画“跳”而帧间隔看着正常时，逐帧记动画自己的进度（位置、距离）和旁边内容的位置对照。2026-10-11 发送的点阵波就是这样查出的：它从发送时刻开始计时，发送那次排版近百毫秒，第一帧跳过 12 格，比对话滑动早约 100 毫秒。
- Mac 测量版是沙盒 App，写不出容器、脚本也读不了容器，结果 POST 到本机端口取回；自己窗口的像素经 `dlsym` 调 `CGWindowListCreateImage` 抓，不需要录屏权限（测量入口都这样做）。
- Mac 上量滚动（滚动条跳、内容跳）：真实 App 里用 `CGEvent(scrollWheelEvent2Source:)` 带 `scrollWheelEventScrollPhase`（began/changed/ended）、窗口号字段，转成 `NSEvent` 后 `NSApp.sendEvent`，SwiftUI 会报真实的滚动相位；不要滚过头，回弹会改滑块长短。离屏窗口收不到这种滚轮事件，LazyVStack 还会把直接改 clip view 的偏移拉回去（2026-10-12）。内容跳不跳：人不动时记可见区顶上那个文本视图相对 clip view 的位置。探针日志用 `Logger` 写、`/usr/bin/log show` 取（zsh 自带的 `log` 会抢名字）。
- 窗口动画的画面瑕疵（露直角、被切）也这样抓真实 App 的逐帧像素，先于离屏夹具：2026-10-12 缩小露直角，单独渲染 `WindowSurface` 各种内容都正常，真实 App 截帧才看出是卡片之间的叠放次序。工作区里有别的会话未提交的改动时，探针放进 `git worktree`（链上 `app/Vendor`，单独 `-derivedDataPath`）构建，不碰共享工作区。
- 找逐帧开销在哪：在测量版里临时加开关（关掉某一项逐帧更新），做成启动参数，用测量入口的 `--variant` 和正常版交替跑，比主线程和丢帧；入口的 `--trace` 再按关键词把测量区间里的主线程分开。测量版必须在最前、窗口露出来才算数：2026-10-12 脚本在后台启动的测量，用户两次指出看不到、系统不正常渲染；测量入口会把测量版带到最前，不在最前的那次判为没测成。`.task` 里的探针会随视图重建被取消，得放进独立 Task。排布要分开测，一窗占满台面和一列两窗的开销来源完全不同。探针别交换 AppKit 自己的方法（2026-10-12 换掉 NSView 的 addSubview 记录挂了什么，测量版闪退），只在自己的视图子类里覆写。`xctrace --attach` 采不到 SwiftUI 模板的数据；Mac 上 `--launch` 按 bundle ID 启动的是已安装的正式版，测量版要按进程号挂。
- 滚动软边不见了：导出 `NSScrollPocket` 的配方（Mirror 看 `v8LayerTree.model`，`ThinFilmPocket(hasFloatingElements: true)` 才模糊，`SoftPocket(hasFloatingElements: false)` 不模糊），再对每个登记的元素调 `_visibleFrameInCoordinateSpace:` 看位置。2026-10-12 下面那个窗口没软边，就是嵌套托管视图报的元素位置差了它在窗口里的偏移。
- 2026-10-12 查出的几个坑：SwiftUI 几何效果缩放 AppKit 视图会逐个改 frame/bounds，文本视图每帧重排重画；`NSViewRepresentable` 不实现 `sizeThatFits` 时按 Auto Layout 量 `fittingSize`，子树大就很贵；SwiftUI 的 `mask` 加在 AppKit 视图上按整块区域逐帧重画遮罩；`sublayerTransform` 连 `mask` 一起变换。
- 量改窗口宽度的开销先把窗口定窄：对话正文最宽 720 点（`Metrics.transcriptWidth`），窗口比它宽时拖缝、让位都不重排正文，新旧写法测不出差别（2026-10-12；测量入口默认把 Mac 窗口定成 1200×924）。测量版等「长对话」按总高（几屏）判断，不按轮数：按需排版按人发的轮次分组，11 轮就有近 4 屏。
- 丢帧是阈值效应：每帧主线程超过 16.7ms（测量机是 60Hz 外接屏）就隔帧出图，CPU 少了三成丢帧也可能一帧不变。报每帧主线程和帧间隔，按起手、持续、停顿、松手后分段，计数只算动作期间；驱动拖动按实际最小尺寸算范围，被夹住不动的那段会拉低平均（2026-10-13 拖缝，Codex 复核指出）。离屏单对话的 bench 会把正文排版放大成主因，归因先在真实 App 里用同一次启动的分层模式（正常、不重排、定尺寸、拿掉内容）定量，再试单项开关。
- 探针的坑（2026-10-13）：读 `@Environment(\.self)` 的探针在环境变化时不重算，`updateNSView` 也只在读过的那几项变了才调，查环境变化要读具体键；开优化的测量版里 `Thread.callStackSymbols` 每次几毫秒、会占满主线程，判断调用来源改用 `callStackReturnAddresses` 比地址。
- 图层每帧重画、却断不到谁调 `setNeedsDisplay` 时（2026-10-14 侧栏拖宽）：lldb 断 QuartzCore 的 `CA::Layer::mark(CA::Transaction*, unsigned int, unsigned int)`，第三个参数 0x100 的是标成要重画，记栈看来路。AppKit 有两条不走公开方法的路：改 `sublayerTransform` 经 `_NSInvalidateSuggestedContentsScaleBelow` 把整棵子树标成重画，视图可见区变了经 `NSViewHierarchyInvalidateVisibleRect` 标。用 lldb 挂测量版：断点先停用，在只在测量段里跑的函数上（没有就临时加一个）再打开，回调里只记栈、不求值表达式；热路径上逐次求值会把测量版拖到测量入口超时被杀，共享的 UserDefaults 就不写回了（2026-10-14 出过一次）。
- 先分清是计算还是渲染：计数显示 body 和取样一次都没跑而开销还在，就是渲染，换成纯色对照即可确认。2026-10-11 卡片点阵就是这样查出的：整窗大小的着色器层随所在渲染层每帧重画。
- 改完要验证：用 Instruments 的 SwiftUI 模板数一次流式刷新或一次动作里重算了多少个 body，同时看 Time Profiler 里布局与渲染的耗时。只数 body 不够，body 没少跑开销也可能在排版和渲染上；真机和 Mac 分别量。
- SwiftUI 用几何效果移动容器时（`ignoredByLayout`、`visualEffect` 都一样），里面所有 `.frame(in: .global)` 和读 `Text.LayoutKey` 锚点的视图每帧重算，只读本地尺寸的不受影响（2026-10-11 离屏实测）。
- UIKit 的两个坑（2026-10-14 iPhone 真机 Time Profiler）：`UIView.alpha` 在 0 和非 0 之间变时 UIKit 把整棵子树通知一遍看不看得见（`_notifySubtreeVisibilityDidChange`），底下有托管视图、文本视图时一次十几毫秒，换窗口时的淡入淡出改设 `layer.opacity` 并自己加图层动画；托管视图里全透明的 `safeAreaBar` 不算滚动软边的元素，软边会变成滚动视图自带的那条（高度不随标题栏），要垫一层看不出来的底，软边高是元素底边再往下约 40 点。
- iPhone 测量别让设备停在测量版外面太久：2026-10-14 键盘场景挂 Time Profiler 时 10 分钟没出报告，期间没有 Kite 在前台防锁屏，iPhone 锁了，后面的真机测量都做不了。挂 `--trace` 先单独试一个短场景。
- iPhone 上点阵取景框逐帧刷新约 60Hz，旁边的滚动是 120Hz，原因没查。用户看过认为点阵波 60 帧够用（2026-10-11），不必为它追 120Hz。

**Why:** 这次先在 Mac 上修好，再按 Mac 的思路改 iPhone，白改了两轮；真机录一次调用栈就定位了。
**How to apply:** 查动画性能先用测量入口重跑固定场景、和基线或改动前的检出交替比；入口之外临时加的探针先说明加什么、为什么，测完删掉；需要用户操作时一次说清要做几次、怎么做。协作要求见 [[feedback-ui-workflow]]，效果取舍见 [[feedback-interaction-quality]]。
