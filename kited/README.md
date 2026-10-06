# kited

Kite 的工作机服务，管理项目、检出、工作区、插件实例和线程。新会话默认由自研 harness 执行，模型使用 ChatGPT 订阅；Claude Code 通过独立适配层接入。

完整使用说明、生命周期、接口和当前边界见 [工作机：使用与服务契约](../docs/kited.md)。

## 启动服务

macOS 安装成登录自启服务，在仓库根目录运行 `./install.command --service-only`；完整 App 使用 `./install.command`，首次配置选择本机执行后安装 kited。独立安装包、升级和卸载见 [macOS 安装与打包](../docs/macOS安装与打包.md)。

开发时仍可从源码前台运行：

在本目录安装依赖并使用项目固定的 Bun 1.4.2：

```bash
bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun run start
```

默认监听 `127.0.0.1:5483`，`KITE_PORT` 可改端口；`KITE_HOME` 默认 `~/.kite`，保存数据库、工作树与线程记录。命令行客户端入口是 `src/cli.ts`，用法见 [启动服务与 CLI](../docs/kited.md#启动服务)。

## 终端试用

先按 [设备登录说明](../docs/kited.md#终端试用) 为这台工作机授权，凭据保存于 `$KITE_HOME/auth/chatgpt/auth.json`；然后运行：

```bash
bun run harness --cwd /你的项目目录
bun run harness --resume <会话id>
```

终端入口直接操作指定目录；服务中的工作区负责工作树、快照和采纳。

## 代码地图

| 路径 | 职责 |
|---|---|
| `src/main.ts`、`daemon.ts`、`http.ts`、`cli.ts` | 服务与客户端入口、HTTP 和 SSE |
| `src/account/`、`catalog-publisher.ts` | 托管账号与目录服务、工作机目录上报；契约见 [托管账号与设备](../docs/托管账号与设备.md) |
| `src/kite.ts`、`model.ts`、`store.ts`、`events.ts` | 业务编排、领域对象、持久化与事件 |
| `src/instance-lifecycle.ts` | 实例与窗口创建、请求去重及回收 |
| `src/instance-configuration.ts` | 实例配置、授权变更与对应通知 |
| `src/runtime.ts` | 选择执行后端 |
| `src/transcript/` | 显示协议、事件流、公共记录投影、Claude 消息转换与历史缓存 |
| `src/harness/` | 自研模型循环、订阅接入、journal、上下文与会话宿主 |
| `src/claude/` | Claude Code 会话宿主、进程控制、原生历史与工具适配 |
| `src/execution/` | 共用沙箱、执行授权、文件工具、命令与进程组 |
| `src/workspace/` | 项目登记、工作树、Git、快照、文件与历史差异 |
| `src/plugins/` | 插件定义、安装目录、实例宿主、进程与工具绑定 |
| `src/operations/` | 实例操作契约、授权入口与操作收据 |
| `src/agents/` | Agent 定义、后端能力与共享模型清单入口 |
| `src/context-templates.ts` | 上下文模板目录 |
| `src/light-tasks.ts`、`thread-titles.ts` | 辅助模型任务与会话标题 |
| `web/` | 随 App 打包的可信插件宿主页源码 |
| `examples/` | 待办插件与视图样例 |
| `scripts/` | 项目检查、构建、macOS 打包安装和样例预览入口 |

## 检查与测试

在仓库根目录运行 `.kite/check`，加 `--all` 跑全量；检查内容见 `scripts/check.ts`。规则见 [test-writer](../.claude/agents/test-writer.md)。

| 路径 | 用途 |
|---|---|
| `test/small/` | 模块、临时 Git 仓库及集成逻辑，不起 Claude Code |
| `test/medium/` | 真实 Claude Code 进程与隔离的假模型端点 |
| `test/manual/` | Swift 解码合同、原生运行时和 WebKit 的验证，见 [入口表](test/manual/README.md) |
| `test/fixtures/` | 插件与协议探针输入 |
| `test/setup.ts`、`fake-api.ts`、`harness.ts` 等 | 测试隔离环境、假端点与公共辅助代码 |

## 大测试清单

升级 SDK 或 Claude Code 后的真实订阅验收见 [大测试清单](../docs/kited.md#大测试清单)。

## 插件开发

构建待办样例用 `bun run build:todo-plugin`，预览用 `bun run preview:todo`。修改 `web/plugin-host.ts` 后运行 `bun run build:plugin-web`，更新 App 的 `Resources/Generated/PluginHost.html`；详细契约见 [Bun 插件宿主](../docs/Bun插件.md)。
