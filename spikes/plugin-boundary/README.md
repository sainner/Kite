# 自定义插件边界短验证

2026-09-30 的独立实验。目的是确认 Web 视图、受限工作机逻辑和现有实例授权能够接起来，不作为产品插件宿主维护。

## 范围与依赖

- macOS 27.2 / Apple Silicon；iPhone 17 模拟器 / iOS 27.0；Bun 1.3.11。
- MCP Apps `@modelcontextprotocol/ext-apps` 2.0.3，MCP client / server / core 2.2.0。
- Deno 2.9.6 从本目录 npm 依赖使用，没有安装到全局。
- 所有状态、工作区和数据库放在独立临时目录，结束时清理；不读取实际工作区或模型凭据。

## 结构

```text
WKWebView 的可信宿主页
  → AppBridge / sandbox iframe 内的 App
  → 原生主 frame 桥接（临时令牌不进入网页）
  → Bun 验证宿主
  → MCP stdio
  → Deno 中的待办逻辑
  → 宿主持久状态，或现有 InstanceOperations 的授权文件读取
```

`todo-server.ts` 使用上游 MCP Server 和 MCP Apps 的工具、资源声明，提供查询、新增、完成待办及读取工作区样本。待办变更逻辑在 Deno 中运行；状态通过实验用的 `kite/state.get` / `kite/state.replace` 回调交给宿主，写入带版本比较的 JSON 文件。该私有实验接口尚未定为产品协议。

`gateway.ts` 为每个 MCP 连接绑定来源身份，参数不能指定调用方或工作区。文件读取实际调用 kited 的 `InstanceOperations`。由于产品的自定义定义加载还未实现，实验用两个现有文件实例分别作为调用来源与目标；这不表示待办插件已经登记进正式目录。

`host.ts` / `view.ts` 是主动执行场景的测试页面。可信宿主页施加 CSP，插件只在 `sandbox="allow-scripts"` 的独立来源 iframe 内运行；消息来源由 `PostMessageTransport` 校验。Swift 再核验原生桥调用来自可信主 frame，同源子 frame 也不能直接调用。主题、尺寸和卸载使用上游通知。

## Deno 加载边界

不能直接把外部插件作为 `deno run plugin.js` 的入口：Deno 的初始静态模块图有独立的加载权限语义。这里仅运行宿主拥有的 `launcher.js`，随后通过变量动态导入已经打包的单文件插件。该进程只允许读取这一个文件，关闭网络、环境、写入、子进程、FFI 与系统信息权限，不允许交互授权或运行时拉取远程/npm 依赖。

子进程使用明确的环境变量和独立缓存。`--max-old-space-size=128` 仅约束 V8 堆，不能当成总内存或 CPU 配额；单个进程可由宿主终止。不能据此宣称已能安全运行任意恶意插件。

本次构建的是仓库内已知样例。未来产品应接收已构建的插件包，并在受控环境构建外部源码；不要在拥有宿主权限的 Bun 构建过程中加载未知插件及安装脚本。

## 验证

```sh
cd spikes/plugin-boundary
bun install --frozen-lockfile
bun run verify
```

`bun test` 单独运行四个运行边界与网关实验；`bun verify-webview.ts` 运行真实 WKWebView 的协议场景，输出 `pass` 和各项读数，不截图、不做视觉验收。二者都依赖先运行 `bun run build`。

iOS 模拟器使用同一场景：

```sh
xcrun simctl list devices available
bun verify-webview.ts --ios <模拟器 UDID>
```

该脚本使用 iOS 27 SDK 构建临时 App，运行后卸载；如果由脚本启动模拟器，结束时也会关闭模拟器。不会打开 Simulator 窗口或截屏。

Mac 与 iPhone 17 模拟器的 WKWebView 场景均已通过：首次打开、重建视图、重启 Deno 后再打开均完成握手并读取同一待办；各收到三次尺寸通知、三次卸载确认和主题变更。插件访问父页面、localStorage、原生桥或未授权工具均被拒绝；工作区授权读取成功，越界读取被拒绝。网络检查同时要求 fetch 失败和 `connect-src` 的 CSP 违规事件，避免把普通网络错误误判为隔离成功。

| 场景 | 2026-09-30 实测结果 |
| --- | --- |
| Deno 权限、模块加载、进程终止与 MCP 网关 | 4 个测试通过 |
| Mac 原生 WKWebView | `pass: true`，进程退出码 0 |
| iPhone 17 模拟器原生 WKWebView | `pass: true`，进程退出码 0；探针卸载、模拟器关闭 |
| 实际 iPhone、跨机器远程连接 | 尚未验证 |

已验证的后端行为：

- 普通 JS 能执行；越界读取、写文件、读取环境、连接回环网络和启动子进程被拒。
- 静态导入、动态导入与 Worker 均不能执行 bundle 外的模块。
- 无限循环进程在发出 ready 后可被终止，并确认 PID 已退出。
- MCP 新增、完成、查询使用同一份状态；并发写入发生版本冲突时显式重试，Deno 重启后保留数据。
- 无令牌、伪造身份、未知工具和越界文件读取被拒；已授权的工作区读取成功。

## 进入产品前仍需完成

插件包与定义加载、安装授权、操作与模型工具的动态登记、实例状态事务和操作收据、断线后的快照与事件恢复、正式 App 的 Web 视图适配、真机验收，以及进程的资源限制和异常清理。

窗口重建与插件进程重启是本实验的恢复范围；不等同于工作机断网、宿主崩溃和跨设备同步已经全部实现。此实验不启动真实模型，也不改变共享工作区的线程互斥规则。

## 上游依据

- [MCP Apps 概述](https://modelcontextprotocol.io/extensions/apps/overview)：UI 资源、工具与宿主桥接。
- [AppBridge API](https://apps.extensions.modelcontextprotocol.io/api/classes/app-bridge.AppBridge.html)：握手、工具调用、主题、尺寸与 teardown。
- [Deno 权限与静态模块图](https://docs.deno.com/runtime/fundamentals/security/)：初始加载、运行时权限及隔离限制；具体 API 以本实验锁定版本的声明和实测为准。
