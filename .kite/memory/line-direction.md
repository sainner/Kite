---
name: line-direction
description: 个人 agent Line 与工作区流转方案的状态入口：契约已写成、未批准编码、未实现；决定理由与待验证项
metadata:
  type: decision
---

方案正文是 [Line 与工作区流转](../../docs/Line与工作区流转.md)，2026-10-12 写成可评审契约，尚未批准编码，尚未实现。

本次确认的决定：流转材料推到项目自己的远程 `refs/kite/*`，包括用户自有的 GitHub/GitLab 远程，不建托管 sidecar；工作区身份与执行权 lease 锚在仓库 ref，不在账号服务加表；目标侧不区分代理与用户，权限只在 Line 所在机器检查；Line 住托管项目的根工作区，由宿主提交现场；monitor 默认订阅账号全部工作区，暂不做开关。

**Why:** 材料随仓库走最省事，且利于多账号协作：公司里一人一个 Kite 账号，有仓库权限就能恢复别人的会话。目标侧身份只是调用方 kited 的声明，可信度等于设备，第二道门挡不住新东西。显式订阅没有解决协作问题，只是多一个要记得做的动作。
**How to apply:** 细化或实施前读契约；实施后把契约状态改为已实现范围，并替换契约末尾列出的现行文档冲突陈述。待验证：跨账号的加密推理与思考签名、平台对自定义 ref 的接受、Claude 记录改写 cwd、材料大小。相关未决见 [[todo-workspace-collaboration]]、[[todo-event-sources]]。
