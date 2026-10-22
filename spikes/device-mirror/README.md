# 照 DeviceHub 的做法收真机的实时画面

2026-10-22，macOS 27.2（26B5112a），Xcode 27.2，iPhone 17（iOS 27.2）与 iPad Pro（iOS 27.0）都已配对、显示为 connected。这里只记录当时的问题、做法和结果。

## 问题

预览想做成测试平台，Apple 一栏像 DeviceHub 那样真机与模拟器并列。模拟器的画面 Kite 自己能取；真机的实时画面 DeviceHub 能显示，但用的是 Xcode 的私有框架。要回答：Kite 在工作机上的辅助程序能不能照它的调用方式收到真机的实时画面。

## 做法

- 拆 DeviceHub：真机画面走 `DeviceKit` → `CoreDevice.framework/Frameworks/CoreDeviceMediaStreamSupport`，后者用 AVConference（FaceTime 那套实时音视频）收设备推来的视频，点按走 `UniversalHID`。模拟器另走 SimulatorKit 在本机直接画帧缓冲，不经编码。
- CoreDevice 没有接口文件。`interfaces/` 里按二进制符号（`nm` 加 `swift demangle`）手写了用到的几个声明：`DeviceManager.shared.allDevices()`、`MediaStreamSession(clientSessionID:)`、`makeVideoStream(withConfiguration:fromRemoteDevice:)`、`VideoStreamConfiguration.receiveMirroredPrimary(layer:timeout:)`、`VideoStream.activate()` 与 `requestLastDecodedFrame()`。
- `mirror.swift`：`mirror list` 列设备；`mirror <ID 片段> [秒数]` 开窗口建视频流画到图层上，打印事件，每 3 秒要一次最后一帧。`./build.sh` 编到 `/tmp/kite-device-mirror`。
- 对照官方入口：`devicectl device capture screenshot` 与 `screen-record`。

## 结果

- 自己的程序能用 CoreDevice：列出 iPhone 和 iPad，建视频流时 CoreDevice 拿到了设备使用断言，和设备谈好了流的配置（60 帧、最高 6 Mbps、开码率自适应）。手写接口的符号都对得上（actor 的方法要声明成 `final` 才是直接调用）。
- 卡在 AVConference：负责收流解码的系统服务 avconferenced 对配置流、要最后一帧都报 `failed authorization check ... entitlementStatus=2`，随即断开，程序这边只收到 `streamDidServerDie`，图层一直是空的。
- DeviceHub 带着 `com.apple.videoconference.allow-conferencing` 这项权限。给实验程序自签上它，内核拒绝加载：`Code has restricted entitlements, but the validation of its code signature failed`，退出码 137。这是苹果限定的权限，不关掉系统完整性保护拿不到。签名已改回不带权限。
- 官方截图能用：`devicectl device capture screenshot` 一张约 0.6–0.8 秒（含起进程），1206×2622 的 PNG。`screen-record` 在这台 iPhone 上报 “The capability Screen Recording is not supported by this device”。官方命令行没有点按真机的命令；Xcode 给 agent 的设备操作工具（MCP 的 DeviceInteraction*）说明里写着支持真机的点按加截图，没在这里试。

## 结论与限制

Kite 自己的程序收不到真机的实时视频：数据通道 CoreDevice 放行，解码服务 AVConference 只认苹果签名、带限定权限的程序。真机只能一步一张截图。没试的另一条路：在工作机上开 DeviceHub 显示真机，再像 Mac App 窗口那样截它的窗口、向它发点按，要录屏与辅助功能权限，DeviceHub 窗口得开在工作机桌面上。只在这一台 Mac、这一个系统版本上测过。
