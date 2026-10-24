---
name: ui-hit-testing-debugging
description: 界面事件诊断的证据边界、光标被谁改掉的探针做法、SwiftUI 菜单行为的小程序验证与交互玻璃让子菜单收起、UIKit 机制用 Catalyst 小程序验证、simctl 两次内核崩溃（之后不再调用 simctl）、真机现场采集不挂调试器、真机崩溃报告怎么取
metadata:
  node_type: memory
  type: context
  originSessionId: 2b6008b7-bf52-4a23-b577-de6bc7b05c97
  modified: 2026-10-24T16:26:38.946Z
---

合成事件后的画面变化可能混入真实用户输入，需要确认目标收到事件；AppKit/UIKit 的 hitTest 落点也不能单独证明 SwiftUI 内部命中或手势正确。

用 simctl 驱动模拟器时整机内核崩溃过两次，两次的最后一步都是 `simctl launch --console-pty` 起探针再结束它：第一次是 `timeout 8 xcrun simctl launch --console-pty …`；第二次在 2026-10-13 21:19（Kernel data abort，看门狗重启，崩溃报告里是 simctl），之前一小时里同时开着五台模拟器，反复 `simctl ui content_size`、装、启动、结束 App。是 console-pty、强杀还是并行模拟器触发的，没有查清。第二次之后编排者定了不再调用 simctl（编译模拟器目标照常），界面验证改到真机（做法见 [[ios-layout-probe]]）；这是编排者的决定，用户没有直接说。

只在真实悬停下出现的现象，合成的 `NSEvent` 不触发 SwiftUI 悬停，强制状态也复现不出。2026-10-11 恢复窗口时按钮组被裁，用户指出要鼠标停在停靠栏后，改用后台滚动截图加图层树记录、请用户真实操作一次，才点名是哪一层在裁。这类问题先问清触发条件，再做被动采集。

光标被谁改掉这类只在真实悬停下出现的问题，2026-10-16 输入区光标用过一个临时探针，一轮真实操作就定位：Debug 里交换 `NSCursor.set` 和 `NSView.cursorUpdate(with:)` 的实现，记下调用栈、接收者和跟踪区域，用 `os.Logger` 写系统日志，再用 `/usr/bin/log show --predicate 'subsystem == …'` 读（zsh 的 `log` 是内建命令，不带路径读不到）。读日志前先按进程号核对用户测的是本检出的预览：其他工作树的 Kite 预览可能同时开着，那次用户测的就是 local-first 的实例。探针查完就删了，结论写在代码注释里（NativeCursor）。2026-10-18 的 `CursorProbe` 至今仍在 Debug 版里（ControlsBarView 初始化时装上），光标问题先读现成的 `kite.cursor-probe` 日志，用户刚测过的那轮往往已经记下。单条系统日志有长度上限，视图链加十几帧调用栈会被截成 `<…>`，看栈要单独记一条、只留符号名；2026-10-21 网页光标闪烁就是这样补了一轮才看清（结论在 `webViewUnderPointer` 的注释里）。闪烁的频率随窗口里别处的刷新变化，用户说「好了」不代表修好，先看日志里的次数。

现场难复现时先做不碰进程的采集：`xcrun devicectl device capture screenshot` 截真机屏、`devicectl device copy from` 取偏好和缓存。2026-10-15 iPhone 侧栏浅底白字时，用 `xcrun lldb --batch` 加 `device process attach --pid` 想读视图层级，进程没有停下（`process interrupt` 报 Process must be launched），lldb 退出后 App 被结束，现场丢失；好在用户知道怎么复现（回主屏幕再进）。没确认能停住、能放开之前，不在用户正开着的 App 上挂调试器。

真机上点了没反应这类，在 Debug 版里沿手势、命中、openURL、打开各步往 `Library/Caches` 的文件里记一行，请用户真实点一轮，用 `devicectl device copy from` 取回；手势的 delegate 与视图的 `gestureRecognizerShouldBegin`、动作方法都记，能分出「没开始」「开始了被别的手势挤掉」「认出了没命中」。探针版按工作机 kited 的那份提交（`/machine` 的 `version.commit`）在 worktree 里编：按主线编的协议号可能比工作机新，App 显示「工作机待更新」，升级 kited 要重启它、打断代理。2026-10-21 iOS 正文链接一直点不开，这样两轮查出是 `buttonMaskRequired = .secondary` 的右键点按也认手指（只筛指针），和点链接互斥又先认出，见 `PhoneTextInteraction`。

SwiftUI 菜单的行为可以不打扰 Kite、用 swiftc 小程序验证：按钮位置用 `onGeometryChange` 记（`.global` 按整个窗口、含标题栏算），往 HID 发真实的鼠标移动和点击打开菜单，再发方向键移到子菜单项、展开（`postToPid` 菜单收不到；发之前先确认 `NSApp.isActive`，不然键落到用户的 App），按可见的 `NSPopupMenuWindow` 个数判断子菜单开没开。进程内没有辅助功能客户端时 SwiftUI 不建辅助功能树，找不到菜单按钮。程序会抢前台、动指针，用户一操作结果就作废，跑之前说一声。

Mac 更多菜单的审批模式子菜单自己收起，前后查了两次。2026-10-21 查出菜单开着时所在视图重算一次子菜单就收起（新闭包让菜单项重新同步）。2026-10-25 发现不重算也会收：交互玻璃（`.glassEffect(.interactive())`）里的 SwiftUI `Menu` 按下就弹出，松手被菜单吞掉，玻璃停在按下变亮的样子，1.9～2.4 秒后自己复位，同时 SwiftUI 把开着的菜单重新同步一遍（`PlatformItemList.update`），子菜单就收起，用户看到的是玻璃高光消失。同一次启动里每开一次菜单轮换变体，请用户点几轮，结果是玻璃不交互时不同步、不收，去掉 `.help` 照样收。小程序复刻不出这个 2 秒的同步，说明还要 Kite 里的某个条件，没查到是哪个。修法是改成按钮、松手弹出自己建的 AppKit 菜单，见 `MoreMenu` 的注释；用户确认菜单本来就该松手弹出。别的放在交互玻璃里、带子菜单的 SwiftUI 菜单遇到同样现象按这个查：SwiftUI 有没有动菜单项，看 `NSMenu.didChangeItemNotification`，栈里是 UpdateGroup 刷新调到 `PlatformItemList.update`。

UIKit 和 iOS 上 SwiftUI 的机制问题，不用模拟器也能在本机用 Mac Catalyst 小程序验证：`swiftc -parse-as-library -target arm64-apple-ios27.0-macabi`，`-Fsystem` 指向 macOS SDK 的 `System/iOSSupport/System/Library/Frameworks`、`-L` 指向 `System/iOSSupport/usr/lib/swift`，放进带 `UIApplicationSceneManifest` 的最小 `.app`、`codesign -s -` 后直接跑可执行文件，结果写 stderr，几秒后自己 `exit`。会弹窗口，跑之前说一声。2026-10-24 用户气泡、头像发灰就这样查出弹出提醒时 UIKit 把根视图调暗、SwiftUI 主题色跟着变灰（修法见 `WindowInterfaceStyle` 的注释）。Catalyst 是 Mac 外形，排版、手势和呈现样式不能代替真机，只拿来确认框架机制。

真机闪退先取崩溃报告：`xcrun devicectl device info files --device <ID> --domain-type systemCrashLogs` 列出，`device copy from --source <文件名>` 取回 `.ips`。SwiftUI 环境里缺 Observable 对象这类断言，报告里只有 `EnvironmentBox.update` → `_assertionFailure` 的栈，没有报错文本和 App 帧；`log collect --device` 要 root，取不到真机日志。2026-10-16 添加窗口闪退是按栈推出机制，再用 `swiftc` 编几十行的 AppKit 小程序复现出同一条 `No Observable object` 报错、验证修法，没让用户再点一次。

**Why:** 不可靠输入会造成诊断误判，进程命中结果和真实手势结果属于不同证据。
**How to apply:** 仅在排查事件或逻辑时使用探针并说明目的；视觉验收按 [[feedback-ui-workflow]]，采集与测量方法见 [[performance-diagnosis]]。查明崩溃原因后更新或移除对应限制，不把旧系统观察扩大为所有环境的保证。
