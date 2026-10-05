# Bun 插件宿主

工作机已接通预构建插件包、实例创建、MCP 工具与资源、实例状态、授权能力回调和 harness 模型工具。Mac / iPhone 的窗口容器已接 MCP Apps Web 视图，并提供插件包安装、实例创建与操作授权编辑入口。

## 安装与创建

管理 API 沿用 `X-Kite-Machine`。HTTP 当前只信任本机客户端；插件进程不能访问本机 HTTP，也不继承宿主认证环境。

`POST /plugin-definitions` 接收：

```json
{
  "id": "custom.todo.v1",
  "title": "待办",
  "lifetime": "persistent",
  "bundle": "预构建单文件 ESM JavaScript",
  "views": [{ "id": "list", "title": "待办列表", "resourceUri": "ui://kite-todo/list.html" }],
  "defaultView": "list"
}
```

`lifetime` 必填：`window` 表示随最后一个窗口关闭回收，且必须声明至少一个视图；`persistent` 表示独立存续，关闭窗口保留状态和进程。没有视图的独立实例使用 `views: []` 并省略 `defaultView`。视图声明为 `{id, title, resourceUri}`，资源须使用 `ui://` URI，登记后使用 `web` renderer。`kite.*` 保留给宿主，manifest 不接收系统身份或自动授权。包上限 4 MiB，写入 `KITE_HOME/plugins/`，不在宿主构建源码、运行安装脚本或加载入口模块。单文件包须包含第三方依赖；运行时关闭自动安装和 `.env` 加载。

相同 ID 和内容可重试；不同内容不能覆盖已有定义。当前升级使用新的定义 ID，实例绑定创建时的包内容摘要，重启时发现内容变化会拒绝执行。

独立存续的无窗口实例通过 `POST /workspaces/:id/plugin-instances` 创建：

```json
{ "id": "客户端生成的 UUID", "definitionId": "custom.todo.v1", "title": "待办" }
```

相同实例 ID 与创建参数可重试。带视图的插件通过现有窗口接口创建实例并打开默认视图；`window` 定义必须走这个原子入口，不能单独创建无窗口实例。

关闭最后一个共享窗口时，`window` 实例先停止插件进程并确认退出，再删除实例及其状态、配置，撤掉其他实例对它的授权。清理失败保留最后窗口和实例，供用户重试。关闭窗口与请求收据仍保留，旧请求和旧实例 ID 不会复活对象。最小化、退出 App、设备断线不触发回收；`persistent` 实例继续留在无窗口实例栏。

### App 管理入口

- **设置 → 管理插件定义**：查看内置与自定义定义；导入预构建 JSON 包，确认名称、视图和生命周期后安装到当前工作机。安装定义不启动实例。
- **工作区停靠栏的添加按钮**：弹窗只创建实例；有视图时同时打开默认窗口，无视图时创建后台实例。网络中断保留请求 ID，可显式重试。
- **已有实例**：无窗口实例保留在 Mac 右栏或 iPhone 底部栏；点击有视图的实例打开窗口。Mac 新窗口先放右侧全高列，空间不足则上下分栏，仍不足则收起一个非聚焦窗口；仅有一个旧窗口时收起它。远端新增窗口仍先进入本机停靠栏。
- **实例设置与授权**：右键／长按停靠图标或窗口标题栏，打开视图、查看及停止 Bun 进程，编辑该实例的 agent 操作、文件操作与插件工具授权。无视图的后台实例通过图标菜单管理。

工具列表按需读取。已有授权直接显示，撤权无需先启动目标插件。保存携带读取时的 revision，并保留未编辑的授权；冲突或失败保留草稿，重新读取前提示放弃修改。harness 在实例设置的「执行授权」页独立编辑工作区读写、额外路径和网络许可；Bun 插件仍使用固定沙箱。模型已接会话标题栏，创建会话的上下文模板已接设置编辑与新会话选择、复制；工具选择和请求预算等 agent 配置仍待界面接入。

## MCP 与能力桥

插件用 MCP stdio 服务提供工具和资源。Kite 使用上游 TypeScript SDK 2.2.0 处理协议与流；进程由共享 OS 沙箱启动器管理。

| HTTP 管理入口 | 含义 |
| --- | --- |
| `GET /instances/:id/plugin/tools` | 启动或连接该实例，读取 MCP 工具列表 |
| `GET /instances/:id/plugin/views/:viewId` | 加载已声明的 MCP Apps HTML，返回 `{html, resourceUri}` |
| `POST /instances/:id/plugin/tools/:tool` | `{operationId, arguments}` 调用工具 |
| `GET /instances/:id/plugin/resources?uri=...` | 读取插件提供的 MCP 资源；宿主不抓取其中的链接 |
| `GET /instances/:id/plugin/process` | `stopped / running / blocked` |
| `DELETE /instances/:id/plugin/process` | 停止并确认进程组退出，保留实例、状态和收据 |

工具操作的 `operationId` 收据由宿主持久保存。相同请求重试返回保存的结果，参数不同则拒绝；已提交但连接中断、取消或超时返回 `outcome: unknown`，不自动重放。工具自行返回的 MCP `isError` 也保存为本次结果。查询实例状态后，用户可以决定是否用新的操作 ID 发起新动作。握手和列表/资源请求限时 5 秒，工具调用限时 30 秒；工具超时后终止进程。

同一实例只用一个插件进程。HTTP 请求可并行，插件持久状态修改需比较版本；harness 按串行工具执行。工具声明不能获得额外的工作区写入权限。工作区归档和 kited 正常关闭会停止相关插件。宿主异常退出后若记录的进程组仍存活，新宿主返回 `blocked`，需先在工作机确认退出；不会凭旧 PID 自动杀进程或重放请求。

插件通过自定义 MCP request 调用三个宿主入口：

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `kite/state.get` | `{}` | `{revision, value}` |
| `kite/state.replace` | `{expectedRevision, value}` | `{revision, value}` |
| `kite/operation` | `{name, arguments}` | `{value}`，或 MCP 错误 |

`value` 是本实例的 JSON 对象，最大 1 MiB。状态由 SQLite 保存在实例的 `state.plugin` 中，避免与原生插件的状态字段混淆；变化通过既有 `workspace.changed` 通知。替换失败或版本冲突不自动重试。插件无需也不能直接访问数据库。

`kite/operation` 复用 [实例操作与授权](实例操作.md)。调用方和工作区固定在 MCP 连接上，参数不能指定另一身份；默认没有业务授权。管理端通过既有 `operation-grants` 接口给实例授权，例如只允许 `files.read` 访问同工作区某个文件实例。每次回调重新核验，撤回立即影响后续调用。凭据、数据库、会话等宿主保护目录仍禁止读取。

## 模型工具与插件间调用

在 agent 第一次模型请求前，管理端通过 `PUT /instances/:agentId/operation-grants` 授权具体的插件实例与 MCP 工具。例如待办插件：

```json
{
  "expectedRevision": "GET operation-grants 返回的 revision",
  "grants": [
    { "operation": "plugin.call", "instanceId": "待办实例 ID", "tools": ["todo_list", "todo_add", "todo_complete"] }
  ]
}
```

PUT 替换整个授权列表；需要保留的 agent 或文件授权一并传入。宿主通过 MCP 获取声明，保存到调用实例的 `config.pluginTools`，包含目标实例、原工具名、包与声明摘要、模型别名、说明和输入 schema。客户端不能提交替代 schema。`plugin_<摘要>_<原工具名>` 区分同名工具的不同实例；模型只填写原工具参数，目标、调用身份与操作 ID 由宿主绑定。显式插件授权独立于 agent 的内置工具选择，默认没有插件授权。

首次模型请求固定声明目录。后续撤回与恢复已登记工具只改变 `allowedTools`；增加新工具、换实例或更换声明需要新会话。授权更新与 `plugin.tools.changed` 通知同事务保存，下一次自然请求追加通知，不唤醒模型或改写历史前缀。每次请求快照的 `settings.pluginTools` 记录别名与实例、包、工具摘要的对应关系。

执行时重新核对工作区、调用方、目标及具体工具授权，并重新获取声明（忽略服务器缓存期限）。与登记声明不符则拒绝；输入由上游 JSON Schema validator 检查，输出由 SDK 按本次声明检查。已发出的模型请求不能绕过撤权。`_meta.ui.visibility: ["app"]` 的工具不能授予模型或其他插件；未声明 visibility 时按 MCP Apps 默认对 model 和 app 开放。HTTP 工具入口只调用允许 app 的工具。要求 MCP task 执行的工具暂不登记为模型工具。

插件间调用使用相同的 `plugin.call` 授权和操作入口：

```json
{
  "name": "plugin.call",
  "arguments": {
    "instanceId": "目标插件实例 ID",
    "tool": "todo_add",
    "operationId": "本次动作的稳定 ID",
    "arguments": { "title": "检查说明文档" }
  }
}
```

UI、模型和插件的收据按调用方及目标实例隔离。模型使用 `turnId:callId`；相同动作重试读取已保存的结果。MCP `isError` 映射为模型工具错误；提交前取消为未执行，提交后失联为结果未知。harness 不根据插件的 `readOnlyHint` 开启并行执行。

## 执行边界

### App 视图

`PluginPane` 沿用原生窗口标题栏、停靠和控制区，内部通过 `WKWebView` 加载随 App 打包的可信宿主页。宿主页用上游 MCP Apps `AppBridge` 与插件通信；插件 HTML 放在仅有 `allow-scripts` 的独立来源 iframe 中。原生消息只接受固定宿主页的主 frame，地址、工作机身份和实例 ID 由原生闭包绑定，网页不能选择其他实例或直接调用工作区管理接口。

视图资源必须是单条、同 URI、最大 2 MiB 的 `text/html;profile=mcp-app` 文本。首期支持内联 JS / CSS 和 data 图片、字体；声明非空网络、嵌套页面或设备权限时明确拒绝。宿主页 CSP 禁止外部连接、远程资源、表单提交和外部导航；WebView 使用非持久数据存储。插件如需工作区能力，由其工具经过原有授权桥调用。

网页 `callServerTool` 只调用本实例允许 app 访问的 MCP 工具，每次请求由宿主页生成独立操作 ID，使用原有持久收据；不会自动重试写操作。卸载视图发送 teardown 并移除原生桥，插件进程仍归工作机管理。显式关闭最后一个共享窗口时，工作机按生命周期决定是否停止进程；停止导致已提交调用失联时，沿用结果未知的收据语义，不自动重放。

App 取得工作区快照后，只在当前实例的 `state.plugin` 值变化时向其已打开的视图发送 `notifications/resources/updated`，URI 为当前视图资源；其他实例或窗口集合变化不触发查询。目录连接重连取得完整快照时强制刷新。待办样例监听通知并重新调用 `todo_list`，初次打开和重建视图同样读取工作机状态。主题和容器尺寸通过 `hostContext` 通知；网页报告的内容尺寸不会改变工作区布局。

### 工作机进程

插件继续使用 Bun，与 harness 共用 `prepareSandbox`。每次进程独立的代码副本只读，可写临时目录另设；必要的运行时系统文件只读。进程不继承宿主环境，不能直接读工作区或其他插件包，网络默认关闭。工作区能力走上面的授权桥。首期插件不开放额外目录或网络的 OS 授权编辑，harness 的 `execution-grants` 管理入口继续只用于 harness。

MCP 单条消息限制 2 MiB，stderr 仅保留 8000 字符诊断尾部。它们不等同于 CPU、总内存或请求速率配额。当前停止确认覆盖受管进程组，恶意脱离进程组的后台任务尚未支持；Linux 仍待实机验证。文件沙箱不等于对任意恶意插件的完整资源治理。

## 仓库内样例

`kited/examples/todo-plugin.ts` 提供 `todo_list / todo_add / todo_complete` 和 MCP Apps HTML 资源，`todo-view.ts` 提供列表、新增和完成界面。它们通过宿主状态接口共享待办。可在 `kited` 目录构建已知样例：

```sh
node_modules/.bin/bun run build:todo-plugin
```

输出 `build/todo-plugin.json`，可在 App 设置中导入，也可直接作为 `POST /plugin-definitions` 的请求体。App 从“添加 → 待办”创建实例与窗口；在新 agent 的实例设置中授予同一待办实例的工具后，模型和界面使用同一份状态。停止插件进程后重新打开视图或调用工具会恢复该实例；并发更新仍检查状态版本，失败会展示错误，不自动重放修改。

`node_modules/.bin/bun run preview:todo` 在临时目录启动独立演示服务，使用本机 5483 端口，准备待办窗口和已授权但未运行的代理。它不调用模型、不读取用户的 kited 数据；Ctrl-C 后清理演示目录。已有服务占用端口时不会停止它。

修改可信宿主页后执行 `node_modules/.bin/bun run build:plugin-web` 更新 App 内的 `PluginHost.html`；`.kite/check` 编译 App 前也会重建。真实 WebKit 协议检查见 `node_modules/.bin/bun scripts/verify-plugin-web.ts`，iPhone 模拟器加 `--ios <UDID>`，只检查事件与隔离，不截图。Mac 与 iPhone 模拟器已验证握手、父页面/存储/网络隔离、主题、资源更新、teardown 和关闭后的原生桥拒绝；真机与远程多设备使用仍待验收。

上游参考：[MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/)、[MCP Apps 工具可见性](https://apps.extensions.modelcontextprotocol.io/api/documents/patterns.html)、[Bun 环境变量与自动加载](https://bun.sh/docs/runtime/environment-variables)。
