# 科研人员与非程序员用 AI 编程 agent 的一手痛点（2026-09-23 调研）

目标用户：科研人员 / 研究生（非计算机专业为主）、运营、产品经理，用 Claude Code、Codex CLI、Cursor 等写 LaTeX、数据分析脚本、整理实验数据。

## 前置说明

- Reddit 全站对本环境的抓取器封锁，所以 r/PhD、r/GradSchool、r/LaTeX 等**零一手引用**；凡涉及 Reddit 的都是二手转述，已标明。
- 知乎专栏 / 小红书正文多数 403，只拿到少数几篇。
- HN 用 Algolia API 拿到了原文；GitHub issues 用 API 拿到了原文。

## 1. 不懂 git / 终端的人：文件改坏、误删、回不去

- "Claude Code executed rm -rf on user data folder containing 3,467 files (~7 GB) without confirmation"：让它整理医学指南 PDF，它先 move 再 move，最后把唯一副本目录删了。非开发者。 https://github.com/anthropics/claude-code/issues/46058 （2026-04-10）
- "worktree auto-cleanup permanently deleted 10 days of uncommitted project work without any warning"：用户不懂 worktree，10 天没 commit，新会话自动清理。 https://github.com/anthropics/claude-code/issues/46444 （2026-04-10）
- "/rewind (Esc Esc) silently reverts/loses code — destructive 'Restore code and conversation' is the default with no confirmation"：唯一的「撤销」入口本身默认是破坏性选项。 https://github.com/anthropics/claude-code/issues/64615 （2026-06-02）
- "combined the corrective copy with an unauthorized rm -rf to 'clean up'… approximately 1-1.5 weeks of work"：有备份但过期一周。 https://github.com/anthropics/claude-code/issues/24196 （2026-02-08）
- HN 讨论 Cowork 删 11GB："I don't think many non programmers will even know 'rm -rf' command and what it does." (pritambarhate) / "So.. He has no backups?" → "yes.. like most end users?" (HumanOstrich / sammyteee) https://news.ycombinator.com/item?id=46597781 （2026-01-13）
- Cowork 发布贴 HN：skybrian "Being able to undo any changes that Cowork makes seems important. Any plans for automatic snapshots or an undo log?" https://news.ycombinator.com/item?id=46593022 （2026-01-13）
- 二手：r/ClaudeCode 「Claude Code deleted my entire 202GB archive after (being told not to touch it)」 https://www.reddit.com/r/ClaudeCode/comments/1sbpfdl/ （转引自 aiqnahub，未能直接核实）
- 关键机制：/rewind 只回滚编辑工具的改动，**不覆盖 bash 命令**（rm/mv），而这正是真实丢数据的主因（yurukusa 恢复指南汇总了 #64392/#64310/#36339/#49129 等同类 issue）。 https://gist.github.com/yurukusa/9084bfd1efac7b4149aa3b3b1c9e2ac2
- 研究者侧变通：Patrick Mineault（神经科学）"Learn about branches. When Claude goes off the rails, you need to be able to roll back cleanly." https://www.neuroai.science/p/claude-code-for-scientists （2026-01-29）；Kevin Yang "Git is your best friend for vibe coding… you can roll back easily when things are messed up." https://yang3kc.substack.com/p/claude-code-is-secretly-an-excellent （2025-07-09）

**频率：很多人提。** GitHub 上是成体系的 issue 簇；每个研究者向导都把「先学 git 分支」当第一条。

## 2. 用 Claude Code 写 LaTeX / 论文

- 好用：CSDN 作者（算法方向研究生）"一句话就能出出版级图表"、数学排版能"发现逻辑漏洞"并补约束；卡：环境迁移超时排查"翻完日志后直接说没问题"，定位为"执行兵而非共同作者"。 https://blog.csdn.net/weixin_48708052/article/details/159042717 （2026-03-14）
- HN：neutronicus "Turn my slapdash notes into LaTeX with nice TiKz diagrams… incredible at everything besides physics and HPC." （2025-07-14, id 44563965）
- HN：mccoyb "It's quite good at matplotlib but terrible at any non-trivial LaTeX / TikZ layout or graphic." （2025-08-11, id 44868425）
- HN：cagey "It was agonizing directing Claude Code to create a (non-mathematical) preso using LaTex. I chose Typst… much better experience." （2026-06-16, id 48548863）
- 小红书（Claude Science 测评）："有时候复杂的图形，AI他妈的就是改不对，太崩溃了" https://www.xiaohongshu.com/explore/6a44faf6000000001101567d （2026-07-02）
- 引用编造：知乎/CSDN 多篇提到让 AI 写综述"作者、年份、期刊、页码"齐全但数据库查不到；psantanna 模板作者的动机 "Producing academic work is no longer the slow part. Checking it is."，并称植入 20 个 bug 后审稿 agent "reported everything was fine" https://psantanna.com/claude-code-my-workflow/ （2026-08）
- 工具层痛点：Claude Code 各界面**不渲染行内 $…$ 公式**是 issue 区高票（#16446 146 赞，#65777 61 赞）。 https://github.com/anthropics/claude-code/issues/16446 （2026-01-06）
- Overleaf 断层催生了一堆 MCP/同步工具（overleaf-mcp、vibeTeX、claude-to-overleaf），说明「协作者在 Overleaf、我在本地跑 agent」是常见摩擦。

**频率：很多人提**（好用 + 图/TikZ 卡 + 引用编造三件套反复出现）。

## 3. 跑数据分析 / 实验数据

- 保密：Paul Goldsmith-Pinkham（Yale 金融）"IRB data, PII, anything that should be on a HIPAA-compliant server—don't let Claude anywhere near it… If you wouldn't put it on Dropbox, don't put it in front of Claude." https://paulgp.substack.com/p/getting-started-with-claude-code （2026-03-29）
- HN Claude Science 帖：SubiculumCode "Connecting AI directly to the data sources… can get quite complicated in terms of meeting institutional policy, applicable law, data access-storage requirements (e.g. NIH data repositories)." https://news.ycombinator.com/item?id=48735770 （2026-06-30）
- 长任务：lebovic（同帖）"computational biology jobs sometimes run for hours on the… HPC. When they're done, the session needs to reawaken, process the results, iterate." （2026-07-01）
- 集群官方口径（Stanford Sherlock）："most coding agents send your prompts and code to external cloud services. Consider this when working with sensitive or unpublished research data." 且禁止在登录节点跑 agent。 https://www.sherlock.stanford.edu/docs/software/ai/coding-agents
- Notebook 摩擦：annzabelle（同帖）"Claude Code and Jupyter in VSCode don't play nicely together… forces me to rerun the whole notebook from the start after every edit Claude makes."；Mineault "Jupyter notebooks don't play well with Claude. Plots embedded in base64 eat context; notebooks are stateful" → 改用 marimo/jupytext。
- 信任成本：Mike X Cohen（神经科学）"With the amount of checking and re-analyses I did, I'm not sure that Claude made this research any faster than if I had done it AI-free." / "any code I use should be entirely written by me or entirely written by Claude and checked by me." https://mikexcohen.substack.com/p/claude-the-scientist （2026）
- Kevin Yang："When it comes to producing figures for publication, where precision is key, I found it easier to do it myself."

**频率：保密 + 信任/核查 很多人提；「跑很久要盯着」零星**（只有 HN 一条明确）。

## 4. 离开电脑后在手机上看进度 / 发消息

- 需求原话：simonbs "Sometimes Claude needs a reply while I'm brewing coffee. Sometimes Codex finishes a task while I'm away from my desk." https://simonbs.dev/posts/put-your-coding-agents-in-your-pocket/ （2026-04-24）；CCBot 作者 "When you step away — commuting, on the couch, at dinner — the session keeps working, but you lose visibility and control." （HN 47151158, 2026-02-25）
- 凑合做法（HN 一片）：Tailscale + Termius/Blink/Termux + tmux + mosh 是主流（postalcoder "I've been doing this for at least a year and a half" 46522217；ratsimihah 47786083；Jnr 46632288）；Telegram/WhatsApp 桥（franze "it whatsapps me when its done or needs input" 47785823）；ttyd 开浏览器（nihakue 48508743）。抱怨："tmux + claude code is definitely not great on mobile" (crashabr 46599580)。
- 官方 Remote Control 的坑：giancarlostoro "You can't interrupt Claude (you press stop and he keeps going!)… It can get stuck in plan mode" (47152438, 2026-02-25)；kzahel "One thing it does not do is let you create new sessions" (47150110)；issue 区：手机发的消息不到 CLI（#42671 #77369）、手机批准的权限不生效（#62553）、`--resume` 丢手机端 turn（#79470）、电脑睡眠 connector 挂 600 秒（#94887）。 https://github.com/anthropics/claude-code/issues/79470
- 台湾博主（自建 Telegram 桥后转官方）：仍缺 "group notifications or multi-person access"；手机端无 Bypass 模式；设了 `DISABLE_TELEMETRY` 或自定义 `ANTHROPIC_BASE_URL` 直接不可用。 https://ultralab.tw/en/blog/claude-code-remote-control-mobile-2026 （2026-08-25）

**频率：很多人提。但全是开发者口径，没搜到科研人员**说「实验跑着我想在手机看」的一手帖。

## 5. 非程序员用 Claude Code / Cowork 翻车

- Cowork 删 11GB（James McAulay 视频，r/ClaudeAI 转发）是标志性事件；国内 36kr/InfoQ 转述："意外导致约 11GB 的本地文件被删除或覆盖。建议在授予目录访问权限前先做好备份。" https://www.infoq.cn/article/0diNmKkv2y0MXOHKKXD2 （2026-01-26）
- 产品人视角（Claire Vo，经 Zvi 转引）：Cowork "asked for approvals on file openings too much" 且 "exposed too many technical files"。 https://thezvi.substack.com/p/claude-coworks （2026-01-13）
- HN：_puk "Cowork gets tangled with git as well. Fails, and then can't delete lock files." (48960530, 2026-07-18)
- 非码农订阅者第一坑：Bernard Burch "Got it all installed in Terminal, then realized you have to have a PAID plan." https://claudecodefornoncoders.substack.com/p/week-1-claude-code-for-non-coders （2025-09-08）
- Mineault 的警告等价于用户画像："Vibecoding without metacognition is quite dangerous."

**频率：Cowork 删文件很多人提（但多是转发同一事件）；运营/PM/写作者的具体翻车一手帖零星**（Substack 评论区付费墙挡住了）。

## 6. 「AI 记住我的项目规范 / 论文格式」

- GitHub 高票 issue："Claude forgets everything in CLAUDE.md after compaction… I have to tell it to re-read this every time it compacts, otherwise it starts doing things in 'common sense' ways" #6354 （2025-08-22, 30 赞）；"CLAUDE.md Mandatory Rules Consistently Ignored Across Multiple Repositories" #2544 （45 赞）；"/compact causes Claude Code to ignore CLAUDE.md" #4017。
- 学术侧的应对是把规范外置成仓库：Panos Ipeirotis（NYU）"It is like hiring a brilliant contractor who gets amnesia every morning… The repository is the conversation. It is the memory." https://www.behind-the-enemy-lines.com/2026/03/lets-work-on-next-task-claude-code.html （2026-03-04）
- 模板生态直接印证需求：psantanna 学术模板（期刊 profile、"no hallucinated citations / correct SE clustering" 等 24 条规则）2,900+ fork、15+ 课题组；国内 academic-research-skills 1.2 万 star（知乎多篇）。
- Cowork 早期评价：Tibor Blaho "no project support, no memory between sessions"（Zvi 转引，2026-01-13）。

**频率：很多人提**（开发者 issue 多；科研人员表现为「装模板/skill」而不是直接抱怨）。

## 没搜到的（一手证据缺失）

1. **Reddit 全部子版**：r/PhD、r/GradSchool、r/LaTeX、r/labrats、r/bioinformatics、r/datascience 一条都拿不到（抓取被封），202GB 帖只有二手 URL。
2. **科研人员「实验跑很久、要在手机上盯」**：手机需求全是程序员说的；HN 只有 lebovic 一句 HPC 长任务。
3. **非 CS 研究生「不会 git 被 agent 改坏文件」的第一人称叙述**：GitHub #46058（医学 PDF）是最接近的，但没自述身份；知乎「改崩了别按 Cmd+Z」文章 403。
4. **运营 / PM / 写作者的具体翻车**：只有 Cowork 删文件（同一事件反复转发）和 Claire Vo 的 UX 点评；Substack 评论区付费墙。
5. **MATLAB / R 用户的一手抱怨**：搜到的是经济学（Stata/R）教程向内容，没有痛点帖。
6. **Twitter/X、Bluesky、Academia StackExchange、Overleaf 社区**：均无可直接引用的命中。
7. 知乎 / 小红书：拿到 CSDN 一篇和小红书 Claude Science 测评一篇；「老金靠 Claude Code+OpenClaw 写论文（英语没过四级不会代码）」https://zhuanlan.zhihu.com/p/2015441679809802664 标题极贴题但正文 403，未能引用。
