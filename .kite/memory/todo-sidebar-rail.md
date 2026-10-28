---
name: todo-sidebar-rail
description: 宽屏侧栏收起状态（2026-10-28 改成同一组件的过渡）没验过的部分：iPad、收起时点圆点和拖分离、Line 角标去留
metadata:
  node_type: memory
  type: todo
  originSessionId: 7e9e7ea3-2b65-4f7f-85c7-6c045620a6f1
  modified: 2026-10-28T06:43:44.241Z
---

来源：2026-10-28 会话里重做宽屏侧栏收起状态，用户在 Mac 预览上看过外观后让提交。

未解决：
- iPad 的收起侧栏没看过（图标列 44pt、收起宽 56pt），只编译通过。
- 收起时点树干上的圆点切工作区、按住圆点拖出去分离、⌃⌘ 数字提示、已分离的圆点变淡，都没手测。
- 收起时 Line 字标旁的收件箱角标直接隐藏，要不要挪到字标角上没定。
- 列表长到要滚动时只留一项展开：用户刚开始试用，规则可能再调。

完成条件：iPad 上看过收起与过渡，上面几项手测过或用户另有决定。性能重量记在 [[todo-window-motion-remaining]]。
