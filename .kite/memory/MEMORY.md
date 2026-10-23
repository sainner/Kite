## 当前取舍与资料入口

- [分布式架构](decentralized-direction.md) — 不再自营服务器：Tailscale 身份、见证方可替换、设备间同步；实施顺序，第 1 步已做；设计待评审
- [自研 harness 与订阅授权](harness-direction.md) — 独立宿主、每台工作机授权和辅助模型的选型理由；DeepSeek 用账号 API Key
- [PDF 读取方案](pdf-read-direction.md) — Vision 与无备用解析器的明确取舍
- [视觉参考与范围](visual-style-direction.md) — 色板、角色点阵、项目色和字体范围
- [界面事件诊断](ui-hit-testing-debugging.md) — 合成输入与命中证据的限制，光标探针，SwiftUI 菜单小程序验证，simctl 不再用，现场采集别挂调试器，真机点按记录与崩溃报告
- [尺寸突变与裁剪怎么查](ui-layout-jump-diagnosis.md) — 预览自己打开、日志打高度或片段坐标、沿视图链打裁剪；log 写全路径；外层蒙版会裁；逐帧错位在提交后核对；iPhone 动画真机逐帧截图；探针按块删
- [卡顿怎么量](performance-diagnosis.md) — 测量入口与交替对照、帧间隔、真机 Time Profiler、合成滚动、软边诊断、UIKit 透明度坑，Mac 结论不外推到 iPhone
- [性能测量用的会话数据](perf-fixture-main-agents.md) — 两个主代理的完整历史存在 fixtures、不进 Git，各压缩两次；工作机清数据后回放用
- [真机量 iPhone、iPad 排版](ios-layout-probe.md) — 不登录：kited 取数据、参数开的探针渲染生产视图、App 里截图、devicectl 取回；不用模拟器
- [对话正文的文本容器](text-container-direction.md) — 每条回复一个 TextKit 2 文本视图、附件嵌代码块、复制给原文、外观不改，第三步 iPhone 待验收
- [Line 与工作区流转](line-direction.md) — 已合回 main、界面待验收；收件箱是 Line 的 monitor；待改进与部署注意
- [界面改原生](decision-native-ui.md) — Mac 对话与外壳改 AppKit、iOS 改 UIKit，为拖缝 60 帧，外观逐项复刻；骨架、点阵是退路
- [NAS 的现状](nas-setup.md) — 常开 Mac mini 上的 ORICO 外置盘，10-22 已接上；按工作机上的普通目录处理
- [子 agent 的 worktree 起点](agent-worktree-base.md) — 默认从 origin/main 建、不含本地提交，可设 worktree.baseRef=head；合回时别碰别的会话的改动
- [磁盘空间](disk-space.md) — 内置盘紧，大件下载与编译前先看余量，不够用外置硬盘 ORICO
- [语音输入方向](voice-input-direction.md) — 与 Keyo 的分工、术语词典与整理后做、点阵表现、未选的识别候选

## 协作反馈

- [界面工作与验收](feedback-ui-workflow.md) — 方案、目标定位、连续推进、失灵诊断不靠猜、真机验收和工具链选择；改完直接开 Debug 预览、微调不跑检查，自己开的 Kite 用完就关
- [交互连续性](feedback-interaction-quality.md) — 公共控件（报一处按类修全）、对象身份、动效性能；窗口动画不回弹、新建从添加入口展开、点阵收起；改尺寸只动相邻窗口；上一步与固定；触屏长按起拖、标题栏无右键菜单
- [状态放标题栏](feedback-pane-status-placement.md) — 窗口状态归信息区，副行只放 description；为空画点阵图案配文字；弹窗副行说清做什么、状态写正文
- [测试要克制](test-restraint.md) — 测试准入主来源；改设计只删旧断言、不改写、不给新功能补测试；事件断言与 PDF
- [设计讨论先给意见](feedback-design-discussion.md) — 用户的总结是征求意见，落文档前先问；认可了具体方案就算已决定
- [讲方案说大白话](feedback-plain-explanations.md) — 先讲现状、解释工程术语、一次问一件事，流程选择给自动默认值
- [扫描无用逻辑](feedback-dead-logic-review.md) — 沿执行与数据流判断，不能只看引用
- [什么要保存](feedback-save-scope.md) — 只有提示词这类文稿改完要保存，其他修改即时生效；新角色在上下文窗口一次建好
- [旧数据出错就删](feedback-stale-data.md) — 旧数据读不了就删、不兼容；方案取舍不把已有会话角色对不上当代价；删前确认
- [不记安装状态](feedback-no-install-state.md) — 不写哪台机器装了哪一版、装没装上；版本读 /machine

## 未决事项

- [真机与线上验收](todo-device-validation.md) — 角色、插件、托管账号、跨机目录与 Git 的验收范围
- [上下文能力](todo-context-capabilities.md) — 外部 MCP 已合回待真机手测、观察账本、预览、开场白与个人记忆
- [skill 接入](todo-skills.md) — 四层来源、skill 工具、压缩重附、资源库、窄窗口候选与键盘补全待真机验收
- [工作区协作](todo-workspace-collaboration.md) — 后台与内嵌实例的界面呈现、已归档实例的查看与恢复，待设计
- [事件来源](todo-event-sources.md) — 文件/插件观察的路由与合并；主动触发已定为通用 monitor
- [执行边界](todo-execution-boundaries.md) — Linux（含沙箱外命令、监听端口、上级目录）、资源限制、项目收紧是否停旧命令
- [开发工作流](todo-development-workflow.md) — 检查、宿主 Git、会话回退与分叉的待评估能力
- [远程连接与托管运维](todo-remote-connections.md) — iPhone 局域网周期断连已修与验证范围、取证做法；两台 Mac 间时快时慢（10-22 实测，待测中继与局域网）；托管容量备份、凭据重绑和多机关系
- [订阅凭据续期](todo-subscription-auth.md) — ChatGPT 自动刷新和安全存储
- [DeepSeek 待实测](todo-deepseek-validation.md) — 纯文字已跑通；工具回合推理交回、跨厂商推理占位、图片待验
- [节假日表](todo-holiday-calendar.md) — DeepSeek 峰谷计价的法定节假日表每年补次年安排，现只有 2026
- [终端插件收尾](todo-terminal-plugin.md) — 已实现待手测；预置脚本已移到预览的目标；跨端口网页待验、旁观设备尺寸、跨 kited 重启、后台命令输入
- [预览插件收尾](todo-preview-plugin.md) — 目标模型与浏览并进文件、能开外网待手测；旧工具名要清；Xcode 批准待跑；DeviceHub 裁不出
- [窗口动画剩余开销](todo-window-motion-remaining.md) — 测量基线与改后数据、侧栏拖宽的两处原因、缩小首帧剩下的岛更新、无效改法；iPad 拖缝到 120Hz 前后、iPhone 数据；侧栏收起展开；真发送开头掉帧
- [去中心化改造收尾](todo-decentralized-rollout.md) — 租约续约等 CloudKit、登出重启关机预告待实测、本机受管通道已上线、Mac mini 收不到同步待人处理
- [本机访问边界](todo-local-access-boundary.md) — 本机接口与 kite-net 代理不设认证、/network 暴露端点，待定收紧；排查装的系统版 Tailscale 要退
- [上架前的版本做法](todo-store-release.md) — kited 兼容在用的旧版 App、先 App 后 kited、公共下载点、Mac App 签名后自更新
- [工作区模型改造](todo-workspace-model.md) — 已实现、协议号 2；部署前清各工作机旧 kite.db（先征得同意）、真机验收、Line 不提交现场待确认
- [本机先行的收尾](todo-local-first-actions.md) — 各路径已改为本机先行、待手测；失败时的收回方式；进入工作区卡顿待量（Mac、iPhone）
- [消息附件收尾](todo-attachments.md) — 输入框那一行待验收、Mac 点开方式待定、真机待测；中途带图交给 Claude 没测
