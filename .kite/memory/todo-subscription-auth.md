---
name: todo-subscription-auth
description: 工作机 ChatGPT 凭据自动续期和安全存储待决定
metadata:
  type: todo
---

**状态：** 待评估；ChatGPT 自动刷新与系统钥匙串存储尚未接入。
**来源：** 订阅认证的当前能力边界与每台工作机独立授权的要求。

需要确定续期、失效反馈与存储方式，覆盖过期、刷新失败和重新登录；不能跨机器复制 refresh token。

**完成条件：** 确认最小方案并验证上述失败路径。授权入口以 [工作机说明](../../docs/kited.md#终端试用) 为准。
