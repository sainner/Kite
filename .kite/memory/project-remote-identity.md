---
name: project-remote-identity
description: 项目以远程仓库为身份、无正式远程时由 Kite 托管的决定来由
metadata:
  node_type: memory
  type: decision
  originSessionId: 9bad5358-e33c-4177-8c83-882f8f71e62f
---

2026-10-06 用户重申项目以远程仓库为身份，而不是本机目录加独立 UUID；此前按目录登记、手动关联检出的实现偏离了最初设想。同日确认没有正式远程的文件夹先使用 Kite 托管远程。

**Why:** 只登记机器上的文件，能看到内容却做不了版本管理，不符合让 Git 在底下隐形工作的初衷；多机协作也依赖共享远程。托管让没有 Git 账号的用户也能开始，日常使用不应再区分一套托管流程。
**How to apply:** 项目、检出、迁移与集成的需求统一以 [项目与远程仓库](../../docs/项目与远程仓库.md) 为准，接口见 [托管账号与设备](../../docs/托管账号与设备.md#项目与-git-远程)。多机验收见 [[todo-remote-connections]]，工作区与线程关系见 [[session-worktree-decision]]。
