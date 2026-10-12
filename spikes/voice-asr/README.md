# 语音识别选型实验（2026-10-11 起）

Kite 语音输入改用流式识别、开录时把最近对话交给识别模型、默认不再用 LLM 美化。这里用真实录音比较候选模型：识别得准不准，带上下文能好多少，说完到定稿多快。结论出来后写进 `docs/research`，并更新项目记忆里的「语音输入方向」。

| 文件 | 内容 | 用法 |
|---|---|---|
| `scripts.json` | 朗读稿：18 段跟 agent 说的话，前 12 段分两组配对话上下文，后 6 段不带；每段列出要认对的词 | 由 `record.swift` 读取 |
| `record.swift` | 照朗读稿逐段录：显示要念的话，录音时显示音量条，按麦克风原格式存 `audio.caf`，连同这段的原文、要认对的词、对话上下文；录过的跳过 | 在自己的终端里跑（不能用 Claude Code 的 `!`，收不到回车）：`xcrun swift spikes/voice-asr/record.swift ~/kite-voice-samples` |
| `run.ts` | 每段样本对每家各跑「无上下文」和「带上下文」两遍，按真实语速推音频，打印每段结果和汇总，明细写成 JSON 放在样本目录 | `bun spikes/voice-asr/run.ts ~/kite-voice-samples qwen,apple` |
| `providers.ts` | 各家的流式客户端 | 由 `run.ts` 调用 |
| `apple.swift` | Apple 本地识别，由 `run.ts` 编译到临时目录后调用 | 由 `run.ts` 调用 |
| `score.ts` | 字错率、关键词命中（大致与照原样），从对话里取上下文 | 由 `run.ts`、`restore.ts` 调用 |
| `restore.ts` | 识别后的确定性整理：念出来的符号换回符号，英文词按对话里的标识符恢复写法；对已有结果离线比较整理前后 | `bun spikes/voice-asr/restore.ts ~/kite-voice-samples [结果 JSON]` |

## 候选与接法

| 候选 | 接口 | 上下文怎么给 | 密钥 |
|---|---|---|---|
| 豆包流式语音识别 2.0 | 火山 `bigmodel_async`，开二遍识别（边说边出字，每句判停后用非流式模型重识别）、顺滑、标点和数字规范 | `corpus.context` 的 `dialog_ctx`，从新到旧最多 20 轮、800 token | `VOLC_API_KEY`（新版控制台），或 `VOLC_APP_KEY` 与 `VOLC_ACCESS_KEY`（旧版）；资源默认 `volc.seedasr.sauc.duration`，可用 `VOLC_RESOURCE_ID` 改 |
| 千问实时识别 | 百炼 `qwen3-asr-flash-realtime`，默认服务端 VAD 分句，`QWEN_MANUAL=1` 时说完一次提交 | `corpus.text`，取最近对话的末尾 6000 字 | `DASHSCOPE_API_KEY`；模型、地址、语种、判句的静音时长可用 `QWEN_ASR_MODEL`、`QWEN_ASR_URL`、`QWEN_ASR_LANGUAGE`、`QWEN_VAD_SILENCE_MS`（默认 800）改 |
| Apple 本地识别 | SpeechAnalyzer 的听写模块 | 只收词表：从对话里摘出来的英文标识、文件名和命令 | 不用 |

密钥写在样本目录的 `.env` 里（一行一个 `KEY=VALUE`），样本和密钥都不进仓库。

豆包暂时比不了（2026-10-12）：流式识别属于「豆包语音」，要用它的控制台签发的 key，火山方舟的 key 握手时返回 401 `Invalid X-Api-Key`；而大模型版语音识别只对完成企业实名认证的用户开放。接法留着，有企业认证再跑：`bun spikes/voice-asr/run.ts <样本目录> doubao`。

## 样本

每段一个目录：`audio.*`（任意格式，跑之前用 `afconvert` 转成 16 kHz 单声道）、`reference.txt`（实际说的话）、`terms.txt`（要认对的词，一行一个，可省）、`context.txt`（当时的对话，按空行分轮、从旧到新，可省）。朗读稿模拟平时跟 agent 说的话：中英混说、文件名、命令、标识符、说到一半改口。照稿念比随口说容易识别，结论只用来横向比较几家，不代表随口说时的绝对准确率。

字错率去掉空白和标点、英文不分大小写后按字算；关键词看定稿里有没有出现；首字是开始推音频到第一个中间结果，定稿是最后一包推出去到拿到定稿。

## 结果

2026-10-12 的 18 段录音结果与结论见 [实验记录](../../docs/research/2026-10-12-语音识别选型.md)。
