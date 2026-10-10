---
name: model-vendor-backend
description: 用户只选择模型，执行后端由模型厂商决定的产品取舍
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
---

2026-10-09 用户确定界面不暴露执行后端：Claude 模型经 Claude Code 订阅运行，其他厂商模型由自研 harness 执行。

**Why:** 在当前接入决定下，后端由模型厂商决定，再让用户选一次会增加多余概念。
**How to apply:** 模型选择与角色配置沿用这一边界；后端切换契约见 [会话后端与宿主边界](../../docs/kited.md#会话后端与宿主边界)。订阅入口与接入理由见 [[harness-direction]]、[[claude-integration-direction]]。
