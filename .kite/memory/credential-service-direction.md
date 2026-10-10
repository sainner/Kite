---
name: credential-service-direction
description: 凭据随账号分发、按类型取用且不进入模型上下文的决定来由
metadata:
  node_type: memory
  type: decision
  originSessionId: 9bad5358-e33c-4177-8c83-882f8f71e62f
---

2026-10-06 用户决定将 Git 凭据绑定 Kite 账号，统一分发给工作机，并允许 agent 用引用请求宿主在执行时使用共享密钥。2026-10-09 进一步确定凭据按共享密钥、Git、模型 API 分类，可见范围独立于取用方式。

**Why:** 多台工作机分别配置 Git 凭据繁琐；agent 需要使用密钥，但不应让密钥进入对话。
**How to apply:** 凭据的归属、取用方和管理接口以 [凭据服务](../../docs/托管账号与设备.md#凭据服务) 为准，命令引用以 [shell 契约](../../docs/harness-主循环.md#shell) 为准。订阅登录仍由各工作机独立完成，不能把 API Key 分发推广为同步订阅 refresh token。导航归属见 [[sidebar-navigation]]。
