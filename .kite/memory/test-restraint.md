---
name: test-restraint
description: 简单配置与接入不扩充测试，跑检查与新增测试分开判断
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0cf825d0-56e8-45bc-967e-d772cc55f877
  modified: 2026-10-08T11:19:39.115Z
---

简单配置、默认路径传递和已由真实登录验证的接入，不为每次改动补测试；已有测试因接口变化必须维护时只做最小调整。

2026-10-08 额度改为随目录事件流推送时，旧测试里“目录流只出现这几种事件”的白名单断言因新增事件失败；用户认为这类断言没有意义，要求直接删除，而不是把新类型补进白名单。

2026-10-07 用户要求 read 的 PDF 转换（kite-pdf，依赖 macOS Vision）不加测试：Vision 冷启动约半分钟，拖慢检查。改动后用手动冒烟验证。

**Why:** 用户在设备登录接入时明确反馈“别写大量 test”“这个就不用写 test 了吧，要克制”；PDF 转换时又说“不要给它加测试，拖慢时间”。
**How to apply:** 按 [测试规则](../../.claude/agents/test-writer.md) 判断是否必须运行才能验证，不把普通参数传递包装成复杂行为。遵守项目已有检查要求，但不把跑检查与扩充测试混为一谈；纯样式预览的用户约定见 [[user-previews-ui]]。
