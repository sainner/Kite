---
name: test-restraint
description: 按测试规则保持新增用例克制，PDF 转换使用手动冒烟
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4d836d54-7a98-4372-9a9f-69caa46f42ca
  modified: 2026-10-12T05:21:46.391Z
---

测试准入与预算只在 [测试规则](../../.claude/agents/test-writer.md) 维护。用户另有以下明确要求：

- 简单配置、默认路径传递和已由真实登录验证的接入，不因每次改动扩充测试；已有接口测试只做必要维护。
- 不用事件类型白名单断言限制可扩展事件流。
- macOS Vision 的 PDF 转换不加入自动测试，修改后用手动冒烟验证。
- 在研阶段不为随时可能变的界面需求写测试（2026-10-12 文本容器第三步：交给 test-writer 一个自动合同加两个手动场景，跑了半小时，用户质疑目的）。界面行为用一次性探针验证、交用户在 build 里验收；样式更不写。交 test-writer 之前先问：这条需求稳定吗？不测会漏掉什么真实风险？答不清就不交。

**Why:** 用户要求检查快速且有实际价值，避免普通参数传递、扩展事件或 Vision 冷启动拖累日常检查。
**How to apply:** 区分运行现有检查与新增测试。继续遵守项目检查要求；界面预览与纯样式任务按 [[feedback-ui-workflow]]。
