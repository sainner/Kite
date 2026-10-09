## 项目背景

- [Kite 来历](kite-origin.md) — Kite 替代 Pigeon 的动机与旧任务书的历史定位

## 项目决定

- [自研 harness 与 ChatGPT 订阅](harness-direction.md) — Claude 账号受阻后提前自研 harness，首个模型入口使用 ChatGPT 订阅
- [Claude Code 重新接入](claude-integration-direction.md) — 先清空工具与附加功能再逐项接入，插话沿用原生 stdin
- [模型厂商决定后端](model-vendor-backend.md) — 界面不暴露后端；Claude 模型走 Claude Code 订阅，其余走自研 harness，菜单按厂商分
- [代理与角色](agent-role-direction.md) — 代理=角色+实例配置，三个 agent 定义合一，工具黑白名单逐层求交，角色可标必需
- [项目约束](project-constraints-direction.md) — 存账号服务按项目分发，kited 执行并缓存，收紧即时生效，不放仓库
- [资源库随账号保存](library-account-storage.md) — 资源库内容随账号分发，分机保存的放设备下各工作机页面
- [协议与适配器边界](protocol-adapter-boundaries.md) — 统一前端会话语义，区分完整 agent 与模型 API 适配，保留原生恢复记录
- [工具接口方向](tool-interface-direction.md) — 短工具名与统一读写入口，版本变化仅提示，抽象调用才填写用途
- [PDF 读取方案](pdf-read-direction.md) — PDF 转 Markdown 用 macOS Vision，不用 Docling 或 pdf.js，不留兜底
- [上下文压缩方向](compaction-direction.md) — 自己实现、按范围选择性压缩的来由；Claude 回合中途压缩等上游稳定再接
- [提示词编排方向](prompt-composition-direction.md) — 上下文编排的核心是用户可编辑，包含轻任务与通知正文
- [辅助轻任务方向](light-task-direction.md) — 辅助生成统一使用常驻 ChatGPT 订阅直调，业务材料与校验各自负责
- [配置与工作区事件投递](external-event-delivery.md) — 配置和环境变化在自然请求边界追加通知，减少缓存损失与工作打断
- [统一执行沙箱](sandbox-execution-direction.md) — 插件与 harness 共用操作系统沙箱，正式运行时继续使用 Bun
- [项目以远程仓库为身份](project-remote-identity.md) — 项目以远程为身份、托管远程与集成推送的决定来源，正文在 docs
- [凭据分发服务](credential-service-direction.md) — Git、共享密钥与模型 API Key 归入资源库凭据，随账号分发、按类型取用
- [工作树与工作区生命周期](session-worktree-decision.md) — 独立工作树用于隔离并行改动，生命周期属于工作区而非单个线程
- [工作区、线程与插件架构](workspace-thread-plugin-architecture.md) — 工作区承载同级实例，agent 统一为插件，自定义插件需要界面、逻辑与工作区能力
- [窗口的跨端同步](workspace-window-sync.md) — 同一工作区共享窗口集合，各设备独立布局与焦点
- [插件实例回收](plugin-instance-lifetime.md) — 按是否需要独立存续决定回收，关闭窗口不再一律保留实例
- [实例管理入口](instance-management-entrypoints.md) — 定义在设置中管理，添加 agent 先开本机草稿，存续实例可找到、可归档
- [新窗口放置](new-window-placement.md) — Mac 新窗口优先新列，其次上下分栏，空间仍不足再收起旧窗口
- [停止会话的语义](session-stop-behavior.md) — 手动停止退回未纳入请求的消息，不等于保留 paused 状态
- [统一资源引用](resource-reference-direction.md) — 统一资源引用保留稳定内容身份，历史 diff 不随当前文件变化
- [窗口标题信息](window-header-information.md) — 状态圆环在标题前；代理窗口副标题是角色，新代理在此选角色
- [侧栏一级导航](sidebar-navigation.md) — 空间、设备、资源库的导航分层；设备下账号与文件并列；账号页允许固定窗口分区
- [初始配置与设备角色](onboarding-device-roles.md) — 本机执行或仅远程控制都入网，进入 App 后发现 kited 工作机
- [托管账号与组网](hosted-network-direction.md) — 我们托管，用户账号密码登录或扫描已登录设备二维码加入；规格见 docs
- [账号用量与额度展示](account-usage-direction.md) — 圆环看额度，正文热力图配某天 24 小时柱状图；按天能取上游就读，按小时由 kited 扫本机存
- [思考与状态展示](thinking-display.md) — 仅显示当前生成的思考，状态指示不承担实时活动或思考正文
- [视觉风格来源与取舍](visual-style-direction.md) — 参考色板、树状子项与用户预览后确认的取舍，当前呈现核对代码
- [模板点阵签名](template-emblem-direction.md) — 新代理空白页铺满角色专属的 AI 生成表达式动画，可手改，保存后自动生成
- [宋体尝试](serif-font-trial.md) — 先只把侧栏字标换成思源宋体，表格与其他文字保持系统字体；扩大范围先确认体积

## 协作反馈

- [同类控件统一交互](shared-control-interaction.md) — 统一尺寸、命中与反馈，保留控件已有的专门触屏交互
- [界面由用户自己预览](user-previews-ui.md) — Mac 整体替换 Release；面向 iPhone 的触控改动安装并打开已连接真机
- [接数据沿用原界面](feedback-preserve-ui-on-data-integration.md) — App 接真实数据时保留已做好的界面结构，不另换空状态页面或控件布局
- [Xcode 用 27.2](feedback-xcode-version.md) — 打开 Xcode 界面用 Xcode-beta.app（27.2），不按名字开到 27.0
- [对话用中文](feedback-chat-language.md) — 回复、计划与交付说明都用简体中文
- [大改动先给方案](feedback-plan-before-large-changes.md) — 新视觉或全局布局先交方案；已确认的多期计划连续做完
- [测试要克制](test-restraint.md) — 简单配置与接入不扩充测试，跑检查与新增测试分开判断
- [扫描无用逻辑](feedback-dead-logic-review.md) — 扫描无用逻辑时沿实际执行和数据流判断，不能只看引用
- [先确认是哪个控件](feedback-confirm-ui-target.md) — 「侧边栏」可能指右侧停靠栏；同名按钮有多处时先确认位置
- [文档只写现状](feedback-docs-current-state.md) — 改文档直接陈述当前状态，不追加更新说明
- [文档只写设计原则](feedback-docs-principles-only.md) — 用户要求清理界面细节的反馈来源，正式规则见 AGENTS.md

## 待办与未决事项

- [待办：代理与角色三期](todo-agent-roles.md) — 角色与代理合一、资源库迁账号、项目约束的分期与完成条件
- [待决策：会话观察账本](context-observation-ledger.md) — 记录模型观察与压缩后上下文的账本设想，尚未确定完整设计
- [待办：插件跨端验收](todo-plugin-device-validation.md) — 插件跨端验收的未解决事项、来源与完成条件
- [待办：共享工作区协作](todo-workspace-collaboration.md) — 共享工作区协作的未解决事项、来源与完成条件
- [待办：文件与插件事件投递](todo-event-sources.md) — 文件与插件事件投递的未解决事项、来源与完成条件
- [待办：真实终端插件](todo-terminal-plugin.md) — 真实终端插件的未解决事项、来源与完成条件
- [待办：长会话上下文能力](todo-context-capabilities.md) — 长会话上下文能力的未解决事项、来源与完成条件
- [待办：执行隔离与资源管理](todo-execution-boundaries.md) — 执行隔离与资源管理的未解决事项、来源与完成条件
- [待办：远程连接与多机关系](todo-remote-connections.md) — 跨机器目录和账号的真机验收、iPhone 重连提速遗留问题、文件同步候选
- [待办：订阅凭据续期](todo-subscription-auth.md) — 订阅凭据续期的未解决事项、来源与完成条件
- [待办：开发工作流待补齐项](todo-development-workflow.md) — 开发工作流待补齐项的未解决事项、来源与完成条件
- [待办：产品中的个人偏好存放位置](todo-personal-preferences.md) — 产品中的个人偏好存放位置的未解决事项、来源与完成条件
- [待办：工作区公共上下文变量](todo-workspace-context.md) — 工作区公共上下文变量的未解决事项、来源与完成条件

## 资料入口

- [界面命中问题的调试](ui-hit-testing-debugging.md) — Mac 进程内合成点击；iPhone 用模拟器探针比 hitTest；悬停需用户实测
- [旧个人 Headscale（lisa）](reference-headscale-lisa.md) — 旧实验服务位置、nginx 分流与清理入口
