---
name: credential-service-direction
description: Git 授权与共享密钥归入资源库的凭据，随 Kite 账号分发，由宿主按引用注入而不进入上下文
metadata:
  node_type: memory
  type: decision
  originSessionId: 9bad5358-e33c-4177-8c83-882f8f71e62f
  modified: 2026-10-06T14:06:43.089Z
---

2026-10-06 用户决定提供凭据分发服务：Git 凭据和 Kite 账号绑定，由服务分发给各工作机，不由每台工作机各自配置。

同一服务还用来增强 harness：agent 在 shell 命令中使用 `{project.ssh_key}` 这类凭据引用时，由宿主在执行时解出并使用，凭据本身不进入模型上下文。

2026-10-08 用户进一步明确：Git 授权与共享密钥统一归入「资源库 → 凭据」，原「关联账号」入口移出设置；Kite 账号留在设置，模型订阅与 API 账号及额度归到设备下的「账号」子页（同日后续确认，导航层级见 [[sidebar-navigation]]）。接入额度数据不改变模型凭据的分发边界。

**Why:** Git 凭据配置繁琐，工作机一多就更麻烦；agent 需要用到凭据时，也不应让密钥出现在对话里。
**How to apply:** 设计 Git 远程访问、托管远程与工作机接入时，凭据从账号侧获取。该服务改变了 [托管账号与设备](../../docs/托管账号与设备.md) 中托管侧不保存凭据的边界；模型供应商凭据暂时保持每台工作机各自登录。需求与待定事项见 [项目与远程仓库](../../docs/项目与远程仓库.md#凭据)；项目身份见 [[project-remote-identity]]，执行边界见 [[sandbox-execution-direction]]。
