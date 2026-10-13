## 当前取舍与资料入口

- [自研 harness 与订阅授权](harness-direction.md) — 独立宿主、每台工作机授权和辅助模型的选型理由
- [PDF 读取方案](pdf-read-direction.md) — Vision 与无备用解析器的明确取舍
- [视觉参考与范围](visual-style-direction.md) — 色板、角色点阵、项目色和字体范围
- [界面事件诊断](ui-hit-testing-debugging.md) — 合成输入与命中证据的限制，simctl 探针未决风险
- [卡顿怎么量](performance-diagnosis.md) — 帧间隔对照、真机 Time Profiler、合成滚动、用户双击的测量版、软边诊断，Mac 结论不外推到 iPhone
- [模拟器量 iPhone 排版](ios-layout-probe.md) — 不登录：本机 kited 取目录、DEBUG 临时入口渲染生产视图、结果写 App tmp
- [对话正文的文本容器](text-container-direction.md) — 每条回复一个 TextKit 2 文本视图、附件嵌代码块、复制给原文、外观不改，第三步 iPhone 待验收
- [界面改原生](decision-native-ui.md) — Mac 对话与外壳改 AppKit、iOS 改 UIKit，为拖缝 60 帧，外观逐项复刻；骨架、点阵是退路
- [语音输入方向](voice-input-direction.md) — 与 Keyo 的分工、术语词典与整理后做、点阵表现、未选的识别候选

## 协作反馈

- [界面工作与验收](feedback-ui-workflow.md) — 方案、目标定位、连续推进、真机验收和工具链选择
- [多 agent 编排](feedback-orchestration.md) — 用 Workflow 直接编排、运行中不插话、对照设收敛门槛，审完再合主线
- [交互连续性](feedback-interaction-quality.md) — 公共控件完整行为、对象身份、保留动效的性能优化；窗口动画不回弹，过渡中点阵收起；空画板是窗口
- [测试要克制](test-restraint.md) — 测试准入主来源、事件断言与 PDF 验证要求
- [扫描无用逻辑](feedback-dead-logic-review.md) — 沿执行与数据流判断，不能只看引用

## 未决事项

- [真机与线上验收](todo-device-validation.md) — 角色、插件、托管账号、跨机目录与 Git 的验收范围
- [上下文能力](todo-context-capabilities.md) — skill/MCP、观察账本、变量、预览、开场白与个人偏好
- [工作区协作](todo-workspace-collaboration.md) — 跨线程竞争、后台交接与归档扩展
- [事件来源](todo-event-sources.md) — 文件/插件观察的路由、合并和主动触发
- [执行边界](todo-execution-boundaries.md) — Linux、资源限制与项目文件/网络授权上限
- [开发工作流](todo-development-workflow.md) — 检查、宿主 Git、会话回退与分叉的待评估能力
- [远程连接与托管运维](todo-remote-connections.md) — iPhone 重连、托管容量备份、凭据重绑和多机关系
- [订阅凭据续期](todo-subscription-auth.md) — ChatGPT 自动刷新和安全存储
- [真实终端](todo-terminal-plugin.md) — PTY 与跨端重连、停止和资源生命周期
- [窗口动画剩余开销](todo-window-motion-remaining.md) — 缩小首帧的 SwiftUI 整轮更新、拖缝约 30 帧的构成与无效改法、轮流重排原型、iPad 真机拖缝，iPhone 未量
- [个人组网清理](todo-headscale-cleanup.md) — lisa 实验资源的存在与清理状态待核验
