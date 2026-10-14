---
name: feedback-pane-status-placement
description: 窗口正文不放按系统条件出现的状态（未登录、读取中、暂不可查询等），状态归标题栏的信息区或副行
metadata:
  node_type: memory
  type: feedback
  originSessionId: 3c83083e-703a-408f-924f-3bc5faa5a2d0
  modified: 2026-10-14T10:39:22.372Z
---

窗口的正文（内容区）只放内容，不放按系统条件出现的状态：未登录、需重新授权、正在读取、尚未取得数据、没有连接的工作机、服务的说明这类。状态归标题栏：图形信息区（`PaneNotice` 的图标盖住圆环，悬停、长按看文字）或次级信息区（副行）。2026-10-14 用户看到账号窗口正文里还显示「未登录」，指出这是早有的定义。

列表窗口里每一项自己的状态（API 窗口每个 Key 一行的状态点和说明）是这一项的属性，仍跟着那一行；标题栏只代表整个窗口。

**Why:** 用户把正文与标题栏的职责分开定义，状态集中在标题栏才一致可找。
**How to apply:** 新做或改窗口时，按条件出现的状态一律走 `PaneWindow` 的 `notice` 或 `PaneHeader` 的副行，不在正文里写提示块。参照账号窗口（`ModelAccountPane` 的 `pending`、`notice`）。
