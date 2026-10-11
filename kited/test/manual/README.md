# 手动验证

这些验证需要真实组网服务、Swift 编译器、原生界面、WKWebView 或模型订阅，不计入 `small` / `medium` 的数量与耗时预算；其中哪些由 `.kite/check` 自动运行见 `kited/scripts/check.ts`。以下命令从仓库根目录运行；原生界面与 Swift 验证需要 macOS 和 Xcode 开发工具。

## 运行时验证

先按 [工作机开发入口](../../README.md#启动服务) 安装依赖，再在仓库根目录选择项目固定的 Bun：

```bash
export PATH="$PWD/kited/node_modules/.bin:$PATH"
```

| 入口 | 验证内容 | 命令 |
| --- | --- | --- |
| `verify-account-network.ts` | 真实账号与 Headscale 入网、账号隔离、撤销后令牌和新请求失效、模拟客户端响应 401 关闭 SSE；仅手动运行 | `bun kited/test/manual/verify-account-network.ts` |
| `verify-account-http-swift.ts` | 真实 Foundation Cookie 残留复现、生产模式来源校验、Bearer 身份隔离及注销重登；常规合同检查自动运行 | `bun kited/test/manual/verify-account-http-swift.ts` |
| `verify-directory-app.ts` | 真实 DEBUG AppModel 的两机目录汇总、离线隔离、按工作区操作、旧响应丢弃及目录摘要保留布局；仅手动运行 | `bun kited/test/manual/verify-directory-app.ts --app /path/Kite.app` |
| `verify-plugin-management.ts` | Swift 配置编辑与真实后端往返、授权和版本冲突 | `bun kited/test/manual/verify-plugin-management.ts` |
| `verify-remote-workspace-swift.ts` | 真实后端工作区与跨工作机项目身份的 Swift 解码、目录同步 | `bun kited/test/manual/verify-remote-workspace-swift.ts` |
| `verify-resource-reference-swift.ts` | 文件、diff 和网页引用经过 Markdown 与编码转换后仍正确 | `bun kited/test/manual/verify-resource-reference-swift.ts` |
| `verify-thread-draft-swift.ts` | 停止退回草稿与发送淡出回调交错时不丢字、不重复 | `bun kited/test/manual/verify-thread-draft-swift.ts` |
| `verify-transcript-scroll-swift.ts` | SwiftUI 动画收起与滚动阶段的定位交接 | `bun kited/test/manual/verify-transcript-scroll-swift.ts` |
| `verify-dot-canvas-swift.ts` | 真实 DotField 浮动、闪烁与空白帧交接的颜色连续性 | `bun kited/test/manual/verify-dot-canvas-swift.ts` |
| `verify-dot-background-swift.ts` | 真实 SwiftUI preference 在窗口点阵启用、停用与移除时的自动占用交接 | `bun kited/test/manual/verify-dot-background-swift.ts` |
| `verify-compact-pane-stack-swift.ts` | 真实 SwiftUI 卡片连续左右切换后的入口恢复与原生按钮命中，含玻璃控制区和持续动画重绘；仅手动运行 | `bun kited/test/manual/verify-compact-pane-stack-swift.ts` |
| `verify-card-sheet-sizing-swift.ts` | 同一次真实 SwiftUI sheet 随生产 CardSheet 内容增减长高、缩短；只读取窗口尺寸，仅手动运行 | `bun kited/test/manual/verify-card-sheet-sizing-swift.ts` |
| `verify-transcript-swift.ts` | 显示投影 JSON 的 Swift 解码、思考和工具结果关联 | `bun kited/test/manual/verify-transcript-swift.ts` |
| `verify-window-dock.ts` | 窗口拖动、停靠、宽窄视口切换、临时收起与状态恢复 | `bun kited/test/manual/verify-window-dock.ts` |
| `verify-plugin-web.ts` | 真实 WKWebView 与 MCP Apps SDK 的隔离和生命周期 | `bun kited/test/manual/verify-plugin-web.ts`；iOS 加 `--ios <模拟器 UDID>` |

`PluginWebProbe.swift` 是 `verify-plugin-web.ts` 编译和启动的原生探针，不单独运行。其余 Swift 文件是同名验证使用的夹具；`command.ts` 提供共用子进程执行入口。

`verify-compact-pane-stack-swift.ts` 直接编译生产 `CompactPaneStack.swift`，用最小两页模型和离屏 `NSHostingView` 验证两个场景：静态卡片，以及带 `safeAreaBar`、`GlassEffectContainer`、重复状态动画和 `TimelineView` 重绘的卡片。复杂场景使用新卡片首次观测到的环境入口立即反向；每次正向、反向切换后都要求从宿主命中原生 `NSButton` 才发送动作；不截图、不打开或操作用户 App。该验证覆盖卡片容器的命中交接，不涵盖真实触控手势识别或完整业务页面；脚本可接受 Swift 源文件路径作为第一个参数，用于编译保留的回归快照。

`verify-card-sheet-sizing-swift.ts` 使用真实 SwiftUI sheet 验证共享弹窗随内容增减调整高度、超长内容受屏幕可用范围限制，且始终使用同一窗口。测试窗口透明且不接收鼠标，只读取窗口尺寸；不涵盖登录服务、实际滚动手势或视觉验收。第一个参数可指定包含完整控件定义的 `CardControls.swift` 快照，此时替代生产控件文件参与编译。

`verify-account-http-swift.ts` 直接编译真实 `AccountHTTP.swift`，连接本机真实账号服务和临时 SQLite；Foundation shared Cookie 存储也隔离到临时目录。服务启用生产模式的来源检查，旧客户端与新客户端使用不同的夹具 IP 避免互相消耗登录限流额度；不访问公网，不测试限流策略。预期拒绝旧 Cookie 请求时，Better Auth 会输出 `Missing or null Origin` 与 `Invalid origin` 日志，脚本最终退出码为 0 才算通过。

`verify-directory-app.ts` 接收已经编译的 macOS DEBUG App 包或可执行文件，不自行编译。它在临时目录启动两个真实 kited，经本机代理控制 SSE 断线与 HTTP 响应交接，在原生进程运行真实 `AppModel`；子进程期限 35 秒。登录与托管目录是隔离夹具，不连接公网账号或 Tailnet、不使用 Keychain。这验证 `clearAccountConnections()` 后的旧响应丢弃，不证明真实撤销会自动触发原生 App 收口，也不涵盖 iPhone 界面验收。

`verify-account-network.ts` 可在 macOS 或 Linux 的 Bun 1.4.2 环境运行，需要 `curl` 和当前平台构建的 `kited/net/bin/kite-net`，也可用 `KITE_NETWORK_BINARY` 指定组网程序路径。账号服务默认使用 `https://hs.sainner.top`，可通过 `KITE_ACCOUNT_URL` 覆盖。它创建两个随机测试账号和三个临时节点，经 `curl --socks5-hostname` 验证访问与撤销。总期限 90 秒，最后 10 秒预留清理；无论成功失败都尝试删除登记设备、停止节点并删除临时目录。脚本只输出阶段结果与待清理测试账号的 user IDs，不输出凭据；账号数据库记录由操作者在对应托管实例清理。该脚本不在常规 `.kite/check` 中执行。

撤销验收先保留 controller 本机网络，确认其令牌访问 `/api/account` 返回 401，并在十五秒传播窗口内确认新组网请求无法取得 2xx；随后模拟客户端响应 401 调用 `network.stop()`，要求既有 SSE 在五秒内结束。不要求控制面撤销自然产生 EOF，也不验证原生 App 的自动轮询与收口。异账号访问若被 ACL 提前拒绝，也不能单独证明请求到达了 Go 的 WhoIs 校验。

## 真实订阅验收

升级 SDK、Claude Code 或模型接入后，需要用对应工作机上的真实订阅验收。Claude 验收先确认终端已登录，并清理测试进程继承的 `CLAUDE_*` 环境变量。假端点测试与 SDK 事件不能代替真实模型请求证据；验收结果保留在任务记录中，注明版本、环境和覆盖范围。

1. 在 App 创建代理，完成读取、修改、shell 与项目检查。核对工具调用和结果、增量显示、文件快照及历史引用；确认暴露的工具符合当前角色与授权。Claude 正常完成一轮后应保留进程，宿主能力不被 Claude 的内置工具或 hooks 重复执行。
2. 检查首轮、工具调用后和原生恢复后的实际上游请求。核对系统提示词与历史内容符合 [上下文模板](../../../docs/harness-上下文组装.md)，没有额外注入 Claude 的日期、环境、技能或项目记忆。高用量提示要区分客户端注入与服务端行为；仅观察 SDK 输出不能作出来源结论。
3. 在配置稳定且没有压缩的条件下，分别验证持续会话和停止后继续输入。确认原生恢复不重复提交输入，并分别记录首轮与后续轮次延迟；不从单次测量推断性能保证。
4. 按 [会话状态机](../../../docs/会话状态机.md) 和 [线程通知投递](../../../docs/线程通知投递.md) 验证停止、队列退回、配置与模型切换、授权撤销和恢复。实例归档与工作区归档的范围分别按 [工作机契约](../../../docs/kited.md) 验证。
5. 核对角色工具、插件授权和凭据访问；已撤销的能力必须被拒绝。项目 MCP 配置不应自动授予实例能力，新增授权在对应后端的生效边界内进入模型请求，规则见 [Bun 插件](../../../docs/Bun插件.md)。
6. 核对模型目录声明的最大上下文与本轮实际配置的上下文窗口。Claude 使用 SDK 提供的运行摘要，自研 harness 核对宿主请求配置；两者都不能只凭模型目录的上限推断本轮实际可用容量。
