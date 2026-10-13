---
name: feedback-orchestration
description: 多 agent 并行时用 Workflow 直接编排、运行中不插话、对照设收敛门槛，审完合进主线
metadata:
  node_type: memory
  type: feedback
  originSessionId: 86ee9d1e-e61e-49dd-92f1-c57d827b5ac1
  modified: 2026-10-13T09:56:24.467Z
---

用户要并行推进大块工作时用 Workflow（/config 里已打开）编排，2026-10-13 说「以后直接编排就行」：拆好就直接跑，不逐项请示编排细节；产品取舍照样先问。

- 运行中不要给 workflow 里的 agent 发 SendMessage：消息会把它从 workflow 里接走，结果直接回主会话，workflow 的记录停在「进行中」、后面的审查阶段不再启动（2026-10-13 这样卡死过一次）。要改方向就停掉 workflow，改脚本后重跑或用 resumeFromRunId。
- 逐像素对照要有收敛门槛：差异小到肉眼看不出就列进汇报交用户看，不要反复微调。2026-10-13 输入区原生化的 agent 在玻璃和输入框对照上磨了约一小时，用户看过对照过程「几乎没有差异」，直接要求收尾。
- 一轮做完先独立审查，再合进主线（用户：「先把改动收入主树（或者review）」）；没做完、没手测的分支先不合。

**Why:** 用户要的是持续推进，不想在编排细节和过度验证上耗时间；中途插话还会把编排本身弄坏。
**How to apply:** 大任务按「workflow 实现 → workflow 审查 → 编排者测量 → 用户手测 → 合并」走，每个 workflow 只管一段，主会话在两段之间看结果、定下一步。agent 的提示里写明对照的门槛和收尾条件。协作的其他要求见 [[feedback-ui-workflow]]。
