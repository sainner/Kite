## 项目背景

- [Kite 来历](kite-origin.md) — Kite 替代 Pigeon 的动机与旧任务书的历史定位

## 项目决定

- [自研 harness 与 ChatGPT 订阅](harness-direction.md) — Claude 账号受阻后提前自研 harness，首个模型入口使用 ChatGPT 订阅
- [Claude Code 重新接入](claude-integration-direction.md) — 先清空工具与附加功能再逐项接入，插话沿用原生 stdin
- [协议与适配器边界](protocol-adapter-boundaries.md) — 统一前端会话语义，区分完整 agent 与模型 API 适配，保留原生恢复记录
- [工具接口方向](tool-interface-direction.md) — 短工具名与统一读写入口，版本变化仅提示，抽象调用才填写用途
- [提示词编排方向](prompt-composition-direction.md) — 上下文编排的核心是用户可编辑，包含轻任务与通知正文
- [辅助轻任务方向](light-task-direction.md) — 辅助生成统一使用常驻 ChatGPT 订阅直调，业务材料与校验各自负责
- [配置与工作区事件投递](external-event-delivery.md) — 配置和环境变化在自然请求边界追加通知，减少缓存损失与工作打断
- [统一执行沙箱](sandbox-execution-direction.md) — 插件与 harness 共用操作系统沙箱，正式运行时继续使用 Bun
- [工作树与工作区生命周期](session-worktree-decision.md) — 独立工作树用于隔离并行改动，生命周期属于工作区而非单个线程
- [工作区、线程与插件架构](workspace-thread-plugin-architecture.md) — 工作区承载同级实例，agent 统一为插件，自定义插件需要界面、逻辑与工作区能力
- [窗口的跨端同步](workspace-window-sync.md) — 同一工作区共享窗口集合，各设备独立布局与焦点
- [插件实例回收](plugin-instance-lifetime.md) — 按是否需要独立存续决定回收，关闭窗口不再一律保留实例
- [实例管理入口](instance-management-entrypoints.md) — 定义在设置中管理，添加只创建实例，无窗口的存续实例仍可找到
- [新窗口放置](new-window-placement.md) — Mac 新窗口优先新列，其次上下分栏，空间仍不足再收起旧窗口
- [停止会话的语义](session-stop-behavior.md) — 手动停止退回未纳入请求的消息，不等于保留 paused 状态
- [统一资源引用](resource-reference-direction.md) — 统一资源引用保留稳定内容身份，历史 diff 不随当前文件变化
- [窗口标题信息](window-header-information.md) — 窗口标题两行，突出会话名称，次级信息为各窗口自定的文字
- [初始配置与设备角色](onboarding-device-roles.md) — 本机执行或仅远程控制都入网，进入 App 后发现 kited 工作机
- [思考与状态展示](thinking-display.md) — 仅显示当前生成的思考，状态 chip 不承担实时活动或思考正文
- [视觉风格来源与取舍](visual-style-direction.md) — 参考色板与用户拍板的视觉取舍，规范正文在 docs/视觉风格.md
- [表格字体来源](table-font-source.md) — 表格使用系统衬线体，iPhone 缺少的中文宋体由苹果按需下载并缓存

## 协作反馈

- [同类控件统一交互](shared-control-interaction.md) — 同类控件统一完整交互，尺寸、命中、玻璃和反馈不能各自修补
- [界面由用户自己预览](user-previews-ui.md) — 样式按用户意见改，编译安装并打开后由用户预览，Mac 替换旧实例
- [接数据沿用原界面](feedback-preserve-ui-on-data-integration.md) — App 接真实数据时保留已做好的界面结构，不另换空状态页面或控件布局
- [假数据要穷举](fake-data-exhaustive.md) — 预览覆盖当前后端真实工具与异常，未支持能力单独标注
- [对话用中文](feedback-chat-language.md) — 回复、计划与交付说明都用简体中文
- [大改动先给方案](feedback-plan-before-large-changes.md) — 新视觉体系或全局布局先交方案与待决问题，确认后实现
- [测试要克制](test-restraint.md) — 简单配置与接入不扩充测试，跑检查与新增测试分开判断
- [扫描无用逻辑](feedback-dead-logic-review.md) — 扫描无用逻辑时沿实际执行和数据流判断，不能只看引用
- [文档只写现状](feedback-docs-current-state.md) — 改文档直接陈述当前状态，不追加更新说明

## 待办与未决事项

- [待决策：会话观察账本](context-observation-ledger.md) — 记录模型观察与压缩后上下文的账本设想，尚未确定完整设计
- [待办：插件跨端验收](todo-plugin-device-validation.md) — 插件跨端验收的未解决事项、来源与完成条件
- [待办：共享工作区协作](todo-workspace-collaboration.md) — 共享工作区协作的未解决事项、来源与完成条件
- [待办：文件与插件事件投递](todo-event-sources.md) — 文件与插件事件投递的未解决事项、来源与完成条件
- [待办：真实终端插件](todo-terminal-plugin.md) — 真实终端插件的未解决事项、来源与完成条件
- [待办：长会话上下文能力](todo-context-capabilities.md) — 长会话上下文能力的未解决事项、来源与完成条件
- [待办：执行隔离与资源管理](todo-execution-boundaries.md) — 执行隔离与资源管理的未解决事项、来源与完成条件
- [待办：远程连接与多机关系](todo-remote-connections.md) — 配对认证已实现，组网真机验收与多机同步候选待处理
- [待办：订阅凭据续期](todo-subscription-auth.md) — 订阅凭据续期的未解决事项、来源与完成条件
- [待办：开发工作流待补齐项](todo-development-workflow.md) — 开发工作流待补齐项的未解决事项、来源与完成条件
- [待办：产品中的个人偏好存放位置](todo-personal-preferences.md) — 产品中的个人偏好存放位置的未解决事项、来源与完成条件
- [待办：工作区公共上下文变量](todo-workspace-context.md) — 工作区公共上下文变量的未解决事项、来源与完成条件

## 资料入口

- [自建 headscale（lisa）](reference-headscale-lisa.md) — Kite 组网控制服务器的部署位置、nginx 分流与排查要点
