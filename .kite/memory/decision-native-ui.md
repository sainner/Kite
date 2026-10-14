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

同日用户定的细节（按编排者建议）：Mac 标题栏不原生化；状态圆环、停靠栏脉冲改图层动画后跟屏幕刷新率（比现在的 30 帧顺）；窗口动画交给 Core Animation（外壳第四期）。iOS 原生版不照搬 SwiftUI 版的副作用：长按气泡任何地方（含内边距、折叠按钮）都开操作栏，压缩分界展开时下面的行跟着展开动画走，点状态栏回顶按系统惯例做好，气泡浮起途中不能选字（同 Mac）；滚动收不收键盘照 iOS 现版；读屏补齐在 iOS 第 1 期之后马上做、两端一起；iPad 指针右键开操作栏顺带做；iPhone 文本容器第三步的真机验收并入 iOS 第 1 期手测。

**Why:** 拖缝 60 帧的预算是 16.7ms。SwiftUI 每帧整棵树重算：托管的 SwiftUI 行改宽约 0.8ms 一行，外壳两窗约 9.4ms；对话原生化以后剩下的大头就是外壳（数据见 [[todo-window-motion-remaining]]）。参照 TelegramSwift：全 AppKit、每条消息一个自绘图层、改宽只同步重算可见行；它的 CoreText 贪心断行只比 TextKit 2 快约 30%，优势主要在没有 SwiftUI 外壳和每行文本视图的开销。宽屏 iPad 和 Mac 用同一套分栏、也能拖缝，对话仍是 SwiftUI；2026-10-13 真机（iPad Pro 12.9 第 5 代）拖缝每步 166～317ms，每次改宽 SwiftUI 把整列行重量一遍，气泡 boundingRect 贴字宽约占 2/3。用户知道代价：按周计，Mac、iOS 视图层各一份（只共用排列和量高的计算），交互和动画有回归风险。

**How to apply:** 动对话列表、行视图、窗口外壳或拖缝性能时按这个方向。2026-10-14 两端改完，旧的 SwiftUI 对话、台面、iOS 紧凑外壳和新旧对照的 Debug 开关已删，外观以现在的原生版为准；要和旧实现比，在旧提交的 worktree 上编（见 [[ios-layout-probe]]），旧版不一定对，副作用不照搬（如气泡正文被量两遍、字没排满气泡，用户认可原生版排满）。Mac 的窄窗口（紧凑布局）仍是 SwiftUI 版（`MacCompactLayout`、`ThreadPane`、`ThreadControls`），对话是原生列表。滚动规则两端一份，写在 `TranscriptListView`、`PhoneTranscriptView` 开头，状态在 `TranscriptFollow`（原 SwiftUI 版的 `TranscriptScroll` 已删）。每步用测量版量过再往下走，iPad 在真机上量：测量入口是 `kited/test/manual/measure-perf.ts`（App 里的部分在 `app/Kite/Verification/PerfProbe.swift`，只编进测量版），用法见 `kited/test/manual/README.md` 的「性能测量」。
