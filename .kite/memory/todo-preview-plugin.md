---
name: todo-preview-plugin
description: 预览的目标模型（.kite/preview/、实例随进程）、模拟器改用 Xcode 自带的，10-22 已实现、待手测；10-23 浏览并进文件插件、能开外网，待手测；别的工作机升级前要清 agent 里的旧工具名；Xcode 批准待用户跑命令、DeviceHub 窗口裁不出屏幕；插件授予预览等不带目标的操作待定；我自己定的实现取舍与已知问题
metadata:
  node_type: memory
  type: todo
  originSessionId: 1fd0107c-f8bf-4003-bdfa-77630176dfbc
  modified: 2026-10-24T12:25:33.513Z
---

**来源：** 2026-10-21 讨论终端的预置脚本时延伸出来；10-22 用户重新讨论预览给谁用，定为「目标」模型加独立的浏览、模拟器改用 Xcode 自带的、设备从列表里选（真机只装包、agent 装真机每次审批）。10-23 用户定浏览并进文件插件、插件改名「浏览」（浏览互联网与本机的文件），这次就能开外网。设计在 [成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览) 与 [实例操作 · 预览](../../docs/实例操作.md#预览)，是现行文档，这里不重复。

**状态：** 10-22 按文档实现（kited 与 App 一起，协议号 12 → 13），`.kite/check` 通过，未提交；第三步原有的 App 窗口、Safari、分发包代码并进来一起。kited 侧用临时冒烟验过：起目标、出网页画面、再起返回同一个、restart 在同一实例里重起、agent 的 open/action/并排一格截图/read/list/stop、找不到目标或设备时错误里列出可选的、浏览窗口新建；Xcode 批准流程验到给出命令为止。10-23 浏览合并实现（协议 13 → 14，含外网链接在浏览里开），未手测：kited 冒烟验过选网址、选在跑的端口、选回文件，以及停掉的端口、本机网址、文件网页同选、旧 kite.browser 与 browser.select 都被拒。

**别的工作机升到协议 13 前：** 已有 agent 的 config.grants 里的 terminal.run、preview.close 会让新版 kited 启动时读授权报错退出（安装器自动回滚），config.agent.tools 里的 terminal_run、preview_close 会让切换模型等报「agent 配置无效」。按 [[feedback-stale-data]] 征得同意后从这些 agent 里去掉这几项。这台 10-23 已清，改前的库备份在 ~/.kite/kite.db.before-protocol13。

**待用户做：**
- Xcode 批准：kited 第一次碰模拟器时，错误里给出两条 `sudo xcrun mcp-server approve --always <编号>`（Kite 与 Kite 目录的 xcode/ 文件夹）。批准前模拟器画面、agent 操作模拟器都用不了；批准后模拟器的点按、滑动、打字、截图、界面结构都没实测过。
- 装新版后手测（Mac、iPhone、iPad）：新建窗口的「预览目标」与设备菜单（iPhone 上默认选中手上这台）；网页画面在本设备看与换工作机浏览器、并排的添加与移除、输出视图、停止与重新运行；浏览窗口侧栏的端口、地址栏输端口号或网址、外网页面里点链接、Mac 上的开发者工具与在浏览器中打开、看着文件时的「打开网址」；终端标题栏「打开网页」开浏览；消息里 localhost 链接（属于预览的开预览，属于终端的开浏览）；Mac 上不开窗口也能直接在自己的浏览器里打开工作区端口；装真机的审批卡片；App 窗口画面与「在这台 Mac 上打开」。

**DeviceHub 窗口没做成（10-22 实测）：** 屏幕在窗口里的位置只能从辅助功能树读（子角色 iOSContentGroup，关闭按钮也在树上），只有第一次读得到，之后 DeviceHub 的窗口在辅助功能里一律报成整个 App（重开 DeviceHub、重新开机都一样），裁不出屏幕、人点的位置对不上。现行人看的画面用 `simctl io screenshot`，约半秒一帧，实时只有一两帧每秒。要不要回去找别的裁法（比如按 Xcode 截图的尺寸比对）待用户定。

**我定的实现取舍（汇报时说，用户还没确认）：** 预览实例的进程由终端插件托管，进程状态同终端放在 state.terminal（文档原写 state.preview.ports，已改）；state.preview 是 screen、主端口 port、app、browser。已结束、还开着窗口的同一目标与设备再起时在原实例里重起。模拟器目标「画面就绪」按模拟器里 launchctl 多出 UIKitApplication 判断。端口段按「目标 + 设备」分（同一目标装到几台设备时各一段，文档已改）；目标脚本里没写 KITE_SIMULATOR、KITE_DEVICE 的，选的设备不算。重新起的预览结束时通知这次起它的 agent。preview_open 看到已在跑而没做主线比对的，进控制队列时已经结束就不起、让 agent 再调一次。目标标题是「目标名 · 型号或设备名」。并排的格子记在本机、所有预览共用一套，默认 WebKit 手机与 Chromium 桌面两格。preview_open 的结果在画面就绪时带一帧截图；工具清单去掉 terminal_run、preview_close，加 preview_read、preview_stop。kite-sim 删了。浏览：网站数据按工作区分开（同一工作区的浏览窗口共用登录）；网页里新窗口打开的链接在同一个页面里打开；页面跳不进 kited 自己的地址；消息里的文件引用不拿正在看网页的浏览窗口来开；消息里的外网链接（10-23 用户定在浏览里开）复用在看外网的浏览窗口，没有才新建；同一网址再点不会把那个窗口拉回链接处。

**已知问题（沿用）：** kite-window 第一次用时要在「隐私与安全性」里允许录屏与辅助功能，源码一改要重新允许。App 不在前台时，不接受首次点按的 AppKit 自绘视图吞左键（spikes/mac-app-window）。Safari 开会话会到前台。Playwright 的 Firefox 在 macOS 27.2 上起不来。浏览器第一次用时下载到 ~/Library/Caches/ms-playwright，磁盘紧时注意 [[disk-space]]。目标里的 `simctl launch --console-pty` 是之前两次内核崩溃前的最后一步，onboarding skill 还推荐它，待查。

**待定（docs 待定节有）：** 测试平台的假设先在一个项目试一轮；Mac 之间传 .app 的动作放哪。

**待定（10-24 用户定先不加）：** 插件设置里没有入口授予不带目标的操作（`preview.*`、`monitor.start`），Bun 插件拿不到预览授权。App 已按操作目录的 `grant` 只在能写对应目标的组里给开关，以前生成的带目标授权本来就存不上。要加时在「工作区」那组按 `grant.params` 为空给开关，先想清插件开的 monitor 唤醒谁；有插件需要时再设计。

**候选改进（未定）：** 等画面稳定的 1 秒定时改为各画面自己判断；App 窗口改 SCStream 推帧；照 Claude 桌面版（idb 取帧、H.264 推流、WebCodecs 解码）把模拟器画面改成视频流。

**完成条件：** 用户批准 Xcode、在 Mac、iPhone、iPad 上手测通过后删掉本条；DeviceHub 与待定两项各自另立或并入时删。
