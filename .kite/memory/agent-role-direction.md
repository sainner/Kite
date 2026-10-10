---
name: agent-role-direction
description: 角色合并提示词与能力配置的决定来由；分层与生效契约见 docs
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
---

2026-10-09 用户决定将「代理」「只读审查」「Claude」三个 agent 定义合并为一个代理插件：工作方式由角色表达，Claude 归入模型厂商选择。

**Why:** 原先提示词在模板、工具上限在定义、实际值在实例配置，用户选了「只读审查」模板仍可能带着 shell；角色需要同时表达工作方式与能力边界。
**How to apply:** 角色内容、工具逐层约束、必需工具与生效规则统一见 [角色与代理配置](../../docs/Agent与插件契约.md#32-角色与代理配置)，不在记忆另存算法。用户可见名称区分「代理」「代理窗口」与作为对话记录的「会话」。验收和开场白未决项见 [[todo-agent-roles]]，模型厂商的取舍见 [[model-vendor-backend]]。
