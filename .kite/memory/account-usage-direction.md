---
name: account-usage-direction
description: 账号用量统一采用本机记录的决定与原因
metadata:
  node_type: memory
  type: decision
  originSessionId: 7a7c5b4b-8f48-4b62-b45a-db1b8567f83a
---

2026-10-10 用户决定：账号用量只统计该账号在所属工作机上的记录，保留长期使用历史。

**Why:** 账号页归属于具体工作机；此前按天取上游整账号统计、按小时取本机记录，同一展示混入了两种范围。
**How to apply:** 增加账号或用量来源时保持本机范围，不混入供应商的整账号用量。此决定针对用量统计，订阅额度仍取上游；数据契约见 [模型账号与额度](../../docs/kited.md#模型账号与额度)。
