# Mac 上用 NSTextView（TextKit 2）排 agent 回复的散文块，外观能不能一点不变

2026-10-11，本机 macOS 27.2（26B5101f），Xcode 27.2（27B5028f），Swift 6.4，Retina 2x。

## 问题

Mac 上 agent 回复由 `MarkdownView` 逐块排成 SwiftUI `Text`，系统不支持跨 `Text` 选字。iPhone 已把连续散文块合成一个 `UITextView`。用户决定两端走同一条 TextKit 2 管线，前提是外观和现在一模一样。要回答：Mac 上换成 NSTextView 之后，跨段选择、链接点击、右键操作栏、上浮动画、高度自适应、装饰绘制各自行不行；并把外观差异逐项列清楚，不是抹平。

## 方法

`main.swift` 是一个独立的 Mac 小程序，窗口里左右两栏排同一段 Markdown（标题、段落、粗斜体、行内代码、引用、有序无序列表、文件引用、网页链接）：

- 左栏是现在 App 用的 `MarkdownView`。`app/Kite` 里的真实源文件直接编进来：`Theme.swift`（字号与 `Metrics`）、`Markdown.swift`、`InlineCode.swift`、`ReferenceViews.swift`、`ResourceReference.swift`、`ControlPointer.swift`、`InterfaceMode.swift`；代码块、表格、提示条这些散文块用不到的类型由 `Stubs.swift` 补桩。颜色资源用 `actool` 从 `app/Kite/Assets.xcassets` 编成 `Assets.car` 放进 `.app` 包，`Color("CodeBackground")`、`Theme.rule`、`AccentColor` 都是真值。
- 右栏是 `ProseTextView.swift`：一个 `NSTextView(usingTextLayoutManager: true)` 包成 `NSViewRepresentable`，属性串照 `SelectableMarkdown.attributed/inline`（iOS）逐行搬到 AppKit，行内代码背景和引用竖线照 `TextKitDecorations.swift` 搬成 `NSTextLayoutFragment` 子类。常量全部取自编进来的 `Theme`/`Metrics`，没有照抄。

自动模式按顺序跑七件事，能程序判定的写进 `report.txt`，像素对照把裁好的图留在日志目录给人看。像素靠 `CGWindowListCreateImage`（dlsym 调用）抓自己的窗口，两栏标题行各放一个纯红 8×8 标记把 pt 对到像素；SwiftUI 侧的逐行几何从 `Text.LayoutKey` 偏好读，TextKit 侧从 `NSTextLayoutFragment.textLineFragments` 读。鼠标事件用 `NSEvent.mouseEvent` 合成后 `NSApp.postEvent`，滚轮从 `CGEvent` 转；运行时会把窗口提到最前（非 key 窗口不分发合成的点击）。

```sh
./build.sh --auto <日志目录>           # 照搬 iOS 属性串，自动跑完退出
./build.sh --auto <日志目录> --tuned   # 按第一轮量到的差异补偿后再跑一遍
./build.sh                             # 手动模式，顶上有按钮：上浮、上浮加滚动、深浅色、变窄、矮窗口
```

产物在 `/tmp/kite-textkit-spike/`（`SPIKE_OUT` 可改），不进仓库。日志目录里：`report.txt`、`light-/dark-{left,right,diff,rows}.png`（整栏截图、整栏差图、按基线对齐的逐行三格图）、`rise-*.png`（上浮中途与结束的整窗截图）。

## 结果

### 1. 跨段落选择与复制：可以

- `setSelectedRange` 从第一段中部跨三级标题选到引用中部，`copy(nil)` 复制出 77 字，与 `textStorage` 对应子串一致。
- `NSApp.sendAction(copy:)` 走响应链（等于 Edit 菜单和 Cmd+C）同样复制成功。
- 合成鼠标按下、拖动、松开，从第一段拖到有序列表第二项，选区 {30, 213}，跨过了标题、引用、列表项。
- 复制出的纯文本带着列表的 `\t•\t` 前缀、引用图标的 U+FFFC 和 U+2060，按既定方向复制要从源 Markdown 重建，这里只证明选区能跨块。

### 2. 链接点击：可以

点网页链接文字、文件引用文字、文件引用的图标（附件字符）三处，`textView(_:clickedOnLink:at:)` 各收到对应 URL（`https://…`、`kite://file?…`）；点非链接文字 0 次，点后选区长度 0。左栏的 `openURL` 全程 0 次，事件没串栏。前提是 `isSelectable = true`，不可选的 NSTextView 不处理链接。

### 3. 右键：三种挂法都量到了

| 挂法 | 结果 |
|---|---|
| A. App 现在的 `SecondaryClickArea` 盖在 NSTextView 上 | 右键和 Control+左键都只到操作栏回调；`menu(for:)` 0 次，没有 NSMenu 弹出。有选区时右键选中的字也一样，选区保留 |
| B. 不盖层，NSTextView 默认菜单 + 外层 `.contextMenu` | NSTextView 自己的菜单弹出（Look Up、Translate、搜索、Cut、Copy、Paste…），SwiftUI 的 contextMenu 从不出现 |
| C. `menu(for:)` 返回 nil + 外层 `.contextMenu` | 右键传到上层，SwiftUI 的 contextMenu 弹出 |

系统编辑菜单的复制：NSTextView 是第一响应者时 `validateUserInterfaceItem(copy:)` 有选区 true、无选区 false，Edit 菜单和 Cmd+C 照常可用，和操作栏互不影响。共存方式由 `menu(for:)` 决定：A 或 C 让右键归我们的操作栏，B 归系统；想要「有选区时给系统菜单、否则给操作栏」只要在 `menu(for:)` 里按选区判断，这里没测。

### 4. 上浮动画：跟着动，而且逐帧重画

把 `MessageBubble.Rising` 原样复制（`offset(y:)` 加 `opacity`，`.spring(.smooth(duration: 0.5))`）套在两栏上：

- 逐帧读 NSTextView 在窗口里的位置，与 progress 推算的位置最大偏差 0.25 pt（半像素取整），旁边放的普通 NSView 探针一样；`layer.presentation()` 同步。
- 透明度不落在 NSTextView 自己的层上（`alphaValue` 和自身 `layer.opacity` 一直是 1），落在 SwiftUI 的祖先层上，从文本视图一路乘到窗口的累计 opacity 与 1−progress 最大偏差 0.00。
- 像素核对：动画中途截图里一级标题那行墨的顶边相对结束位置，t≈109ms 时左右两栏都是 24.5 pt（期望 24.56），t≈225ms 都是 10.0（期望 10.03）；墨量分别是结束时的 21% 与 66%（期望 23%、69%）。同时 `scrollTo` 底部时，两栏每帧的位移也相同。
- 左栏开着 `textSelection(.enabled)` 的 SwiftUI Text 在这个实验里也跟着上浮，没有复现 `MessageBubble` 注释里「可选中的文字不跟气泡上浮」的现象；App 里是否仍需要上浮时关选字，要在真实对话里看。
- 开销：静止 0.9 秒 `draw` 0 次；只动 `offset` 0.5 秒弹簧 `draw` 35 次（基本每帧一次），只动 `opacity` 1 次，只滚动（`scrollTo` 底部）1 次。SwiftUI 用几何效果移动平台视图时不改它的 frame（`setFrameOrigin`/`setFrameSize` 0 次）却每帧让它重画。

### 5. 高度自适应：可以

`sizeThatFits` 按 `proposal.width` 把容器宽度放上去、`ensureLayout` 后取 `usageBoundsForTextContainer.height`，按宽度缓存。栏宽 360 → 240 → 360，三次 frame 高都等于 ceil(usage)、最后一行底边不超出；一轮布局里 SwiftUI 问 `sizeThatFits` 几十次，实际排版只在新的宽度上发生（到第一次核对时问了 78 次、排了 21 次），缓存必须有。放在 SwiftUI `ScrollView` 的 `VStack` 里，NSTextView 没有自己的 `NSScrollView`（`enclosingScrollView` 是 SwiftUI 的 HostingScrollView），向下滚 6 行的滚轮事件打在 NSTextView 上，外层 contentOffset 0 → 60，它自己不滚。

### 6. 装饰：能画，坐标不用翻

`DecoratedFragment` 和 iOS 版逐字相同（只多了 tuned 变体的开关），在 flipped 的 NSTextView 里引用竖线和行内代码背景都画在字的位置上：竖线取样色 #E0DFD5 与 SwiftUI 的 #E1DFD5 一致，代码背景块 #F1EEE0 与 #F0EDE0 一致。TextKit 2 交给 `draw(at:in:)` 的 context 已经是片段局部坐标，不需要再处理 flipped。位置上的差异见下表。

另外发现一个两端共用逻辑里的缺陷：`drawInlineCode` 用 `CTTypesetter` 重排一行取字形位置，CoreText 不认识 `NSTextAttachment` 的宽度，所以同一行里只要行内代码前面有引用图标（附件），背景块就画偏——第 13 行「带 ▣链接 和 code」CoreText 算出的首字形 x 比 TextKit 的段落片段多 22.46 pt，其他行是固定的 4.46，背景块落在字的右边。iPhone 上同一段代码大概率也有，需要核对；修法可以是给附件字符加 `CTRunDelegate`，或改用 `NSTextLineFragment.locationForCharacter(at:)` 取位置、只用 CoreText 取宽度。

### 7. 外观对照

字体：SwiftUI `Font.resolve` 给出的 CTFont 与 AppKit 这边构造的 NSFont，PostScript 名、字号、字重八种用途全部一致（body `.SFNS-Regular` 13、heading1 `.SFNS-Semibold` 17、heading2 `.SFNS-Semibold` 15、heading3 `.SFNS-Bold` 13、行内代码 `.AppleSystemUIFontMonospaced-Regular` 11.7、粗体 Semibold、斜体 RegularItalic）。颜色：正文 #2B2A27/#2A2826、引用 #87857C 两边相同；深色下 #E0E0E0、#9FA0A2 也相同。链接文字 SwiftUI 用的是系统 `linkColor`（浅色 #0068DA，深色 #419CFF），不是 App 主题色；文件图标用的是 `.tint`（主题色 #5B88C2 / #4E79B0）——NSTextView 这边分别用 `linkTextAttributes` 和手动着色的附件图片后两边一致。

逐行按各自基线对齐再比像素（允许 ±3 像素整体平移以排除亚像素相位）：17 行里 9 行残差 0.00%、3 行 0.04%，字形、字距、粗斜体、编号与项目符号的位置都一样；有残差的行是带图标的两行（0.26%、0.84%，图标本身的渲染略有差别）、折行不同的第 10/11 行（0.63%、12.87%）和代码背景画偏的第 13 行（0.91%）。整栏直接比差 13.69%，全是下面这些位置差异造成的。

照搬 iOS 属性串时的差异（light 下测，dark 相同）：

| 差异 | 大小 | 原因 | 能不能抹 |
|---|---|---|---|
| 块与块之间多 6 pt | 每个块边界 +6；12 块的样例整段高出 65.5 pt（含下面标题、图标行两项） | TextKit 2 把 `lineSpacing` 放在每一行上方，段落第一行也有；SwiftUI 的 `VStack` 只有块距 | 能：`paragraphSpacingBefore = blockGap − lineSpacing`，tuned 变体验证后块距一致 |
| 开头的标题少 6 pt 上留白 | 第一块是标题时 −6 | TextKit 不认文档第一段的 `paragraphSpacingBefore`；SwiftUI 的 `.padding(.top)` 无条件生效 | 能：在视图外补 `padding(.top, blockGap/2)` |
| 引用竖线顶边高出 6 pt | 竖线 44 高，SwiftUI 37.5 | 同第一条，片段顶边比字高一个行距 | 能：`QuoteDecoration.top` 加上 `lineSpacing`，tuned 后 −0.03…37.97 对 0…37.5 |
| 行内代码背景高 2 pt | 块高 16（整行）对 13.5（代码字体） | iOS 版用整行 `typographicBounds.height`；SwiftUI 用 run 自己的 ascent+descent 贴基线 | 能：按 run 字体算高度，tuned 后两边 2.00…15.50 一样。iPhone 现在的样子和 Mac 本就不同，改了会一起变 |
| 行内代码背景左边窄 1–1.5 pt | 块左边 247 对 245.5，字从 254 起 | SwiftUI 的 run 起点比字形原点靠左约 1.4 pt，原因没查 | 没试 |
| 一、二级标题下面多 1–2 pt | 行高 22 / 20 对 20.02 / 19，基线位置相同 | TextKit 行高是 ascent+descent+leading；SwiftUI 的标题行高既不是 a+d 也不是 a+d+l，规律没找到 | 勉强：固定行高会把基线抬高 1–2 pt，再加 `baselineOffset` 又把行高压掉同样的数；tuned 里按级别硬凑两个常数后行高对上了，字形仍比 SwiftUI 低 1–1.5 pt，行高和字形位置没能同时对齐；三级标题本来就一样 |
| 个别行矮 0.69 pt | 行高 15.31 对 16.01，样例里是带图标的两行和引用的第一行 | SwiftUI 这些行按 ascent+descent（15.31）算行高、其余行按 16，规律没找到；TextKit 恒定 16.01 | 不抹：这是 SwiftUI 的不一致，TextKit 反而整齐；一段里差 ≤1.4 pt |
| 折行位置差一个字 | 列表第二项「…要和正」/「文对齐」对「…要和」/「正文对齐」 | SwiftUI 不在中文词「正文」中间折行，TextKit 2 默认和 `.standard` 都逐字折 | 没找到开关；真实文本里多久出现一次要看 |
| 嵌套列表符号偏 0.5 pt | 首墨 x 27.0 对 27.5、9.0 对 9.5 | 右对齐 tab 与 `.frame(alignment: .trailing)` 的半像素取整不同 | 没试 |
| 鼠标悬停 | NSTextView 默认对链接显示 URL 工具提示 | 行为层面的差别 | `displaysLinkToolTips = false` 关掉；光标形状（I 形、链接手形）这里没测 |

tuned 变体（`--tuned`）把能抹的一起抹掉后：整段高 460 对 457.5，逐行最大 Δy 2.24 pt，全部来自 0.69 pt 的行和折行差异；竖线、代码背景、块距、标题行高都对上，标题字形低 1–1.5 pt。标题那两个常数是按本机量出的 SwiftUI 值硬写的，不能当正式做法。

需要人眼看的：`light-rows.png`/`dark-rows.png` 里图标两行的渲染差别（截图里看不出，残差 <1%）；代码背景左边 1–1.5 pt；0.5 pt 的项目符号偏移；上浮淡显的观感（数据上一致）。

## 适用限制

- 只在 macOS 27.2 beta 上跑过，部署目标是 macOS 26，TextKit 2 的行距摆放、固定行高与 leading 的关系要在 26 上再核一次。
- 一段样例文本、一种字号（系统默认 13）、栏宽 360 与 240；没有代码块、表格、分隔线（按方向它们另做附件），没有流式增量更新、没有多条消息的对话。
- 像素对照只覆盖本机 2x 屏；链接颜色读的是系统 `linkColor`，用户改了系统强调色时 `.tint` 侧会跟着变，这里没测。
- 合成事件走 `NSApp.postEvent`，和真实输入设备的差别（压力、触控板手势）不在范围内。
- 上浮动画只量了 NSTextView 的位置、层透明度和截图里的墨，没量帧率；`draw` 次数是单个文本视图、一段文本的数据。

## 结论

六项功能都成立：跨块选择与复制、链接点击、右键归操作栏且系统复制可用、上浮逐帧跟随并淡显、高度按宽度自适应且不抢滚轮、装饰不用翻坐标。外观不是照搬就一样：照搬 iOS 属性串会让块距多 6 pt、引用竖线高 6 pt、代码背景高 2 pt、标题下多 1–2 pt；前三项有明确的修法并已验证，标题只能硬凑且行高与字形位置不能同时对齐，折行差异和个别行 0.69 pt 的行高差没有办法。主要风险：TextKit 2 的行距摆放和 iOS 共用的属性串构建有出入，意味着 iPhone 现在的块距和竖线也可能与 Mac 的 SwiftUI 版不同，要一并核对；行内代码前有引用图标时背景画偏是两端共用的缺陷；`offset` 动画让 NSTextView 每帧重画，发送时上浮的那条消息会多一次完整的文本绘制。
