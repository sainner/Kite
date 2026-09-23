# Kite

个人 agent 工作台：Mac 和 iPhone 上的原生 App，加上跑在工作机上的后台服务 kited，让 agent 在任意文件夹上工作。

- 文档、代码注释、提交说明都用简体中文。
- 上游优先，只做薄层。加机制之前先问：上游有没有？一个约定能不能解决？几行指令能不能解决？
- kited 怎么工作见 kited/README.md；被 Kite 管理的项目该长什么样见 kite-onboard skill（.claude/skills/kite-onboard/），Kite 仓库自己也按它来。
- spikes/ 是验证实验，保持原样，用来复现当时的结论，不当产品代码维护。
- kited 里起子进程一律显式传 env。`Bun.spawn` 不传 env 时用的是进程启动时的环境，不是改过的 `process.env`，测试里换掉的隔离环境会失效。

## 测试

改完代码跑 `.kite/check`，退出码为 0 才算通过。测试一律交给 test-writer 子 agent 写，交什么见它的说明；自己接着写实现，写完一起跑检查。
