---
name: pdf-read-direction
description: PDF 读取采用 macOS Vision，不引入备用解析器
metadata:
  type: decision
---

用户选择 macOS Vision 将 PDF 转为 Markdown，并明确不保留备用解析器；不支持的工作机直接报错。

**Why:** 用户需要分页读取和结构化正文，同时不希望承担重型 Python、模型和运行库依赖，工作机以 Mac 为主。
**How to apply:** 在 Vision 结果上改进，不自行引入 pdf.js、Docling 或其他兜底。扫描件的 OCR 和标题识别需以真实文档验证；现行调用与系统限制见 [read 契约](../../docs/harness-主循环.md#read)，验证方式见 [[test-restraint]]。
