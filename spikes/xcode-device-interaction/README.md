# Xcode 27 给 agent 的设备操作工具

2026-10-22，macOS 27.2（26B5112a），Xcode 27.2（xcode-select 指向 Xcode-beta），Xcode 的 MCP 服务 xcode-tools 25447.1。这里只记录当时的问题、做法和结果。

## 问题

预览里 agent 看和点模拟器、真机、Mac App，现在靠 Kite 自己的 kite-sim、kite-window。Xcode 27 自带一组设备操作工具（经 `xcrun mcpbridge` 提供的 MCP 工具 DeviceInteraction*），要回答能不能拿来替代，以及四点：要不要开着 Xcode、每个 agent 是不是要批准；Kite 的 harness 能不能接；Mac 上能不能只碰本项目的 App；几个工作区同时用会不会互抢。

## 做法

- `mcp.py`：用 stdio 连 `xcrun mcpbridge`，initialize 后按参数依次调工具，打印每步耗时；`list` 列出工具。
- 在临时目录用 XcodeNewProject 新建一个 iOS App 项目和一个 macOS App 项目（模板 `com.apple.dt.unit.singleViewApplication`、`com.apple.dt.unit.cocoaApplication`），XcodeOpenWorkspace 打开，再开设备会话、装 App、点按、截图。
- 命令写法从 `xcrun mcpbridge run-agent skills export <目录>` 导出的 `device-interaction/SKILL.md` 里查：`t x y` 点按、`d x y` 双击、`t x1 y1 f x2 y2 秒` 滑动、`drag`、`mt` 多指、`b h` 按 Home、`sender keyboard kbd 文字` 打字、`w 秒` 等待。

## 结果

- 不用开 Xcode 的界面：mcpbridge 第一次连上时自己拉起后台的 mcp-server（之前 `xcrun mcp-server status` 是 not running），Xcode.app 没出现。工具共 53 个，含构建、跑测试、读构建日志、渲染 SwiftUI 预览等。
- 要批准：没批准的 agent 调什么都返回 “This agent isn't approved”，要先 XcodeOpenWorkspace 或 XcodeNewProject，由这一步向用户要批准（agent 与项目文件夹两项，也能 `sudo xcrun mcp-server approve <编号>`）。agent 按连上来的那个程序认（这次是没签名的 Python，按二进制哈希），批准 24 小时后到期；文件夹批准连子目录一起。
- 模拟器能用：开会话约 1 秒（模拟器在后台开机）；开机后第一次截图等了 52 秒；InstallAndRun 构建、安装、启动约 26 秒；之后截图 0.4–1 秒、点按加截图 0.4–0.9 秒、滑动约 0.9 秒、按 Home 约 5.8 秒（等动画）。每步返回截图（按点的尺寸，iPad mini 744×1133）、缩略图和界面结构文件（每个控件带可点的 hitPoint），都是 `/var/folders/.../ActionArtifacts/` 下的文件路径。打字进了 Spotlight 搜索框，中文也行。
- 只支持模拟器：iOS 项目的可选设备只有模拟器，配对着的真 iPhone、iPad 不在列表里；macOS 项目开会话报 “None of the available devices are supported for Device Interaction … iOS [Simulator] 27.0+; watchOS [Simulator] 27.0+; tvOS [Simulator] 27.0+”；列 Mac App 的 DeviceInteractionListRunningApplications 报 “is not enabled”。Xcode 附带的说明里写着支持真机和 Mac，这个版本没开。
- 设备由调用方指定：`deviceIdentifier` 给模拟器的 UDID 就用那台；不给时用项目当前的运行目标，这次 Xcode 默认挑了一台 Kite 工作区专用的模拟器。
- 并行：两份项目（当作两个工作区）各开一台模拟器，两条连接同时各点 4–5 次，都正常，每步变成约 0.5–1 秒。同一台机器上第二台模拟器开机时第一次 InstallAndRun 报 “Session initialization timed out”，重试成功（当时空闲内存约 2.5GB）。
- 窗口：开会话、点按、截图都不开窗口，工作机桌面上没有模拟器画面。InstallAndRun 像在 Xcode 里点运行，会拉起 Xcode 自带的 DeviceHub（进程名是带空格的 “Device Hub”），在工作机桌面上开出这台模拟器的窗口（iPad mini 约 458×739 点）；结束会话、关掉模拟器后窗口还在，DeviceHub 要自己退出。Xcode 是给 DeviceHub 开 `devices://` 网址让它开窗口的（日志里 `application:open:urls`）。照这个格式，`open -g -a <Xcode>/Contents/Applications/DeviceHub.app "devices://device/open?id=<模拟器 UDID>"` 能单独让 DeviceHub 开出指定模拟器的窗口，不抢前台、不开机（关机的显示占位，开机后是实时画面）；参数名 `id` 是从 DeviceKit 的报错 “Parameter 'id' is required” 里得知的，同一组里还有 `select`、`showInspector` 两个动作没试。这个窗口能用 `screencapture -l <窗口号>` 截到，含窗口外框和底部按钮，iPad mini 窗口 458×739 点、截图 916×1478 像素，一张 0.3–1.9 秒（每次起进程）。
- 会话：会话名就是会话键，跨连接能用；闲置几分钟后会话被自动关掉（之后报 “Session not found”），用过的名字短时间内不能再用。EndSession 不关模拟器，模拟器要自己关。

## 结论与限制

agent 操作模拟器可以改用 Xcode 的工具：官方、带界面结构和可点坐标、中文打字没问题，设备由 Kite 分配的模拟器 UDID 指定，并行的工作区不互抢。替代不了的：Mac App 窗口和真机（这个版本不支持），人看的实时画面（它只给一步一张图；要实时看可以用上面的网址让 DeviceHub 开出窗口再截窗口，窗口占着工作机桌面）。接进 Kite 要补 MCP 客户端给 agent 用、处理按程序算的批准（24 小时到期）、会话闲置被关后重开、读回 `/var/folders` 下的截图文件。只在这一台 Mac、这一个 Xcode 版本上测过；同一工作区两个 agent 同时操作没测。
