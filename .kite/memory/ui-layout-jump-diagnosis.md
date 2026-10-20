---
name: ui-layout-jump-diagnosis
description: 弹窗或窗口尺寸突变、内容被裁怎么查：启动参数让预览自己打开、日志打各段高度或沿视图链打裁剪，自己量；常见原因是初始状态在 onAppear 里才定、外层蒙版裁边
metadata:
  node_type: memory
  type: context
  originSessionId: 5062538f-26bf-4ce9-9a1e-8b44d40a4fcc
  modified: 2026-10-20T06:44:13.235Z
---

2026-10-18 新建工作区弹窗在 Mac 上打开时高度跳一下，量一轮就找到原因并修好（该弹窗随后按用户要求整个去掉）。经验：

- 先量后改：临时加启动参数让 Debug 预览自己打开弹窗（`preview-mac.sh --参数` 原样传给 App），用 `Logger(subsystem: "kite.probe")` 打出各段高度的变化和窗口实际的 resize，再用 `/usr/bin/log show --predicate 'subsystem == "kite.probe"'` 读回。zsh 的 `log` 是内建命令，不写全路径什么都读不到。量完删掉探针。
- 当时的原因：默认的项目和工作机在 `onAppear` 里才选上。弹窗已按没选时的内容量过高度、窗口照它打开，选上后多出一行提示，约 0.35 秒后 `CardSheetWindowSize` 把窗口改高。规则已写进 `CardSheet` 的说明：按内容定高的弹窗，影响排版的初始状态在 init 里定。
- 当时预览里开着弹窗，`preview-mac.sh` 请旧实例正常退出没成功；用户关掉弹窗后才退出。是否每次都会被弹窗挡住未核实。

- 2026-10-19 停靠栏展开的面板右边被裁：凭猜测改了两轮（滚动区、台面视图往右多排）都没好。在台面视图的排版里打一条日志，沿 superview 往上列出每层的类型、frame、clipsToBounds、layer.masksToBounds，一次读出裁的是 SwiftUI 为 PaneFade 的 mask 包的 `_NSGraphicsView`（按内容区大小、开着裁剪）。SwiftUI 里挂 mask、clipShape 的祖先会这样裁掉原生视图伸出去的部分。

- 2026-10-19 iPhone 底栏家族格展开、收起时闪、抖、抽：在 Mac 和停靠栏预览里量排版数值宣称修好了好几轮，用户每次说「仍然」。最后在真机上取证一轮一个准：临时探针在 App 里每帧 `window.drawHierarchy(in:afterScreenUpdates: false)` 截底栏那一条、拼成一张长图存进 Library/Caches，同时把排版数值、UIScrollView 的 contentOffset 写进文本，`devicectl device copy from` 取回，`sips --cropOffset` 裁出几帧看。用户自己的工作区里才复现时，探针改成被动：挂在点开、收起的入口上，用户点一次就截 1.3 秒。查出的三样都是 SwiftUI 在这里的实际行为：过渡的修饰里改的环境值传不到内容，靠过渡改环境值的「展开动画」两头之间什么也没有；动画中每帧引起的重排不带动画，靠排版动画过渡的值（挤的程度、离右端的距离）第一帧就到终点，要做成 Layout 的 animatableData；iPhone 的 UIScrollView 每次重排都按锚点把位置拉回去，和滚动动画轮流生效，来回抖。

- 2026-10-19 两处位置不对，各量一两轮就定位，凭读代码和独立小程序都没找到：表格首列贴边，日志打出文本视图的 `textContainerOrigin` 是 -5（容器无限宽时 AppKit 按排出的范围推原点）；拖缝后回复下面多一截空白，每段打出 `layoutFragmentFrame` 的 y 和高，对比量高时和稍后显示时，一眼看出五段各多空 16 pt。TextKit 的位置问题直接打片段坐标对比，比推机制快。日志一行太长会被 `<…>` 截掉，列表要分行打。
- 2026-10-20 工具行扫掠偶尔缺字（用户说"正常对话时"）：探针在 CA 提交（run loop observer 次序 2000000）之后挂一个 observer，逐帧把扫掠记下的图和现在重画的逐像素比，对不上时截自己的窗口；再在本地按对话节奏往会话里喂工具调用（不经工作机，喂完还原）。一轮查出 `cacheDisplay` 画出来的图带着图层上挂的 mask，扫掠途中重拍就把遮罩挖掉的那一截记进图里。逐帧画面错位用这种"提交后核对"的探针，比截图找快。
- 清探针按块删，不要 `git checkout` 整个文件：主检出里常有别的会话同时在改（同日清探针时才发现另一个会话改了二十来个文件）。

**Why:** 用户要求记下这次修 bug 的经验；凭猜测改样式容易多轮无效。
**How to apply:** 窗口、弹窗、卡片的尺寸跳动、闪动或被裁，先照此量出是哪一段、哪一步变的，再改根因；诊断不靠猜，同 [[feedback-ui-workflow]]。
