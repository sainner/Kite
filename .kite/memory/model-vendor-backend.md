---
name: model-vendor-backend
description: 后端不在界面暴露；Claude 模型只走 Claude Code 订阅，其余模型走自研 harness，模型菜单用原生菜单按厂商分节
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
  modified: 2026-10-09T05:38:37.951Z
---

2026-10-09 用户确定：界面不暴露执行后端。Claude 受政策限制只能通过 Claude Code 订阅使用，因此选 Claude 模型即走 Claude Code；其他厂商的模型都由自研 harness 执行。模型切换菜单只按模型厂商分类，不再是「执行后端」。2026-10-10 用户决定模型菜单回到系统原生菜单，与「更多操作」外观一致：每个厂商一节、当前模型打勾，不再用自定义弹窗里的分段选择器。

**Why:** 后端由模型厂商唯一决定，让用户再选一次后端是多余的概念。原生菜单里放不进分段控件，为了分段改成弹窗后，与相邻的「更多操作」菜单外观不一致。
**How to apply:** 新会话草稿、会话内模型菜单和以后的角色配置里只出现模型（按厂商分组），后端由所选模型推出；跨厂商切换模型即切换后端，沿用现有切换后端的限制。订阅入口与 harness 方向见 [[harness-direction]]、[[claude-integration-direction]]。
