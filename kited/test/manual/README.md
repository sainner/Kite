# 手动验证

这些验证需要真实组网服务、Swift 编译器、原生界面或 WKWebView，不计入 `small` / `medium` 的数量与耗时预算；其中哪些由 `.kite/check` 自动运行见 `kited/scripts/check.ts`。以下命令从仓库根目录运行；原生界面与 Swift 验证需要 macOS 和 Xcode 开发工具。

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
| `verify-transcript-swift.ts` | 显示投影 JSON 的 Swift 解码、思考和工具结果关联 | `bun kited/test/manual/verify-transcript-swift.ts` |
| `verify-window-dock.ts` | 窗口拖动、停靠、预设切换与状态恢复 | `bun kited/test/manual/verify-window-dock.ts` |
| `verify-plugin-web.ts` | 真实 WKWebView 与 MCP Apps SDK 的隔离和生命周期 | `bun kited/test/manual/verify-plugin-web.ts`；iOS 加 `--ios <模拟器 UDID>` |

`PluginWebProbe.swift` 是 `verify-plugin-web.ts` 编译和启动的原生探针，不单独运行。其余 Swift 文件是同名验证使用的夹具；`command.ts` 提供共用子进程执行入口。

`verify-account-http-swift.ts` 直接编译真实 `AccountHTTP.swift`，连接本机真实账号服务和临时 SQLite；Foundation shared Cookie 存储也隔离到临时目录。服务启用生产模式的来源检查，旧客户端与新客户端使用不同的夹具 IP 避免互相消耗登录限流额度；不访问公网，不测试限流策略。预期拒绝旧 Cookie 请求时，Better Auth 会输出 `Missing or null Origin` 与 `Invalid origin` 日志，脚本最终退出码为 0 才算通过。

`verify-directory-app.ts` 接收已经编译的 macOS DEBUG App 包或可执行文件，不自行编译。它在临时目录启动两个真实 kited，经本机代理控制 SSE 断线与 HTTP 响应交接，在原生进程运行真实 `AppModel`；子进程期限 35 秒。登录与托管目录是隔离夹具，不连接公网账号或 Tailnet、不使用 Keychain。这验证 `clearAccountConnections()` 后的旧响应丢弃，不证明真实撤销会自动触发原生 App 收口，也不涵盖 iPhone 界面验收。

`verify-account-network.ts` 可在 macOS 或 Linux 的 Bun 1.4.2 环境运行，需要 `curl` 和当前平台构建的 `kited/net/bin/kite-net`，也可用 `KITE_NETWORK_BINARY` 指定组网程序路径。账号服务默认使用 `https://hs.sainner.top`，可通过 `KITE_ACCOUNT_URL` 覆盖。它创建两个随机测试账号和三个临时节点，经 `curl --socks5-hostname` 验证访问与撤销。总期限 90 秒，最后 10 秒预留清理；无论成功失败都尝试删除登记设备、停止节点并删除临时目录。脚本只输出阶段结果与待清理测试账号的 user IDs，不输出凭据；账号数据库记录由操作者在对应托管实例清理。该脚本不在常规 `.kite/check` 中执行。

撤销验收先保留 controller 本机网络，确认其令牌访问 `/api/account` 返回 401，并在十五秒传播窗口内确认新组网请求无法取得 2xx；随后模拟客户端响应 401 调用 `network.stop()`，要求既有 SSE 在五秒内结束。不要求控制面撤销自然产生 EOF，也不验证原生 App 的自动轮询与收口。异账号访问若被 ACL 提前拒绝，也不能单独证明请求到达了 Go 的 WhoIs 校验。

2026-10-06 针对 `https://hs.sainner.top` 的三节点实测已通过入网、同账号访问及异账号伪造头拒绝。该次使用未观察账号状态的纯 daemon controller，撤销后直到脚本 80 秒验证期限结束仍未观察到 SSE 自然 EOF，curl 退出 28；设备最终清理成功。该次运行停在等候 EOF，未验证撤销后的新请求。这是当次条件下的观察，不代表控制面永久不会关闭连接；原生 App 行为仍需独立验收。
