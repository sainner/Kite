# iPhone、iPad 原生对话的三项技术验证（第 0 期）

2026-10-13，Xcode 27.2（27B5028f），iOS 模拟器 27.2：V1、V2 在 iPad Pro 11-inch (M5)，V3 在 iPhone Air。设计稿见编排工作树的 `.orchestra/ios-transcript-design.md` §5（V1～V3），这里只记当时的问题、做法和结果。

## 问题

- V1：关了滚动的 `UITextView`（TextKit 2）放进外层 `UIScrollView`、只露出一截时，它自己排版排多少；改宽以后呢。Mac 靠覆写 `visibleRect` 让 `NSTextView` 只排露出来那截，拖缝时长回复才不用整段重排。
- V2：SwiftUI 只在渲染时做的几何效果（紧凑布局开合、iPad 卡片飞行、控制区横滑）套在表示视图上时，UIKit 视图是不是逐帧改尺寸、逐帧排版。
- V3：UIKit 滚动视图放进现在的 SwiftUI 窗口（标题栏、控制区都是 `safeAreaBar`），标题栏底下的滚动软边和现在一不一样；底下让出的高带着动画变（键盘、控制区长高）时，贴底的内容跟不跟得上。

## 做法

一个独立的 SwiftUI 小 App，`./build.sh v1|v2|v3 [模拟器 UDID]` 编译、装进模拟器、启动、等报告写完取回（产物在 `/tmp/kite-ios-native-spike/`，不进仓库）。App 的共用量高协议 `app/Kite/UI/TextKitMeasuring.swift` 原样编进来，V1 的文本视图遵循它。只调接口、读状态；V3 的截屏由脚本用 `simctl io screenshot` 拍整屏（含系统软边、键盘），键盘由程序聚焦输入框弹出。没有合成触摸、键盘或滚动事件。

- V1：7.5 万字、358 段的正文（17 pt 正文字体，中英混排），宽 600、外层露出 400 pt、停在正文中间。数各段 `NSTextLayoutFragment` 的状态是不是 `layoutAvailable`，读 `textViewportLayoutController.viewportBounds`，各步分开计时（-O）。
- V2：照 `WindowShell`（Animatable 的 `GeometryEffect` 加 `ignoredByLayout`，外壳排版框逐帧排、圆角裁）、`WindowMotion` 舞台（`TimelineView` 逐帧取样、外框逐帧排、内容缩放、透明度遮罩）、`CompactPaneStack`（平移 `ignoredByLayout`）的写法各套一个表示视图，`sizeThatFits` 返回提议尺寸；程序改状态开合、飞行、横滑，`CADisplayLink`（120 Hz）逐帧记。是近似的复刻，不是真实外壳。
- V3：同一个窗口（`safeAreaBar` 标题栏和带输入框的控制区，`.scrollEdgeEffectStyle(.soft, for: .top)`、底边软边隐藏）分别放 SwiftUI `ScrollView`、只设 `topEdgeEffect.style = .soft` 的 `UIScrollView`、再用 `UIScrollEdgeElementContainerInteraction` 登记顶上那截的 `UIScrollView`，内容滚到标题栏底下截屏比。表示视图铺满窗口、`proxy.safeAreaInsets` 当 `contentInset` 传进去，事务带动画时用 `context.animate` 改。逐帧记最后一行底边和控制区顶边（都取呈现层）之间的距离。

## 结果

### V1：直接用做不到只排一截；iOS 27 有一条可行的组合

| 写法 | 首次露出 | 改宽 600→560 |
|---|---|---|
| 参照：整段 `ensureLayout` | 130～143 ms | 132 ms |
| A 关滚动、frame 整段高，外层露 400 pt | 设 frame 134 ms 整段排完（358/358），`layoutIfNeeded` 9 ms；视口 0…40554，整段 | 只设 frame 138 ms，343/358 段重排；视口仍整段 |
| C 开着滚动、自己当滚动视图停在中间 | 5 ms，排 12 段 | 118 ms：从文首排到视口，268 段 |
| B「视口窗」：frame 只取露出那截、bounds 偏到对应位置 | 排的是文首 5 段（y 0…578），视口所在的 20177 处没有排好的段落 | `contentOffset` 被复位成 0 |
| E 关滚动 + 覆写视口（只给外层露出那截） | 视口裁到 600 pt；但设 frame 仍整段排（139 ms） | 只设 frame 127 ms 整段重排，视口裁了也没用 |
| H 开着滚动（关掉它的拖动手势）+ frame 宽固定 720 + 只改容器宽 + 覆写视口 | 先量高 130 ms（同参照），再设 frame 158 ms（见下） | 连续 20 步每步 3.6 ms，只排视口那 7 段；只改 frame 高 0.1 ms；外层滚动后 `layoutViewport` 2.8 ms 补排 |
| D 共用的 `measure(lineWidth:from:through:)` | — | 改宽后只排 1400 pt：4.8 ms，12 段 |

- 关了滚动的 `UITextView`，TextKit 的视口就是整个 bounds（风险 R1 成立）。更要紧的是：**改 frame 本身**就让 `UITextView` 重设容器尺寸、整段重排，和视口无关。关滚动时改宽、改高都会；开着滚动时改宽会，只改高不会（0.1 ms）。
- 关了滚动的 `UITextView` 把容器高定成视图高：frame 高 100 时整段量高只排到 109 pt。iOS 上实现 `TextKitMeasuring.fit` 时要把容器高一起放开（`.greatestFiniteMagnitude`）。
- iOS 27 SDK 公开了 `UITextView.viewportBounds(for:)`（头文件注明要调 super），覆写成 `super ∩ 外层露出来的那截`，相当于 Mac 覆写 `visibleRect`：视口确实只剩露出来那截（E、F、G、H 都是 y 20177…20777）。部署目标是 iOS 26，iOS 26 上不会被调用，退回整段排。
- 设 frame 时容器宽会被强制改回 frame 的宽（`widthTracksTextView = false` 也一样，H 的 720）。所以 frame 宽要在放字之前定好，之后只改容器宽；不然建好时白排一遍。
- 只排一截时上面没排的段落按估的高占位，露出来那截的位置是估的（H 排好的在 y 20136…32245，宽 600 时那里是另一段字），和 Mac 一样要靠列表按住看着的那一行（`pin`/`pinShift`）。
- 计时是模拟器上的，整段排比 Mac 原生慢（Mac 同样 7.5 万字约 35 ms）；只看量级和排了几段。

结论：第 3 期要做 iPad 长回复拖缝只排一截，可行的写法是 H（`isScrollEnabled = true`、关掉它自己的拖动手势和滚动条、frame 宽固定成最宽内容列、拖缝只改 `textContainer.size` 的宽、frame 只改高、覆写 `viewportBounds(for:)` 裁到外层可见区，外层滚动时请视口重排），代价是要求 iOS 27，且文本视图比内容列宽（命中区往右伸到最宽列）。第 1 期的正文行可以先按 A 的简单写法（整段排），等 iPad 真机量过再定（设计稿 D3）。

### V2：几何效果不改表示视图的尺寸，但会反复调 layoutSubviews

| 场景 | 动画中的帧 | layoutSubviews | 尺寸 | updateUIView |
|---|---|---|---|---|
| 抽屉开合：拉开 / 收回 | 50 / 49 | 7 / 39 次 | 始终 834×1210 | 0 |
| 卡片飞行 | 51 | 14 次 | 始终 500×847 | 0 |
| 横滑 | 49 / 48 | 0 / 0 | 始终 834×1210 | 0 |

- 三种写法下表示视图的 frame、bounds、transform 都不变，位置靠祖先视图（抽屉、卡片：按 `UIView` 换算到窗口的位置逐帧变）或只靠图层（横滑：只有呈现层的位置在变）挪。没有逐帧改尺寸（风险 R2 里「逐帧改 frame 导致逐帧重排」在这些写法下不成立）。
- 但抽屉收回时几乎每帧（49 帧里 39 次）、卡片飞行时约四分之一的帧会调表示视图的 `layoutSubviews`，尺寸没变。原生列表的 `layoutSubviews` 要在尺寸和让出的距离都没变、也没有待排的改动时直接返回，不能每次都跑排列。
- 复刻的是写法不是真实外壳（真实的还有 `safeAreaPadding`、`RestPlacement`、点阵层），第 1 期接进去以后要在真实外壳里再数一次。

### V3：软边一样；键盘跟得上，SwiftUI 带动画改让出的高时早一帧

- 软边：三张截图左边 1000 px 宽（文字相同的部分）逐像素比，状态栏到标题栏下沿、软边下沿、正文三段的差都不超过 1（满 255），差超过 30 的像素为 0。只设 `topEdgeEffect.style = .soft` 就和 SwiftUI `ScrollView` 一样，登记 `UIScrollEdgeElementContainerInteraction` 与否看不出区别。截图：`v3-swiftui.png`、`v3-uikit-style.png`、`v3-uikit-registered.png`。没有覆盖真实标题栏的 `topFade`、`ScrollEdgeDots` 和玻璃按钮。
- 键盘（程序聚焦输入框，第二次弹出时量；第一次模拟器加载键盘卡住约一秒）：`updateUIView` 只被调一次、事务里**没有**动画，直接改 `contentInset` 和滚动位置，弹出 68 帧、收起 57 帧里最后一行和控制区的距离每帧都是 0.0 pt。改动落在系统键盘动画的 UIKit 动画块里，跟着同一条曲线走。
- 控制区带 `withAnimation(.smooth(duration: 0.4))` 长高 300 pt：SwiftUI `ScrollView` 贴底时距离在 ±0.4 pt 以内；表示视图用 `context.animate` 改，`updateUIView` 调一次、事务带动画，距离最大 11～46 pt（三次运行），收回时最小 −32 pt。逐帧看是 UIKit 这边比 SwiftUI 早一帧起步（控制区还没动时列表已经挪了 7.4 pt，之后每帧列表约等于控制区下一帧的位置），中途掉一帧时差得更多，不是曲线不同。
- 所以设计稿 §4.3「事务带动画时用 `context.animate`」在键盘上用不着（事务不带动画），在 SwiftUI 动画改让出的高时会错开一帧。第 1 期要找对齐的办法（比如让 UIKit 这一下晚一帧起步，或换成按帧取值），并核对实际 App 里哪些控制区高度变化是带动画的。

## 复现

```sh
./build.sh v1 <iPad 模拟器 UDID>
./build.sh v2 <iPad 模拟器 UDID>
./build.sh v3 <iPhone 模拟器 UDID>
```

报告和截图在 `/tmp/kite-ios-native-spike/reports/`。脚本只装、启动这个实验 App（bundle ID `top.sainner.kite.spike.ios-native-transcript`），不动 Kite。
