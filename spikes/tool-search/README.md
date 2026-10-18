# tool search 实验（2026-10-18）

验证 deferred tools（tool search）在自研 harness 用的两条接口上能不能用：ChatGPT 订阅接口（`chatgpt.com/backend-api/codex/responses`）与 DeepSeek 的 Responses 兼容接口。请求格式按 OpenAI 的 [tool search 文档](https://developers.openai.com/api/docs/guides/tools-tool-search)；DeepSeek 的[接口文档](https://api-docs.deepseek.com/zh-cn/guides/responses_api)没有列出 `tool_search`。

| 用例 | 内容 |
|---|---|
| `hosted` | 声明 `tool_search` 和一个 namespace，里面的 `get_code` 标 `defer_loading`，看能否由服务端搜出再调用 |
| `client` | 只声明客户端执行的 `tool_search`；模型发出 `tool_search_call` 后回一个带 `get_code` 的 `tool_search_output`，看下一轮能否调用 |
| `persist` | `client` 跑完再问一轮，看加载过的工具不再搜索就能调用 |
| `additional` | 不声明工具，历史中间放一个 `additional_tools` 条目 |
| `size` | 同一个说明很长的工具：不带、直接声明、函数上标 `defer_loading`、放进 namespace 再标，比较输入用量 |

`allowed.ts` 另测 ChatGPT 订阅接口上 `tool_choice` 的 `allowed_tools` 与客户端搜索的配合，用例写在脚本开头。`claude.ts` 测 Claude 后端（Claude Code 自带的 ToolSearch），见文末。

用法：`bun probe.ts chatgpt|deepseek [模型] [用例...]`、`bun allowed.ts [模型] [用例...]`，缺省全跑。会真实发请求：ChatGPT 用 `~/.kite` 的订阅凭据；DeepSeek 用 `DEEPSEEK_API_KEY`，没有时照 kited 的做法从 Kite 账号凭据里取第一把 DeepSeek Key，凭据密钥只读、不新建。

## 结果

每个组合跑一次，DeepSeek 两个型号的 `client` 各跑了三次，结果一致。

| 用例 | gpt-6-luna | gpt-6.1-sol | deepseek-flash | deepseek-v4-pro |
|---|---|---|---|---|
| `hosted` | 服务端搜索后调用 | 未测 | 直接调用，没有搜索步骤 | 未测 |
| `client` | 通过 | 通过 | 通过 | 不通过：没发出 `tool_search_call`，把搜索写成了正文 |
| `persist` | 通过 | 通过 | 通过 | 不通过 |
| `additional` | 通过 | 未测 | 不通过：模型回答没有工具 | 未测 |
| `size`（不带 / 直接 / 函数标 / namespace 标） | 84 / 2783 / 2722 / 369 | 同左 | 328 / 2985 / 2985 / 2995 | 391 / 3048 / 3048 / 3051 |

- ChatGPT 订阅接口与公开 API 的文档一致：服务端搜索、客户端搜索、`additional_tools` 都能用。`defer_loading` 放在 namespace 里才明显省用量；文档说单个函数主要推迟参数定义，这里长的是说明，所以几乎不省。
- deepseek-flash 能用客户端搜索，加载的工具在后面的回合不用再搜。`defer_loading` 被忽略：直接声明和标了的用量相同，`hosted` 里模型不搜就直接调用。`additional_tools` 被忽略。
- deepseek-v4-pro 的 `client` 三次输入都只有 119 个 token，比 flash 少了 `tool_search` 的定义，像是这个工具被整个丢掉了。
- 两家共同能用的只有客户端执行的搜索：工具定义经 `tool_search_output` 追加在历史里，不改动请求开头的工具声明。

### allowed_tools（gpt-6-luna，各跑一次）

| 用例 | 结果 |
|---|---|
| `allowed_tools` 里写 `{type: "tool_search"}` | 400：不支持这个类型 |
| 把 `tool_search` 当函数名写进 `allowed_tools` | 400：`tools` 里没有这个函数 |
| `allowed_tools` 只列别的函数 | 模型搜不了，反复调列出的函数 |
| 搜索那次不限制，加载后 `allowed_tools` 列上加载的函数 | 接口接受，模型调用它（它不在顶层 `tools` 里） |
| 加载后 `allowed_tools` 不列加载的函数 | 模型调不了它 |

- `allowed_tools` 能限制经搜索加载的函数，但列不进 `tool_search`：只要用了 `allowed_tools`，这次请求就不能搜索。

适用限制：每项只跑了一到三次，只测了上表的型号，没有看缓存命中（`cached_tokens`）。

## Claude 后端（2026-10-19，CLI 2.1.280）

`claude.ts` 直接引用 kited 当前的 Claude 配置启动 Claude Code，所以重跑的结果跟着 kited 的配置走。kite 服务整体不设常驻；`read` 单独设 `alwaysLoad`，插件工具 `todo_add` 不设。用法见脚本开头：`fake` 接假端点，抓首个主循环请求；`real` 与 `resume` 用本机默认的 Claude 登录发真实请求，会话文件写在 `~/.claude/projects` 下。模型用 sonnet。

| 用例 | 结果 |
|---|---|
| `fake`，`tools: []`，`ENABLE_TOOL_SEARCH` 为 `true` 或 `force` | 没有 ToolSearch，`todo_add` 照常声明：按需加载整个失效 |
| `fake`，内置工具全集 | 有 ToolSearch；`read` 常驻，`todo_add` 不在声明里，声明里多一个标 `defer_loading` 的 `DeferredToolPlaceholder` |
| `fake`，`tools: ['ToolSearch']` | 声明只有 ToolSearch、占位和 `read`；连跑 6 次，`read` 都在首个请求里 |
| `real`，系统提示列出 `mcp__kite__todo_add` 或裸名 `todo_add` | 模型按关键词调 ToolSearch，结果是 `tool_reference`，接着调用成功 |
| `resume` | 新进程接着同一会话，不再搜索，直接调用 |
| `resume … strip` | 历史里有 `todo_add` 调用但没有 ToolSearch 记录（相当于从自研 harness 交接过来），接口照常接收，模型直接调用成功 |
| 加上 `CLAUDE_AGENT_SDK_MCP_NO_PREFIX=1`，`fake` 与 `real` 各一次 | 工具用裸名：声明里是 `read`，ToolSearch 的结果指向 `todo_add`，搜到后调用成功 |

- 表中除最后一行外，各行都是在 kited 加上 `CLAUDE_AGENT_SDK_MCP_NO_PREFIX` 之前跑的，工具名带 `mcp__kite__` 前缀。
- 关了附件（`CLAUDE_CODE_DISABLE_ATTACHMENTS`）以后，CLI 不在请求里列出推迟加载的工具名，模型要从宿主给的上下文里知道有哪些。
- 读 2.1.280 的代码可知：开了 ToolSearch、又是流式输入时，CLI 启动只等整体设了 `alwaysLoad` 的 MCP 服务；`CLAUDE_CODE_MCP_STARTUP_WAIT_MS` 设成正数，就等所有服务连上，以它为上限。实验里没遇到没等上的情况。

适用限制：真实请求每项只跑了一次，只测了 sonnet。
