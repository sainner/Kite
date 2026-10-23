---
name: feedback-no-install-state
description: 记忆里不写哪台机器装了哪一版、装没装上；版本以 /machine 实时读到的为准
metadata:
  type: feedback
---

不往记忆里写「本机已装协议 18」「这台 Mac mini 装上了协议 13」这类安装状态：哪台机器装了哪一版、哪个构建、装没装上。

**Why:** 2026-10-23 我在两条待办里写「本机已装协议 18」，用户说这种严禁往记忆里写。安装状态随每次安装、自动更新而变，记下来很快就错；它是当前会话的执行状态，不是跨会话的背景。
**How to apply:** 待办只写还要做的事（「待手测」「待真机验收」）。要知道某台机器跑的版本，读它的 `/machine`（`version.protocol`、`build`、`commit`）。代码的协议号以 `kited/src/version.ts` 为准，提交以 Git 为准，也不抄进记忆。
