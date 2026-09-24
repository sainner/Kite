---
name: fake-data-exhaustive
description: Kite App 先用假数据做界面时，假数据要穷举各种情况（每种工具、成功/出错/后台/子 agent 等）
metadata:
  node_type: memory
  type: feedback
  originSessionId: eef6c087-5039-44b4-b7ef-20f7db11d385
  modified: 2026-09-24T05:41:11.170Z
---

做 Kite App 的界面、还没接 kited 时，用户选「先用假数据做界面」，并补充要求假数据**穷举**各种情况：会话窗口那一步是把 Kite 会话里有的每种工具都调一遍（kited/README.md「会话的上下文」列的工具，加项目自己的 MCP），成功、出错、后台、子 agent、打断、没跑完都要有。

**Why:** 界面要在接真实数据之前就把每种情况的样子定下来，漏掉的情况接上 kited 后才暴露。

**How to apply:** 以后做文件、终端、预览等窗口，假数据先列全这个窗口会遇到的所有情况（含出错和边角），参数和结果照上游的真实格式写（工具参数见 SDK 的 sdk-tools.d.ts）。现成的例子是 app/Kite/SampleTranscripts.swift。
