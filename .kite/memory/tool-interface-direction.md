---
name: tool-interface-direction
description: 短工具名与统一读写入口，版本变化仅提示，抽象调用才填写用途
metadata:
  type: decision
---

用户决定使用简短的 read、patch、shell：read 后续承载不同文件类型，patch 合并创建、修改与删除，补丁解析优先复用上游。

用户明确文件未读或整文件版本变化只提示，不拒绝仍能匹配当前内容的有效补丁；修改和删除都不额外加读后版本锁。补丁匹配失败、目录越界、新建覆盖已有文件仍是错误。

**Why:** 整文件版本锁会误拒绝互不重叠的局部修改。短工具名减少入口分散；shell 等抽象工具还需要告诉用户这次调用的用途。
**How to apply:** patch 与 write/edit 是表达方式，一致性策略是另一维度，不能从名称推断保障。抽象工具由 agent 填写简短 description，不指定语言；可由参数生成摘要的工具不重复要求。统一 read 入口不等于已支持多模态，需同时核对结果与模型适配。实现细节查 [harness 主循环](../../docs/harness-主循环.md)，持久观察设想见 [[context-observation-ledger]]。
