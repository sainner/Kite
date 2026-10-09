---
name: ui-transient-recording
description: 一闪而过的布局、动画、滚动问题怎么复现：Mac 录屏抽帧和几何日志，iPhone 真机日志回传，模拟器最小探针；注意别的会话也在用 Debug 预览
metadata:
  node_type: memory
  type: reference
  originSessionId: 5dea5a03-d5fb-48c8-985d-ce207e34761a
  modified: 2026-10-09T07:55:31.068Z
---

2026-10-09 排查卡片弹窗打开时内容先偏到左上角的问题时的做法，环境为 macOS 27：

- 终端有屏幕录制权限（没有辅助功能权限，见 [[ui-hit-testing-debugging]]）。`screencapture -x -v -V 秒数 -k 文件.mov` 能录屏，再用 `ffmpeg` 按时间段抽帧、裁剪，用 `tile` 滤镜拼成一张图来看，0.2 秒内的残影也能看清。
- 需要的界面由临时探针打开：Debug 版加一段由环境变量控制的代码，用 `open --env 变量=1 --stdout 日志 App路径` 启动，同时在 AppKit 视图里打印窗口和内容的 frame，对比关掉不同可疑逻辑时的画面。探针用完就删。
- 弹窗开着时用 AppleScript 退出 App 会报「用户已取消」，需要直接结束进程。
- 别的会话可能也在用同一份 Debug 产物预览；重启 Kite 会关掉别人刚打开的预览，结束后要正常重开一次，并告诉用户。

2026-10-09 排查展开工具行时对话没贴底的问题时补充：

- 滚动、对齐类问题在 `onScrollGeometryChange` 里逐帧打印内容高度、偏移和滚动位置，比录屏可靠。用户同时在用电脑时，录屏常拍不到 Kite 窗口，还会混进用户自己的滚动。
- 要复现的操作由探针在 App 内触发，例如用通知让最后一个工具组定时展开、收起，不依赖合成点击。工作区里的会话由用户决定，内容不满一屏时，可以在探针里给对话顶上加一段空白。
- 主工作区被别的会话改到编不过时，用 `git worktree` 基于 HEAD 加探针，指定单独的 `-derivedDataPath` 编译，并把 `app/Vendor` 下的 xcframework 软链过去；用完删掉工作树和编译产物。

2026-10-09 排查 iPhone 收起抽屉后越界滚动抽搐时补充：

- 真机日志：探针由环境变量开启，用 `xcrun devicectl device process launch --device <ID> --console --terminate-existing -e '{"变量":"1"}' <bundle id>` 启动，App 的 stdout 会实时传回本机。手机要解锁、App 要在前台，锁屏后连接就断了；日志里混着组网库的输出，写等待脚本时别用 “error” 之类的字样判断结束。
- 主工作区还有别的会话没提交的改动时，用 `git worktree` 建好以后再 `rsync` 当前的 `app/Kite/` 进去，复现的就是用户实际在用的代码。工程是文件夹同步分组，新增的探针文件不用改工程。
- 真机上要用户配合时，尽量让探针自动完成操作（例如用 `.task(id:)` 等窗口载入后再开合抽屉），只请用户打开对应界面。
- 关于 SwiftUI 本身的结论，用模拟器上的最小探针 App 来比（按 [[ui-hit-testing-debugging]] 的方式手写 Info.plist），一轮几十秒，不用登录。实测：滚动视图的内边距或尺寸哪怕只变 0.01pt，越界的位置也会被夹回边界；SwiftUI 的动画是叠加的，不带动画地改值打断不了正在进行的弹簧。

2026-10-10 截屏、录屏都报「could not create image」时补充（静态样式问题）：

- 在 Debug 探针里用 `ImageRenderer` 把要看的 SwiftUI 视图离屏渲染（`scale = 4`，环境对象要显式传进去），PNG 转 base64 写到 stderr，用 `open --env 变量=1 --stderr 日志 App路径 --args …` 启动后从日志里解出来，再用 `sips` 裁剪后看图。App 有沙盒，写不到会话临时目录，`~/Library/Containers/com.sainner.kite` 也读不到；`print` 到 stdout 是块缓冲，退出 App 后才写出。
- ScrollView 这类平台视图渲染不出来，要挑里面的部分单独渲染。这次靠它看出工具小头像被图标的排版尺寸撑宽，只看代码和日志里的格子尺寸都没发现。

**Why:** 这类问题截一张图抓不到，只看代码猜了几轮都没有结论，录屏抽帧加 frame 日志才定位到原因。
**How to apply:** 遇到「刚打开时」「动画过程中」才出现的界面问题，先录屏抽帧确认现象，再用探针逐个关掉可疑逻辑做对比；纯样式修改仍按 [[user-previews-ui]] 交给用户自己预览。
