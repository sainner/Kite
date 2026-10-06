# Bun 插件宿主

本文面向 Bun 插件作者，规定包格式、MCP 接口、状态、授权与 Web 视图限制。定义、实例和窗口的共同边界见 [Agent 与插件契约](Agent与插件契约.md)，App 安装与管理见 [App](App.md#插件与实例管理)。

## 安装与创建

管理 API 沿用 `X-Kite-Machine`。HTTP 信任本机客户端和经组网验证的同账号设备；插件进程不能访问本机 HTTP，也不继承宿主认证环境。

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

`lifetime` 必填：`window` 表示随最后一个窗口关闭回收，且必须声明至少一个视图；`persistent` 表示独立存续，关闭窗口保留状态和进程。没有视图的独立实例使用 `views: []` 并省略 `defaultView`。视图声明为 `{id, title, resourceUri}`，资源须使用 `ui://` URI。`kite.*` 保留给宿主，manifest 不接收系统身份或自动授权。包上限 4 MiB；安装不构建源码或运行安装脚本。单文件包须包含第三方依赖；运行时关闭自动安装和 `.env` 加载。

相同 ID 和内容可重试；不同内容不能覆盖已有定义。当前升级使用新的定义 ID，实例绑定创建时的包内容，重启时发现内容变化会拒绝执行。

独立存续的无窗口实例通过 `POST /workspaces/:id/plugin-instances` 创建：

```json
{ "id": "客户端生成的 UUID", "definitionId": "custom.todo.v1", "title": "待办" }
```

相同实例 ID 与创建参数可重试。带视图的插件通过现有窗口接口创建实例并打开默认视图；`window` 定义须同时创建实例与首窗口，不能单独创建无窗口实例。

窗口关闭后的回收、清理失败与迟到重试，统一遵守 [实例生命周期](Agent与插件契约.md#33-plugininstance工作区中的业务对象)。

### App 管理入口

设置中安装插件定义，工作区添加入口创建实例，实例菜单管理视图、进程和授权。完整交互、草稿与冲突处理见 [App](App.md#插件与实例管理)。Bun 插件当前使用固定执行边界，不提供 agent 的执行授权编辑页。

## MCP 与能力桥

插件通过 MCP stdio 提供工具与资源，进程受 [共同沙箱边界](Agent与插件契约.md#71-插件与-harness-共用操作系统沙箱) 约束。

| HTTP 管理入口 | 含义 |
| --- | --- |
| `GET /instances/:id/plugin/tools` | 启动或连接该实例，读取 MCP 工具列表 |
| `GET /instances/:id/plugin/views/:viewId` | 加载已声明的 MCP Apps HTML，返回 `{html, resourceUri}` |
| `POST /instances/:id/plugin/tools/:tool` | `{operationId, arguments}` 调用工具 |
| `GET /instances/:id/plugin/resources?uri=...` | 读取插件提供的 MCP 资源；宿主不抓取其中的链接 |
| `GET /instances/:id/plugin/process` | `stopped / running / blocked` |
| `DELETE /instances/:id/plugin/process` | 停止并确认进程组退出，保留实例、状态和收据 |

工具操作的 `operationId` 收据由宿主持久保存。相同请求重试返回保存的结果，参数不同则拒绝；已提交但连接中断、取消或超时返回 `outcome: unknown`，不自动重放。工具自行返回的 MCP `isError` 也保存为本次结果。查询实例状态后，用户可以决定是否用新的操作 ID 发起新动作。握手和列表/资源请求限时 5 秒，工具调用限时 30 秒；工具超时后终止进程。

调用可能并发，插件修改共享状态须检查版本，不能依赖请求到达顺序。工具声明不能获得额外的工作区写入权限。工作区归档和 kited 正常关闭会停止相关插件。宿主异常退出后，无法确认旧执行结束时返回 `blocked`；须在工作机核查残留执行，不自动重放请求。

插件通过自定义 MCP request 调用三个宿主入口：

| 方法 | 参数 | 结果 |
| --- | --- | --- |
| `kite/state.get` | `{}` | `{revision, value}` |
| `kite/state.replace` | `{expectedRevision, value}` | `{revision, value}` |
| `kite/operation` | `{name, arguments}` | `{value}`，或 MCP 错误 |

`value` 是本实例的 JSON 对象，最大 1 MiB。状态由宿主持久保存并属于当前实例；变化通过工作区事件通知。替换失败或版本冲突不自动重试。插件无需也不能直接访问数据库。

`kite/operation` 复用 [实例操作与授权](实例操作.md)。调用方和工作区固定在 MCP 连接上，参数不能指定另一身份；默认没有业务授权。管理端通过既有 `operation-grants` 接口给实例授权，例如只允许 `files.read` 访问同工作区某个文件实例。每次回调重新核验，撤回立即影响后续调用。凭据、数据库、会话等宿主保护目录仍禁止读取。

## 模型工具与插件间调用

管理端通过 `PUT /instances/:agentId/operation-grants` 授权具体的插件实例与 MCP 工具；自研 harness 须在首次模型请求前登记所需声明。例如待办插件：

```json
{
  "expectedRevision": "GET operation-grants 返回的 revision",
  "grants": [
    { "operation": "plugin.call", "instanceId": "待办实例 ID", "tools": ["todo_list", "todo_add", "todo_complete"] }
  ]
}
```

PUT 替换整个授权列表；需要保留的 agent 或文件授权一并传入。工具名称、说明和输入 schema 必须来自目标实例的 MCP 声明，客户端不能提交替代 schema。同名工具按目标实例区分；模型只填写原工具参数，目标、调用身份与操作 ID 由宿主绑定。显式插件授权独立于 agent 的内置工具选择，默认没有插件授权。

自研 harness 的工具声明须在首次请求前登记；之后只能撤回或恢复，新增需要新会话。Claude 的工具集合在下次进程启动或恢复时生效。通知与撤权规则见 [线程通知投递](线程通知投递.md)。

调用以当前授权和已登记的声明为准；目标声明变化时拒绝执行，输入和输出须符合登记的 schema。已发出的模型请求不能绕过撤权。`_meta.ui.visibility: ["app"]` 的工具不能授予模型或其他插件；未声明 visibility 时按 MCP Apps 默认对 model 和 app 开放。HTTP 工具入口只调用允许 app 的工具。要求 MCP task 执行的工具暂不登记为模型工具。

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

UI、模型和插件的收据按调用方及目标实例隔离。相同动作重试返回已保存的结果。MCP `isError` 映射为模型工具错误；提交前取消为未执行，提交后失联为结果未知。harness 不根据插件的 `readOnlyHint` 开启并行执行。

## 执行边界

### App 视图

插件 HTML 在隔离的 MCP Apps 视图中运行，原生容器负责标题栏、停靠和控制区。网页不能更换绑定的工作机或实例，不能访问宿主页存储、直接调用管理接口或取得宿主凭据。

视图资源必须是单条、同 URI、最大 2 MiB 的 `text/html;profile=mcp-app` 文本。首期支持内联 JS / CSS 和 data 图片、字体；声明非空网络、嵌套页面或设备权限时明确拒绝。视图不得发起外部连接、加载远程资源、提交表单或跳转外部页面；网页本地数据不承诺持久保存。插件如需工作区能力，由其工具经过原有授权桥调用。

网页 `callServerTool` 只调用本实例允许 app 访问的 MCP 工具，写操作不自动重试，未知结果沿用持久收据语义。卸载视图后拒绝该视图的后续原生调用，插件进程仍归工作机管理。显式关闭最后一个共享窗口时，工作机按生命周期决定是否停止进程；停止导致已提交调用失联时，沿用结果未知的收据语义，不自动重放。

当前实例状态变化通过 `notifications/resources/updated` 通知视图，URI 为当前视图资源；视图应重新读取状态。重连或重新打开后也须以工作机内容为准。主题和容器尺寸通过 `hostContext` 通知；网页报告的内容尺寸不会改变工作区布局。

### 工作机进程

插件使用 Bun，与 Kite 的命令工具共用操作系统沙箱。插件代码与必要运行时文件只读，临时空间可写。进程不继承宿主环境，不能直接读工作区或其他插件包，网络默认关闭。工作区能力走上面的授权桥。首期插件不开放额外目录或网络的 OS 授权编辑，`execution-grants` 管理入口只面向支持该能力的 agent 实例。

MCP 单条消息限制 2 MiB，诊断输出可能截断；这些限制不等同于 CPU、总内存或请求速率配额。当前停止确认覆盖受管进程组，恶意脱离进程组的后台任务尚未支持；Linux 仍待实机验证。文件沙箱不等于对任意恶意插件的完整资源治理。

## 仓库内样例

`kited/examples/todo-plugin.ts` 提供 `todo_list / todo_add / todo_complete` 和 MCP Apps HTML 资源，`todo-view.ts` 提供列表、新增和完成界面。它们通过宿主状态接口共享待办。可在 `kited` 目录构建已知样例：

```sh
node_modules/.bin/bun run build:todo-plugin
```

输出 `build/todo-plugin.json`，可在 App 设置中导入，也可直接作为 `POST /plugin-definitions` 的请求体。App 从“添加 → 待办”创建实例与窗口；在新 agent 的实例设置中授予同一待办实例的工具后，模型和界面使用同一份状态。停止插件进程后重新打开视图或调用工具会恢复该实例；并发更新仍检查状态版本，失败会展示错误，不自动重放修改。

`node_modules/.bin/bun run preview:todo` 在临时目录启动独立演示服务，使用本机 5483 端口，准备待办窗口和已授权但未运行的代理。它不调用模型、不读取用户的 kited 数据；Ctrl-C 后清理演示目录。已有服务占用端口时不会停止它。

宿主页开发与构建入口见 [kited README](../kited/README.md#插件开发)。真实 WebKit 协议检查见 [手动验证入口](../kited/test/manual/README.md)。Mac 与 iPhone 模拟器已验证握手、父页面/存储/网络隔离、主题、资源更新、teardown 和关闭后的原生桥拒绝；真机与远程多设备使用仍待验收。

上游参考：[MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/)、[MCP Apps 工具可见性](https://apps.extensions.modelcontextprotocol.io/api/documents/patterns.html)、[Bun 环境变量与自动加载](https://bun.sh/docs/runtime/environment-variables)。
