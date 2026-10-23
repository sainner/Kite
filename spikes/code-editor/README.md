# 代码编辑器上色验证（2026-10-23）

验证系统文本视图（TextKit 2）加 tree-sitter 的上色跟不跟得上打字、画没画错、各步多久。结论见 [代码编辑器上色验证](../../docs/research/2026-10-23-代码编辑器上色验证.md)。

探针要编进 App 里跑，用的是当时 `app/Kite/Editor/` 的编辑器；编辑器以后改了，要在当时的提交上复现。

```sh
cp spikes/code-editor/EditorProbe.swift app/Kite/Verification/
git apply spikes/code-editor/KiteApp-hook.diff     # 带 -editorProbe 启动时只显示编辑器
spikes/code-editor/run-mac.sh normal               # 或 big；报告打到终端
spikes/code-editor/run-ios.sh <设备 ID> big -editorProbeCheck NO
```

- 两端都编开了优化的 Debug 版（`-O`、`-Os`、整模块），产物在 `/tmp/kite-code-editor-spike/`（`SPIKE_OUT` 可改）。iOS 装进去的 Debug 版会替换设备上的 Kite。
- `normal` 是一段有代表性的 Swift（中文注释、字符串、闭包）接成约 1000 行，`big` 接成约 2 MB；由探针自己生成，两端都是沙盒 App，不往里放文件。
- 默认在每一段画出来的那一刻核对字色（换掉排版管理器的代理，各段换成核对用的片段）；`-editorProbeCheck NO` 只计时，iOS 上不换 UITextView 自己的排版代理。
- 报告写进 App 的缓存目录 `editor-probe-<normal|big>.txt`，Mac 上同时打到终端，iOS 由脚本取回。
- 跑完把 `EditorProbe.swift` 删掉、`git apply -R` 还原入口。
