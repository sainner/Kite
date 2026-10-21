---
name: todo-attachments
description: 消息附件已实现，输入框那一行待验收、真机待测；harness 回合中途带图交给 Claude 的合成条目没测
metadata:
  node_type: memory
  type: todo
  originSessionId: 327f8327-65db-4295-8f38-f1be354c550e
  modified: 2026-10-21T10:47:59.641Z
---

**来源：** 2026-10-21 实现消息附件，方案在会话里与用户确认（附件默认不进 Git、原件随副本跨机、Line 转达带附件）。约定见 [会话显示协议 · 附件](../../docs/会话显示协议.md#附件)。

未决：

- 输入框上方待发附件那一行（DraftAttachmentStrip）的样子是先定的默认：缩略图高 56、圆角与玻璃同心、叉在右上角、上传中半透明盖住加进度、失败点一下重传。待用户在 Debug 预览里验收。
- Mac 上点气泡里的附件是取原件后用默认 App 打开，iPhone、iPad 是快速查看；Mac 要不要改成应用内预览，待用户定。
- iPhone、iPad 真机：回形针菜单的照片与文件、粘贴图片、经组网传大文件的速度与断线后重传、气泡里点开预览。
- 换后端时，harness 回合中途收下的带图输入会合成成 prompt 为内容块数组的 queued_command，CLI 认不认没测（回合开头的 user 条目、CLI 自己的排队插话已有测试）。认不了时切换会报翻译失败、不切换。
- DeepSeek 用户消息里的图片，见 [[todo-deepseek-validation]]。

**完成条件：** 用户确认输入框那一行和点开方式；真机跑通选照片、选文件、粘贴；中途带图的交接补测或实测过。
