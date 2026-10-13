---
name: ios-layout-probe
description: 不登录，在真机上量 iPhone、iPad 排版、和旧版截图对照的做法（模拟器不再用）
metadata:
  node_type: memory
  type: reference
  originSessionId: 29e9cfac-6fa3-4802-97cf-ca5316cfd76b
---

iOS App 要登录 Kite 账号和组网才进得去，量排版不必走完整流程。模拟器不再用（见 [[ui-hit-testing-debugging]]），改在真机上做（iOS 对话改原生时这样对过旧版）：

- 数据从本机 kited 取：`curl -H "X-Kite-Machine: <id>" http://127.0.0.1:5483/roles` 这类接口，机器 ID 由 `/machine` 给出；会话记录是 `/events?thread=<id>` 第一帧的 `thread.history`。缺的种类（代码块、长消息、压缩分界等）往记录里补。
- DEBUG 构建临时加一个探针视图，由 App 参数开（`-probeMode …`，`KiteApp` 里按 `UserDefaults` 换掉 `AppRoot`），平常启动照常是 App。编译条件用 `OTHER_SWIFT_FLAGS` 传，探针文件不入库。会话记录解成 `RemoteEvent`、threadId 换成草稿 `WorkThread` 的 id 后 `apply`，直接渲染生产视图；按宽度给 `.frame(width:)`，用 `onGeometryChange` 记实际尺寸。
- 截图在 App 里画：`window.drawHierarchy(in:afterScreenUpdates: true)` 存 PNG 到 `Library/Caches`，探针跑完自己退出，下一次启动是新进程。
- 夹具和结果用 `devicectl` 放进、取回 App 的缓存目录（取回的命令见 `app/README.md`），放进去时目的地要写到文件名，写目录会失败。`launch` 的 App 参数放 `--` 后面，并带 `--terminate-existing`：App 已在跑时不带它参数不生效，探针不跑，取回的是上一次的结果（看文件时间）。新设备第一次装报描述文件不含它时，用 `-destination id=<设备> -allowProvisioningUpdates -allowProvisioningDeviceRegistration` 编一次。
- 和旧版对照：在 `git worktree add --detach` 出来的旧提交上加同一个探针编一份，两份先后装同一台设备、同样的参数跑，截图对比，只改看得出的差别（间距、颜色、字号、位置），1pt 以内的取整、基线、抗锯齿差不追——用户 2026-10-14 纠正过：外观一样不等于逐像素一致；对不上时让探针导出文本视图的 frame、视口、附件的显隐这类数值，比猜快。
- 为性能改了排版机制（视口、容器、按需排）以后要重跑截屏对照：拖缝测量看不出漏画，2026-10-13 一处正文只排第一段就是截屏才发现的。
- 量出的是布局数值和像素；手感和最终效果仍由用户在真机验收。

**Why:** 2026-10-12 查资源库窗口边距时这样量出条件块最小宽度比正文列宽 18.8pt，一轮就定位；2026-10-13 iOS 原生对话靠它把行高取整、Label 布局、中文断行、附件显隐逐项对齐到和旧版一样。
**How to apply:** 窄屏布局对不齐、被撑宽、截断异常，或换实现要对照旧版外观时这样做；工作区有别的会话未提交的改动时放进 worktree（见 [[performance-diagnosis]]）。测完删探针、还原入口。验收要求见 [[feedback-ui-workflow]]。
