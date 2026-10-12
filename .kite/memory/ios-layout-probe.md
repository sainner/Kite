---
name: ios-layout-probe
description: 不登录、不占用户手机，在 iOS 模拟器里量 iPhone 排版（视图实际宽度、截断）的做法
metadata:
  node_type: memory
  type: reference
  originSessionId: 29e9cfac-6fa3-4802-97cf-ca5316cfd76b
  modified: 2026-10-12T05:50:32.616Z
---

iOS App 要登录 Kite 账号和组网才进得去，模拟器里走不到资源库这类页面。量排版不必走完整流程（2026-10-12 查资源库窗口边距用过）：

- 数据从本机 kited 取：`curl -H "X-Kite-Machine: <id>" http://127.0.0.1:5483/roles`，机器 ID 由 `/machine` 给出，模板目录同理。
- DEBUG 构建临时加一个入口：`KiteApp` 的 iOS `WindowGroup` 里按环境变量换成探针视图，用 JSON 解出目录直接渲染生产视图，按 iPhone 的宽度（如 402）给 `.frame(width:)`，用 `onGeometryChange` 记实际宽度。模拟器 App 能读宿主路径，环境变量用 `SIMCTL_CHILD_` 前缀经 `simctl launch` 传入。
- 结果写进 App 的 `tmp`，用 `simctl get_app_container booted com.sainner.kite data` 取回；`simctl launch --stderr=<路径>` 没写出文件。单独 `-derivedDataPath`，测完删探针、还原入口、卸载模拟器里的 App。
- 量出的是布局数值；手感和最终效果仍由用户在真机验收。

**Why:** 这次靠它量出条件块最小宽度比正文列宽 18.8pt，一轮就定位，比看代码猜快得多。
**How to apply:** 窄屏布局对不齐、被撑宽、截断异常时先这样量；工作区有别的会话未提交的改动时按 [[performance-diagnosis]] 的说法放进 worktree。验收要求见 [[feedback-ui-workflow]]。
