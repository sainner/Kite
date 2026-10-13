---
name: decision-native-ui
description: 界面改原生的决定：Mac 对话与窗口外壳改 AppKit，iPhone、iPad 的对话与外壳改 UIKit，为拖缝 60 帧；外观逐项复刻，旧版的副作用不照搬
metadata:
  node_type: memory
  type: decision
  originSessionId: 7bb37716-307f-4af6-83d0-94e9d1bf5954
  modified: 2026-10-13T08:17:46.831Z
---

2026-10-13 用户先选定：Mac 主对话的列表和各种行（正文、人发的气泡、工具行、思考、事件、压缩分界等）改写成原生 AppKit 视图，外观逐项复刻现状，在分支 `claude/mac-native-transcript` 上做；同日说拖动时对话不必保持贴底。第四期后 Mac 拖缝每步仍约 20ms（30 帧），其中 SwiftUI 窗口外壳固定约 9.4ms；在「两窗隔一帧轮流重排」「拖缝时换骨架或点阵」「重写外壳」三条里，用户倾向重写：Mac 的窗口外壳（画板、窗口卡片、标题栏、输入区等）也改 AppKit，iPhone、iPad 的对话和外壳改 UIKit（两端共用一份），并行推进。骨架、点阵是用户给的退路（「如果实在不行」）。

**Why:** 拖缝 60 帧的预算是 16.7ms。SwiftUI 每帧整棵树重算：托管的 SwiftUI 行改宽约 0.8ms 一行，外壳两窗约 9.4ms；对话原生化以后剩下的大头就是外壳（数据见 [[todo-window-motion-remaining]]）。参照 TelegramSwift：全 AppKit、每条消息一个自绘图层、改宽只同步重算可见行；它的 CoreText 贪心断行只比 TextKit 2 快约 30%，优势主要在没有 SwiftUI 外壳和每行文本视图的开销。宽屏 iPad 和 Mac 用同一套分栏、也能拖缝，对话仍是 SwiftUI，真机没量过。用户知道代价：按周计，Mac、iOS 视图层各一份（只共用排列和量高的计算），交互和动画有回归风险。

**How to apply:** 动对话列表、行视图、窗口外壳或拖缝性能时按这个方向。外观以现有 SwiftUI 版逐项对照（[[feedback-ui-workflow]]），但旧版不一定对：先判断差异是有意设计还是 SwiftUI 带出来的副作用，副作用不照搬（如气泡正文被量两遍、字没排满气泡，用户认可原生版排满）。滚动行为以 `TranscriptScroll` 现有规则为准逐条迁移。每步用测量版量过再往下走；iPad 先在真机上量拖缝再定改多少。
