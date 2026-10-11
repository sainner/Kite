# Kite

个人 agent 工作台：Mac、iPhone 和 iPad 上的原生 App，加上跑在工作机上的后台服务 kited，让 agent 在任意文件夹上工作。目前处于在研阶段，暂不部署。

## 项目入口

| 目录 | 职责 | 入口 |
|---|---|---|
| `app/` | Mac、iPhone、iPad 共用的 SwiftUI App | [编译与代码地图](app/README.md) |
| `kited/` | 工作机服务、命令行、自研 harness 与 Claude 适配 | [运行与代码地图](kited/README.md) |
| `shared/` | 工作机与验证脚本共用的数据，目前是模型清单 | [agent-models.json](shared/agent-models.json) |
| `docs/` | 产品设计原则、对外契约与开发入口 | [文档索引](docs/README.md) |
| `spikes/` | 保留当时结论的验证实验 | 不作为产品代码维护 |

Agent 的统一项目指引在 [AGENTS.md](AGENTS.md)，项目记忆入口在 [.kite/memory/MEMORY.md](.kite/memory/MEMORY.md)。

## 安装与打包

macOS 安装入口为 `./install.command`，安装 App 后在初始配置中选择本机执行即可安装后台服务。`./package-mac.command` 只生成安装包。两者都支持 `--service-only`，仅处理工作机服务。前提、安装位置、升级和卸载见 [macOS 安装与打包](docs/macOS安装与打包.md)。

## 开发

先在 `kited/` 安装依赖，使用项目固定的 Bun：

```bash
cd kited
bun install
export PATH="$PWD/node_modules/.bin:$PATH"
bun run start
```

服务默认监听 `127.0.0.1:5483`。模型授权与终端试用见 [kited README](kited/README.md)，App 用 Xcode 打开 `app/Kite.xcodeproj`。

修改后在仓库根目录检查：

```bash
.kite/check
```

加 `--all` 跑全量检查。需要 Swift 编译、原生运行时或 WebKit 的验证另见 [手动验证入口](kited/test/manual/README.md)。
