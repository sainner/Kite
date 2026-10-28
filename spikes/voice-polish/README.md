# 语音润色实验（2026-10-29 起）

用户嫌语音输入的结果太口语。kited 现在识别完再用轻任务按「语音整理」模板整理一次（多一次请求）；百炼的 `qwen-audio-3.1-asr-flash-message` 有个 `disfluency_removal_enabled` 开关，文档说开了以后「最终结果可去除语气词、重复和自我纠正，并整理表达」，识别时就润色好。这里比两条路：润色得怎么样、标识符还认不认得准、说完到出字多久。结论出来后写进 `docs/research`，并更新项目记忆里的「语音输入方向」。

| 文件 | 内容 | 用法 |
|---|---|---|
| `scripts.json` | 口语稿：8 段跟 agent 说的话，带口头禅、重复和改口，前 5 段配 `spikes/voice-asr` 的两段对话上下文；每段列出要认对的词 | 由 `synth.ts`、`record.swift` 读取 |
| `synth.ts` | 用系统的中文合成语音（默认婷婷）把稿子念成 `tts-NN` 样本，先跑通协议、粗看效果；合成的话比真人干净 | `bun spikes/voice-polish/synth.ts ~/kite-voice-polish` |
| `record.swift` | 照稿子的意思随口说，录成 `NN` 样本，不用照念 | 在自己的终端里跑：`xcrun swift spikes/voice-polish/record.swift ~/kite-voice-polish` |
| `run.ts` | 每段跑四种做法，打印结果、关键词和耗时，明细写成 JSON 放在样本目录 | `bun spikes/voice-polish/run.ts ~/kite-voice-polish` |

## 四种做法

| 做法 | 怎么跑 |
|---|---|
| 现行 | `qwen3-asr-flash-realtime` 说完一次提交，对话按「语音识别」模板放进 `corpus.text`，定稿做确定性恢复；直接调 kited 的 `voice/` 代码 |
| 现行 + DeepSeek | 现行的结果按 kited 的「语音整理」模板交给 DeepSeek（默认 `deepseek-flash`、`low`，可用 `DEEPSEEK_MODEL`、`DEEPSEEK_REASONING` 改），耗时含整理 |
| 新型号 | `qwen-audio-3.1-asr-flash-message`，run-task 双工协议，近场 VAD、断句静音 6 秒；对话里的标识符作热词（权重 4，最多 50 个），不带对话；同样做确定性恢复 |
| 新型号 + 润色 | 同上，打开 `disfluency_removal_enabled` |

不带对话是因为带了 `input.context`（文档说最多 5 轮、每轮不超过 400 字）润色就不起作用：2026-10-29 同一段合成录音，只开润色时语气词、重复都去掉了、「三格」写成「3 格」；加上两轮对话后照原话出字、数字也不规整，「Mac」还认成了「Map」。只加热词不影响润色。

密钥写在样本目录的 `.env` 里（一行一个 `KEY=VALUE`）：`DASHSCOPE_API_KEY`（北京地域百炼）、`DEEPSEEK_API_KEY`。新型号默认连 `wss://dashscope.aliyuncs.com/api-ws/v1/inference`，连不上时按文档改成业务空间的地址 `QWEN_MESSAGE_URL=wss://<WorkspaceId>.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`，或用 `DASHSCOPE_WORKSPACE` 带上业务空间。样本和密钥都不进仓库。

协议依据：千问 AI 平台的 Qwen-Audio-ASR-Message [客户端事件](https://platform.qianwenai.com/docs/api-reference/speech-recognition/qwen-asr-message/client-events)、[服务端事件](https://platform.qianwenai.com/docs/api-reference/speech-recognition/qwen-asr-message/server-events)，百炼的 [实时语音识别指南](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)。

## 结果

2026-10-29 用 8 段合成录音的结果与结论见 [实验记录](../../docs/research/2026-10-29-语音润色.md)。
