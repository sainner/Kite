---
name: code-editor-direction
description: 代码文件编辑的选型：系统文本视图（NSTextView、UITextView，TextKit 2）加 tree-sitter 高亮，没选 CodeMirror、STTextView、Runestone 的理由
metadata:
  node_type: memory
  type: decision
  originSessionId: b0b2a4b3-2067-4e31-bb86-eb3c2199e2e4
  modified: 2026-10-23T10:32:24.092Z
---

2026-10-23 用户选定：浏览窗口里编辑代码文件用系统文本视图（Mac 是 NSTextView，iPhone、iPad 是 UITextView，都用 TextKit 2），语法高亮用 tree-sitter（官方 Swift 绑定 tree-sitter/swift-tree-sitter，BSD-3），行号挂在 TextKit 2 的可见区排版回调上（`NSTextViewportLayoutController` 的 delegate，两端 SDK 都有）。第一版只做编辑、高亮、行号和带冲突检查的保存，补全、折叠以后再说。同日用户定：点进原文直接改，没有编辑模式（我提过 iPhone 上点一下会弹键盘的代价）。

没选的：
- CodeMirror 6 放进网页视图：一份三端通用、功能最全，但和 [[decision-native-ui]] 的原生方向冲突，论坛有 iOS 上选区拖动手柄消失的报告（未查到是否修好）。
- STTextView：TextKit 2、两端都有实现、有 tree-sitter 插件，但许可是 GPL v3 或商业授权。
- Runestone：MIT、tree-sitter，但只做 iPhone、iPad，Mac 只能走 Catalyst 且作者说没做完，最后发版 2024-06。
- CodeEditSourceEditor 只有 Mac；SwiftUI TextEditor 没有行号、大文件带高亮慢。

**Why:** 在 Kite 里改代码多是小改，大段由 agent 写，中文输入法、选字、撤销、查找这些手感比功能多要紧，系统文本视图直接给了；对话正文已经是 TextKit 2 文本视图（[[text-container-direction]]），有经验。苹果工程师在开发者论坛（thread 832728）对 iOS 27 写代码编辑器也建议 UITextView 加 TextKit 2 可见区回调、高亮自己解析后写成属性。
**How to apply:** 做编辑器时按这个方向，不再引入网页编辑器。ChimeHQ/Neon 的作者写明它的 TextKit 2 集成没解决，不直接依赖它，高亮自己做一层薄的（tree-sitter 增量解析，只给可见范围上色）。
