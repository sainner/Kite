# Kite

个人 agent 工作台：Mac 和 iPhone 上的原生 App，加上跑在工作机上的后台服务 kited，让 agent 在任意文件夹上工作。

- 文档、代码注释、提交说明都用简体中文。
- 开始任务先读 `.kite/memory/MEMORY.md`，再按需读单条记忆。做事时把值得长期保留的项目决定和反馈写进这个目录，一事一文件并更新索引；已有事实过时就更新，不记任务流水账。这是项目记忆的唯一位置，各种 agent 共用，不另建一份。最新的后端方向见其中的「自研 harness 与 ChatGPT 订阅」。
- 上游优先，只做薄层。加机制之前先问：上游有没有？一个约定能不能解决？几行指令能不能解决？
- kited 怎么工作见 kited/README.md，App 的工程见 app/README.md；被 Kite 管理的项目该长什么样见 kite-onboard skill（.claude/skills/kite-onboard/），Kite 仓库自己也按它来。
- spikes/ 是验证实验，保持原样，用来复现当时的结论，不当产品代码维护。
- kited 里起子进程一律显式传 env。`Bun.spawn` 不传 env 时用的是进程启动时的环境，不是改过的 `process.env`，测试里换掉的隔离环境会失效。
- Codex 开发环境的记忆、子 agent 和 skill 入口见 `docs/Codex-开发环境.md`。

## 测试

改完代码跑 `.kite/check`，退出码为 0 才算通过。测试一律交给 test-writer 子 agent 写，规则正文在 `.claude/agents/test-writer.md`，Codex 入口在 `.codex/agents/test-writer.toml`；当前 agent 工具没有自动发现这个定义时，显式读取规则并交给写测试的子 agent。自己接着写实现，写完一起跑检查。
