---
name: feedback-preserve-ui-on-data-integration
description: 接真实数据时沿用已认可的界面，避免顺带重做外观
metadata:
  type: feedback
---

给现有 App 接真实数据时，沿用已认可的界面结构，优先替换数据来源与动作回调；空数据和连接状态也按既有结构表达。

**Why:** 用户曾指出接入后的 Mac 界面与此前完全不同；原有界面已花时间调整，接数据不构成重新设计外观的授权。
**How to apply:** 仅在用户另行确认界面方案时改变结构。不能用示例会话伪装真实数据，也不能把编译通过当作原有界面得到保留的依据。
