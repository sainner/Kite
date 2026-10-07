---
name: pdf-read-direction
description: PDF 转 Markdown 选用 macOS Vision，不用 Docling 或 pdf.js，也不为其他系统保留兜底
metadata:
  type: decision
---

2026-10-07 用户在对比后选定 macOS Vision 文档识别作为 read 的 PDF 转换，并明确不需要兜底解析器；不支持 Vision 的机器直接报错。

对比时的观察：pdf2md（pdf.js 文本层启发式）处理中文 PDF 时把正文全标成标题，表格散开，扫描件没有文字；Pigeon 用过的 Docling 准确度最好，但需要 1.6 GB 的 Python、torch 和模型运行库，内存约 2 GB，每页数秒；Vision 预热后每页约 0.3 秒，结构接近 Docling，扫描件 OCR 偶有错字。这些只是少量样本在 Apple Silicon 上的观察，不是质量保证。

**Why:** 用户要的是好用的 Markdown 和分页查询，同时不想背重型运行库；Kite 工作机以 Mac 为主。
**How to apply:** 改进 PDF 转换时在 Vision 结果上调整，不重新引入 pdf.js 或 Docling，除非用户改变决定。扫描页的标题判定和 OCR 准确度仍待真实文档验证。实现与限制见 [harness 主循环](../../docs/harness-主循环.md#read)。
