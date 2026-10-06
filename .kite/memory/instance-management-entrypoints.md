---
name: instance-management-entrypoints
description: 定义在设置中管理，添加只创建实例，无窗口的存续实例仍可找到
metadata:
  type: decision
---

2026-10-01 用户确定：插件定义在设置中管理；工作区添加弹窗只创建实例，有视图时自动打开。仍然存在的无窗口实例也要有侧栏入口，普通点击打开视图，右键或长按进入实例设置与授权。

**Why:** 用户选择把定义管理、创建和已有实例管理分开；后台实例不能因为没有窗口而无法找到。
**How to apply:** 沿用 Mac 右栏与 iPhone 底部入口，具体形状和布局查 [App 说明](../../docs/App.md)。本条不要求关闭窗口后保留所有实例，回收依据 [[plugin-instance-lifetime]]。
