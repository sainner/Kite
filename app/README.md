# Kite App

Mac 和 iPhone 共用一个 SwiftUI 工程、一个多平台 target。

```
app/
├── Kite.xcodeproj
│   └── xcshareddata/xcschemes/Kite.xcscheme   共享 scheme，命令行和 Xcode 用同一个
└── Kite/                                      源码和资源
```

布局：一个会话就是一个窗口组（`Workspace`，在 `Tiles.swift`）：有哪些窗口、Mac 上怎么排、聚焦哪个。Mac 把它们排成卡片（`TileViews.swift`），按住卡片标题栏拖出去，它脱离布局变成跟着指针的圆，落到别的卡片上时用占位预览放下后的排布；iPhone 一次显示聚焦的那个，页签切换（`PhoneLayout.swift`）。Mac 主窗口左边是侧边栏（会话列表和底部的 action 区，拖右边的缝调宽度，拖到很窄收成一列图标，⌃⌘S 切换），会话从侧边栏拖到主窗口外面分离成独立窗口（`DetachedSession.swift`），关掉后回到主窗口。卡片和缝上不拖窗口，拖窗口交给侧边栏这些空白处（`MouseDragArea.swift`）。红绿灯按钮那一条多高、让出多宽，从 AppKit 的安全区读（`WindowChrome.swift`），不写死。尺寸和颜色集中在 `Theme.swift`。

每个窗口都是同一个骨架（`PaneWindow.swift`）：浮在上面的标题栏、内容、浮在下面的控制区，内容从两者后面滚过去，标题栏后面垫系统的滚动边缘效果（软边），控制区后面垫一层渐变遮罩（窗口底色从控制区顶边的全透明过渡到不透明，伸过 Home 条那一截到窗口底边；不透明度是 1 − h²，h 是离窗口底边的距离占整段高度的比例）。控制区是一张液态玻璃卡片，左右留边，靠近窗口角的两个角和窗口圆角同心（窗口用 containerShape 给出形状），底下贴着 Home 条让出的安全区，没有安全区时（Mac 的卡片、iPhone 拉开抽屉）离底边留一点，键盘升起来时离键盘也留这么多。SwiftUI 的安全区分 container 和 keyboard 两区，但只能按区忽略，读出来是合在一起的；Home 条那一截从 UIKit 的安全区读（UIKit 的安全区不含键盘），多出来的就是键盘；这一比在屏幕那一层做，窗口里读到的安全区在拉开、收起抽屉时跟着动画逐帧变，还会冲过 Home 条那一截。控制区底下的安全区里放状态信息，只看不点：iPhone 上让小横条藏起来，它只在进 App 时出来一下，藏起来以后才显示状态信息；系统不告诉 App 它藏没藏，进 App 后等 1 秒算它藏了。各个窗口只给标题栏的信息（标题和次要信息，不放图标）、内容、控制区里的东西和状态信息。Mac 上标题栏靠左，次要信息在标题右边，卡片的拖动把手叠在这一条上；iPhone 上居中，次要信息在标题下面、小一号，左边是拉开侧边栏的按钮（从左边缘往右滑也行）。iPhone 上从控制区往上拖拉出 action 栏，打字时不拉，横着拖不算；打字时点控制区以外的地方收起键盘。还没做的窗口（文件、终端、预览）标题栏是窗口的名字，内容是占位，控制区是一张空卡片。字号是两端共用的一套 token，每个对应一种系统文本样式。

会话窗口（`SessionPane.swift`）：标题栏是会话的标题和所在的项目，内容是对话，控制区上面一行是输入框，下面一行按钮：左边是 effort 的当前档位（low、medium、high、extra、max），iPhone 上点它或从它往右滑、Mac 上鼠标移上去，刻度线展开在档位名前面，当前档位落在手指下面，左右拖调档位；右边是附件、斜杠命令、语音输入（还没做），有字时多一个发送，回合在跑时多一个打断；状态信息是在不在干活、上下文用了几成、工作区改了多少行（假数据）。人发的消息靠右带气泡，agent 的话铺满这一栏，Markdown 用 Foundation 自带的解析、逐块排版（`Markdown.swift`）。两段话之间 agent 做的事折成一行，点开列出每一步，每一步再点开看参数和结果（`WorkViews.swift`）；每个工具怎么说、归哪一类在 `ToolPresentation.swift`，认不出的工具（项目自己的 MCP 等）列出参数和结果原文。会话记录的形状照统一格式的要点（`Transcript.swift`），kited 还没给出记录，现在显示 `SampleTranscripts.swift` 里的假数据：把 Kite 会话里有的工具都调了一遍，另有回合正在跑、不写代码的项目、空会话、压缩打断出错几个会话。发消息和打断只改假数据。

## 约定

- 工程照 Xcode 自带的「多平台 App」模板的设置写成，不用 XcodeGen 这类生成工具。`Kite/` 是同步文件夹：在里面加、删、挪文件，工程自动跟上，不用改 `project.pbxproj`。
- 两端共用代码，差异用 `#if os(macOS)`、`#if os(iOS)` 分开。
- Swift 6 语言模式，数据竞争在编译时报错；模板默认是 5。默认隔离在主线程（`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`），和模板一致。
- 开发语言是简体中文（`zh-Hans`），界面文字直接写中文。
- 最低 macOS 26、iOS 26。只支持 iPhone，要 iPad 时把 `TARGETED_DEVICE_FAMILY` 改成 `1,2`。
- Mac 版开沙盒，允许对外连网（连 kited）、只读用户选中的文件，和模板一致。
- Bundle ID 是 `com.sainner.kite`。

## 编译和运行

`.kite/check` 在 `app/` 有改动时编译两端，出错时列出文件和行号。手动编译：

```bash
xcodebuild -project app/Kite.xcodeproj -scheme Kite -destination 'generic/platform=macOS' -destination 'generic/platform=iOS Simulator' build -quiet
```

运行用 Xcode 打开 `app/Kite.xcodeproj`，选 My Mac 或一台 iPhone 模拟器。

## 签名

本机 Xcode 还没有登录开发者账号：Mac 版是临时签名（ad-hoc），自己编译自己用没问题；iOS 只能跑模拟器。装到 iPhone、走 TestFlight、把 Mac 版给别人都要付费开发者账号，登录后在工程里设 `DEVELOPMENT_TEAM`。
