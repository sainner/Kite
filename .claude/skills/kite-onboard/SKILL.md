---
name: kite-onboard
description: 按 Kite 项目规范体检和补齐一个项目文件夹：目录结构、.gitignore、AGENTS.md、记忆目录，能判断改坏没有的项目加 .kite/check，代码项目再加 test-writer 子 agent。项目接入 Kite、新建项目、整理项目结构、写 AGENTS.md 或测试规则时用。
---

# Kite 项目规范

本 skill 检查准备接入 Kite 的本地文件夹。Kite 的项目以远程仓库为身份；添加文件夹时 Kite 只读它，不往里写：有 origin 的按远程登记，没有的导入到 Kite 自己的仓库，普通文件夹按 .gitignore 与 .gitattributes 模板提交初始版本，模板只进 Kite 的仓库。之后的工作都在 Kite 建的工作区里做。身份与添加项目的契约见 [项目与远程仓库](../../../docs/项目与远程仓库.md)。

体检和补齐的原则：缺什么补什么，已有的不动；要改用户已有的文件，先说明要改什么、为什么，得到同意再改。

## 一个项目长这样

```
论文项目/
├── .git/                  版本库，访达默认看不到
├── .gitignore             Kite 导入普通文件夹时按 templates/gitignore 提交；已有仓库不改。.env 这类环境变量文件要被它忽略
├── .env                   被忽略的环境变量文件不进 git：添加项目时存成项目密钥并设好路径，Kite 建工作树时写进去
├── .gitattributes         Kite 初始化时写入 templates/gitattributes：记忆索引按行合并，各工作区同时追加不冲突
├── AGENTS.md              给 agent 的项目说明，唯一的指令源；按 templates/AGENTS.md 写
├── .claude/
│   ├── agents/
│   │   └── test-writer.md 代码项目提供。写测试的子 agent，测试规则都在这里；按 templates/test-writer.md 写
│   ├── rules/             只在碰到特定路径时适用的约定
│   └── settings.json      上游设置
├── .kite/
│   ├── memory/            项目共享记忆，MEMORY.md 做索引，正文按需读取；
│                          在 Kite 之外直接用 Claude Code 时，另核对 autoMemoryDirectory
│   ├── setup              可选。工作树的初始化命令，如装依赖；只用退出码报告成败
│   ├── preview/           可选。预览目标：产品的每种运行方式一个可执行文件，如开发服务器、跑在模拟器上的 iOS App、
│                          Mac App、装到 iPhone；文件名即目标名；在终端环境里运行、不加沙箱，写法见下文
│   └── check              检查命令：判断这个项目改坏了没有。代码项目是类型检查加受影响的测试，加 --all 跑全量
│                          受影响的测试从 KITE_BASE 这个版本起算改动，没有这个变量就看还没提交的改动
│                          只用退出码报告成败；输出只报结论、失败项和超预算项，完整日志写进 KITE_LOG_DIR 并给出路径
├── docs/                  可选。设计原则、职责边界、必要的对外契约与开发入口
├── assets -> 资源库里这个项目的目录（链接本身进 git，大文件本体在资源库）
└── 正文文件……
```

不在项目里的：会话记录、会话的工作树、Kite 的快照（在 `.git` 里的 `refs/kite/`，不建分支）、大文件本体、只关于某个人的记忆。

## 体检和补齐

按顺序检查，每一步只补缺的：

1. **git 仓库**：不是仓库就停下，提示用户在 Kite 里添加这个文件夹，由 Kite 导入到自己的仓库，之后在 Kite 的工作区里继续。
2. **.gitignore**：Kite 导入的仓库应当是 templates/gitignore 的内容；已有的仓库用它自己的，不改，只检查 .env 这类环境变量文件有没有被忽略。
3. **.gitattributes**：没有就按 templates/gitattributes 写。已有的缺记忆索引那一行，说明并得到同意后追加，其余规则不动。
4. **大文件**：列出项目里按 templates/gitignore 属于大文件类型、却被 git 跟踪的文件，建议挪进资源库，不自动挪。
5. **AGENTS.md**：没有就按 templates/AGENTS.md 写，尖括号处向用户问清楚或从项目里读出来再填。已有的不重写，只检查代码项目有没有「测试」一节。
6. **不放 CLAUDE.md**：Claude Code 在项目没有 CLAUDE.md 时直接读 AGENTS.md。已有 CLAUDE.md 且只有一行 `@AGENTS.md` 的，建议删掉；内容不同的，提示用户把内容并进 AGENTS.md 后再删，不自己合并。
7. **记忆目录**：在 Kite 之外直接用 Claude Code 的机器上，在 `.claude/settings.local.json`（不进 git）里把 `autoMemoryDirectory` 设成本项目 `.kite/memory` 的绝对路径，否则记忆写进用户目录（`~/.claude/projects/…/memory/`）。上游只认绝对路径或 `~/` 开头的路径，所以不写进提交的 `.claude/settings.json`。用户目录里已有的、关于这个项目的记忆，挪进来。
8. **检查**：能判断「改坏了没有」的项目提供 `.kite/check`，契约见上面的目录图，写法见下一节。代码项目再按 templates/test-writer.md 写 `.claude/agents/test-writer.md`，分层表里填本项目的小、中、大各指什么。
9. **报告**：补了哪些文件；哪些需要用户决定。

## .kite/check 怎么写

检查回答的是「这个项目改坏了没有」，不只代码项目有。能快速判断的都可以放进来，比如：论文项目编译出 PDF、没有未定义的引用和缺失的图；数据分析项目在一小份样本数据上把流程跑通；网站能构建、站内没有坏链接。

检查一慢，人和 agent 就会少跑、跳过。下面几条以代码项目为例，都是为了让它快、可信；别的项目取其中适用的（先快后慢、只看改动、只报结论、不漏报）：

1. **检查项少而准**。只收能挡住 agent 常犯、而类型检查和测试挡不住的错。先用语言自带的开关（比如编译器的严格选项），不够再加工具；工具只开有具体理由的规则，不开风格类的：agent 会照着周围代码的风格写。Kite 仓库的 lint 只开了两条：没接住的 Promise、把异步函数交给只接同步回调的地方。
2. **先跑快的静态检查，再跑测试**。类型检查、lint 这类几秒就能报出来，互不依赖的同时跑，不用等测试。
3. **只跑受影响的测试**。沿 import 关系，从改动的文件找到依赖它们的测试，尽量用语言工具自带的功能（Bun 的 `bun test --changed`、Jest 的 `--findRelatedTests`、pytest 的 testmon 插件），不自己造依赖图。改动从 `KITE_BASE` 起算，没有这个变量就看还没提交的改动。依赖清单、锁文件、测试配置变了，依赖图看不出影响范围，跑全量。没有受影响的测试就直接通过。
4. **按层分开跑**。小测试和中测试放在不同目录，检查命令按目录分层。小测试互不相干，按文件分到多个进程并行跑；中测试要起外部进程，并行就是同时起好几个、抢内存，按顺序跑。
5. **按预算核对**。跑完读测试报告：单个测试超上限、中测试个数超上限、全量超时，都判失败。不在分层目录里的测试也判失败。
6. **输出只报结论**。通过时一行；没通过时只列失败项和超预算项，完整日志写进文件并给出路径，不把几千行测试输出塞进 agent 的上下文。日志目录由调用方通过 `KITE_LOG_DIR` 指定；没有这个变量时，每次自己建一个临时目录，不写在固定位置，免得同时跑的检查互相覆盖。
7. **不漏报**。测试进程出错退出、报告里却没有失败项（比如某个文件一加载就出错），也判失败；报告里一个测试都没有时，分清是「没有受影响的测试」还是「没跑起来」。

在 Kite 会话里，agent 通过 shell 调用 `.kite/check`，没有专用 check 工具或宿主检查排队保证。调用方可显式提供 `KITE_BASE` 和 `KITE_LOG_DIR`；未提供时按上面的未提交改动和临时日志目录规则执行。项目自己的 AGENTS.md 规定何时检查，不能假设工具会自动补足基线、日志归档或排队。

Kite 仓库自己的 `.kite/check` 是一个例子：它调 `kited/scripts/check.ts`，类型检查和 lint 同时跑，App 有改动时构建 macOS 和 iOS 模拟器目标，用 `bun test --changed` 选测试，小测试按文件分到两个进程并行运行。

## 预览目标怎么写

契约见 Kite 仓库 docs/实例操作.md 的「预览」与「目标」。一个目标是产品的一种运行方式，用户在新建窗口里点选，agent 用 preview_open 起；脚本要可执行（`chmod +x`），经用户的登录 shell 运行，环境同用户开的终端。起出来的预览实例就是脚本这棵进程树，画面由它产生什么决定：监听了网页端口就是网页，装进工作区的模拟器就是模拟器，起了带窗口的 Mac App 就是 App 窗口；脚本退出实例就结束。

1. **监听 `$PORT`**。Kite 给每个工作区的每个目标（装到几台设备时每台各一段）分一段 10 个端口，`PORT` 是第一个，也是网页画面的主端口。框架会读 `PORT` 的直接用，不读的传给它的端口参数，比如 `exec bun run dev --port "$PORT"`；同一目标另起的服务用 `PORT+1` 往后。不写死端口，否则并行的工作区互相抢。
2. **服务留在前台，最后一步用 `exec`**。不加 `&`、不守护化：脱离进程树的服务探测不到端口，停实例时也停不掉。前端加接口这类要几个服务的，在一个目标里一起起，别拆成两个目标。
3. **启动 Mac App 时直接运行可执行文件**，比如 `exec 记账.app/Contents/MacOS/记账`，不用 `open`。这样 App 就是实例的进程：输出进实例，停止就是退出，重启就是重新构建再打开，App 窗口画面也只认实例进程树里的 App。用 `open` 时脚本打开 App 就结束，App 和实例脱钩，旧的得自己想办法关，画面里也看不到。Mac App 打成 .app 再跑它里面的可执行文件，别的 Mac 才能从画面里把它装过去。
4. **装到真机的目标跑完就退出**，比如用 `devicectl`、`adb` 装到真机，实例随之结束，画面在设备上。iPhone、iPad 装到 `$KITE_DEVICE`：用户在设备列表里选了与工作机配对过的真机时（agent 装真机要经用户批准），Kite 把它的编号经这个变量交给脚本，比如构建时用 `-destination "generic/platform=iOS"`，再 `xcrun devicectl device install app --device "$KITE_DEVICE" 路径/记账.app` 和 `xcrun devicectl device process launch --device "$KITE_DEVICE" 包名`。选的是模拟器时没有这个变量、有 `KITE_SIMULATOR`；一个脚本可以两种都支持：有 `KITE_DEVICE` 装真机，否则装模拟器。
5. **iOS App 装到 `$KITE_SIMULATOR`**。脚本里写到 `KITE_SIMULATOR` 的，Kite 先按选的模拟器型号（没选用默认型号）给工作区建一台专用的模拟器（不启动），编号经这个变量交给脚本，并行的工作区各用各的。脚本自己启动、安装和打开，比如 `xcrun simctl bootstatus "$KITE_SIMULATOR" -b`，构建时用 `-destination "id=$KITE_SIMULATOR"`，再 `xcrun simctl install "$KITE_SIMULATOR" 路径/记账.app` 和 `xcrun simctl launch --console-pty "$KITE_SIMULATOR" 包名`；带 `--console-pty` 时 App 的输出进实例，脚本留在前台，停实例就停 App。不要用 `booted`，也不要开 Simulator.app。
6. **只放运行方式。** 装依赖放 `.kite/setup`；构建、迁移、跑测试不是运行产品，不做成目标，agent 用 shell 跑。
7. 改过的目标和主线上的不一样，agent 起它之前要用户批准一次；合回主线后不再问。

## 测试规则为什么放在子 agent 里

写测试和写实现分开：主 agent 写实现，test-writer 只照需求写测试，看不到实现，所以测试检验的是需求，不会复述实现。哪些需求要测由主 agent 定：它看得到代码，只交看代码确认不了、要跑起来才知道对不对的。所以准入标准要写进 test-writer 的描述（description），主 agent 每轮都看得到描述，看不到定义正文。两边可以并行，前提是动手前先把需求和接口写下来。测试规则只在这个子 agent 工作时加载，平时不占上下文。

templates/test-writer.md 分层表里的数字是默认预算，项目可以按实际资源开销调整，并说明原因；以该项目检查脚本能执行的预算为准。

## 知识入口

| 知识 | 放哪 | 加载方式 |
|---|---|---|
| 始终适用的约定 | AGENTS.md | 每轮加载 |
| 只在碰到特定文件时适用的约定 | `.claude/rules/*.md`，用 `paths:` 限定 | 碰到对应路径时注入 |
| 项目背景、决定理由、反馈与未决事项 | `.kite/memory/`，一事一文件，`MEMORY.md` 做索引 | 开始任务读取索引，正文按需读 |
| 设计原则、职责边界、对外契约与开发入口 | `docs/` | 经项目入口按需读取 |

准入与退出规则以 [Kite 的知识分工](../../../AGENTS.md#持久知识的分工与准入) 为主来源，不在此复制。与本项目工作方式有关的用户反馈可以进入项目记忆；无关的个人画像不收录。完整主题和正式协作规则形成后，记忆只保留仍有独立价值的背景或入口。为其他项目补齐时采用其已有约定，不把本仓库记忆或个人偏好复制过去。

## 在 Codex 中使用

项目的知识正文不随开发工具复制两份。Codex 使用根目录的 `AGENTS.md`；其中明确要求开始时读取 `.kite/memory/MEMORY.md`、按需读取正文，工作中把长期有效的项目决定和反馈及时写回。Codex 自带的全局生成记忆和这份项目记忆分开，不能照搬 Claude 的 `autoMemoryDirectory` 设置。

已有 `.claude/skills/<技能>` 时，在 `.agents/skills/<技能>` 建相对软链接，Codex 原生支持这种发现方式。不要重复复制模板；它们可能同时被项目代码引用。

写测试的规则仍以项目的一份正文为准。为 Codex 添加 `.codex/agents/test-writer.toml`，用 `name`、`description`、`developer_instructions` 定义入口，指令要求先读该规则文件；可在 `.codex/config.toml` 的 `[agents.test-writer]` 中用 `config_file` 显式注册，路径相对配置文件。不要直接搬入 Claude 的 `tools` 字段，也不要额外指定用户没要求的模型或权限。

Kite 仓库自己的接入和验证方法见 `docs/Codex-开发环境.md`。给其他项目补齐时以那个项目的规则和路径为准；不覆盖已有 Codex 配置。
