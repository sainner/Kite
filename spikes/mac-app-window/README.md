# 只截一个 Mac App 的窗口、只向它发输入

2026-10-22，macOS 27.2（26B5112a），Xcode 27.2，Safari 27.2。这里只记录当时的问题、做法和结果。

## 问题

预览插件要能看预置脚本起的 Mac App 的窗口（[成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览)），人和 agent 按“截一帧、做一个动作、等稳定、再截一帧”的循环操作。不变式是只截这个窗口、只向这个进程发输入，不能借此控制整台工作机。要回答：

1. 能不能只截一个 App 的窗口，被别的窗口盖住时行不行，要多久。
2. 能不能只把点按、滚动、键盘送给这个进程，不动工作机上真的鼠标，App 不调到前台。
3. 系统的隐私权限（录屏、辅助功能）算在谁头上：kited 起的辅助程序默认继承 kited 的责任进程，kited 有了权限，它起的所有进程（含 agent 的命令）都跟着有。
4. 真的 Safari（没有无界面模式）能不能当成工作机上的一种浏览器来驱动。

## 做法

- `target.m`：靶子 App。一个窗口，有按钮、输入框和一块不接受首次点按的画布（`acceptsFirstMouse` 为 NO），收到的点按、按键、滚动和 `sendEvent:` 看到的原始事件都往标准输出写一行。
- `probe.m`：探针，一条命令做一件事：`perms` 看三项权限，`window`、`capture`、`capture-app` 截图，`click`、`right`、`drag`、`scroll`、`type`、`key` 发输入，`ax` 读界面结构；设了 `PROBE_DISCLAIM` 时先以自己为责任进程重新执行自己。
- `./build.sh` 编译到 `/tmp/kite-appwin`，不进仓库。靶子在后台起（不调到前台），探针对着它的进程号操作；Calculator（SwiftUI）用 `open -g` 在后台起再测。
- Safari 用系统自带的 `safaridriver -p <端口>`，直接发 WebDriver 请求。

## 结果

### 截图

- ScreenCaptureKit 截得到被别的 App 盖住、App 不在前台的窗口。两种过滤器都行：`desktopIndependentWindow`（只有这个窗口）和“这块显示器上只含这个 App”再用 `sourceRect` 裁到窗口（落在窗口里的菜单、弹出框一起截到）。产品用后者。
- 600×432 点的窗口：按像素（@2x）截一帧约 65–90 ms，按点截约 20–35 ms；取 `SCShareableContent` 约 20–40 ms，窗口不变时可以复用过滤器。
- `CGWindowListCopyWindowInfo` 列窗口不需要权限，但要只取屏幕上的（`kCGWindowListOptionOnScreenOnly`）：AppKit 自己有一个 500×500 的屏幕外窗口，按全部窗口取会先拿到它。

### 输入

- `CGEventPostToPid` 只送给这个进程，真的鼠标位置前后不变，App 不会到前台。
- 鼠标事件只设公开的 91、92 号字段（指针下的窗口）不够：App 收到了，但 `windowNumber` 是 0、`locationInWindow` 不对，送不到视图。把 NSEvent 构造的事件和 CGEvent 逐个字段比，窗口号在 51 号字段（未公开）；窗口里的位置要用未公开的 `CGEventSetWindowLocation` 设，传窗口左上角为原点的点。两样都设之后，按钮、单击、双击、右键、滚动在 App 不在前台时都送到了，坐标对。
- 拖动的按下、拖、抬起都要带 `kCGMouseEventClickState = 1`，不然视图收不到。
- 不接受首次点按的视图（画布）在 App 不在前台时收不到左键：事件到了 `sendEvent:`，被窗口当成“先激活”吞掉。按钮这类控件、SwiftUI（Calculator 在后台点 7、8 显示 78）没有这个问题。yabai 那种发事件记录让窗口成为主窗口的做法试了，记录被当成鼠标事件，没用。
- 键盘事件不用带窗口号：`CGEventKeyboardSetUnicodeString` 逐字发，中文、emoji 都进了输入框。靶子 App 没有“编辑”菜单，⌘A 不起作用，正常的 App 有。

### 权限

- 从终端起的探针继承终端 App 的权限（三项都有）。以自己为责任进程（`responsibility_spawnattrs_setdisclaim` 加 `POSIX_SPAWN_SETEXEC`，进程号与标准输入输出不变）重新执行后，三项都没有：权限改按这个程序自己算。产品的 kite-window 这样做，kited 本身不拿这两项权限。
- 谁都能运行这个程序，所以它只操作起它的进程的子孙进程；对 Calculator（不是子孙）直接拒绝。

### Safari

- 这台机器的 Safari 已打开远程自动化。开会话约 0.8 秒，Safari 会到前台；截图（PNG，按设备像素）第一张约 120 ms，之后约 25 ms；点按、滚轮、改窗口尺寸都行。
- 同一个 Safari 同时只认一个会话：第二个会话报 “The Safari instance is already paired with another WebDriver session”，只能一个会话里开几个窗口。
- 用键盘动作往输入框打字之后，紧跟的点按（移动、按下、抬起之间不停）会丢；在中间各停 50 ms 就不丢，之后的点按也恢复。

## 限制

只在这一台 Mac、这一个系统版本上测过；51 号字段和 `CGEventSetWindowLocation` 是未公开接口，系统更新后可能变。没测多显示器、窗口在别的桌面空间或最小化、全屏 App、Metal/游戏类自绘窗口。
