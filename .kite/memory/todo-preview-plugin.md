---
name: todo-preview-plugin
description: 预览插件第一步（网页移出终端、工作机浏览器、模拟器、agent 的 preview_* 工具）已实现待手测；Firefox 在 macOS 27 起不来；Safari、Mac App 窗口与分发包未做；逐帧界面细节与参照
metadata:
  node_type: memory
  type: todo
  originSessionId: 1fd0107c-f8bf-4003-bdfa-77630176dfbc
  modified: 2026-10-22T02:41:26.614Z
---

**来源：** 2026-10-21 讨论终端的预置脚本时延伸出来，用户决定做；设计在 [成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览)，接口在 [实例操作 · 预览](../../docs/实例操作.md#预览)。2026-10-22 用户说「完成三段」，第一步三段一起实现：网页从终端移进 kite.preview（终端去掉 web 视图与 terminal.select，协议号 11）、工作机上的浏览器（Playwright）与 agent 的 preview_* 工具、模拟器。

**实现时自己定的（用户还没确认，汇报时提过）：** 预览 lifetime 是 window，agent 开的没有窗口、随它归档回收；agent 操作 device 的预览时用工作机浏览器另开（原定 WebKit，因守不住代理边界改用 Chromium，见下）；preview_action 一个函数工具照 Anthropic computer use 的动作名，不接厂商自带的 computer use；网页视口跟着最近操作的设备窗口；网页上拖动换成滚动；工作机浏览器经每个预览一个的出口代理连出去（Playwright 的 route 拦不住跳转，测试抓到过）；动作后画面一直没变的等满 1 秒才算稳定（模拟器点开设置约 1.2 秒才出第一帧）；模拟器只给脚本里写到 KITE_SIMULATOR 的建，名字「Kite 工作区名」建在默认设备集，闲置 30 分钟关机，工作机本机默认实时画面。

**待手测：** Mac、iPhone、iPad 上新建网页预览（选端口、换浏览器）、消息里 localhost 链接打开预览、终端标题栏的「打开网页」；工作机浏览器的画面、逐帧与实时、点按与滚动、输入文字、Mac 直接打字；agent 开的预览出现在停靠栏、点开能看它在做什么、关闭预览；模拟器预览与预置脚本装 App。只有新建的代理有 preview_* 工具（同 terminal_run）。

**已知问题：** 模拟器的系统语言跟工作机（这台是简体中文、拼音输入法），没点输入框时按键逐字敲会进入拼音组字，组字中途无障碍写值也写不进去；改 .GlobalPreferences 的 AppleKeyboards 与 com.apple.keyboard.preferences 的 KeyboardsCurrentAndNext 再启动都没用（2026-10-22 实测），没再查。冷启动模拟器约 28 秒，开着约 3GB 内存、目录几 GB（见 spikes/simulator-io）。Playwright 的 Firefox（firefox-1555）在这台 macOS 27.2 上直接运行也报 Could not find profile folder，起不来，等上游。WebKit（webkit-2370）在 Mac 上跟随到本机地址的跳转、页面的第一次导航不走上下文代理，直连本机任意端口（页面自己发的 fetch、iframe、跳转、表单走代理），网络进程是系统拉起的 XPC 服务、套不上沙箱，2026-10-22 起不提供；设计文档原写 agent 用 WebKit 求内核一致，要不要改设计待用户定。浏览器第一次用时下载到 ~/Library/Caches/ms-playwright（约几百 MB），磁盘紧时注意 [[disk-space]]。

**候选改进（2026-10-22 /simplify 审查提出，未定）：** 动作后等满 1 秒（quietMs）是对所有画面统一的定时，候选改为各画面自己判断有没有新帧（模拟器看 kite-sim 的帧计数，网页看导航信号）。

**没做：** Safari（safaridriver）、Mac App 的窗口、分发包与装到设备；模拟器的多机型选择。

docs 不收、实现时照做了的界面细节（讨论时已认可）：逐帧模式在画面上标出刚点的位置，等待稳定时显示等待中；默认只发稳定后一帧，想看动画切实时画面；拖动、滑动在松手时作为一个动作发出，长按、捏合另给按钮。

**参照：** Claude Code 桌面版的 iOS 模拟器面板（2026-07 公测，文档 https://code.claude.com/docs/en/desktop-ios-simulator）。

**完成条件：** 用户在 Mac、iPhone、iPad 上手测通过，Safari 与 Mac App 窗口另立待办或做完后删掉本条。
