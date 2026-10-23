/** 实例操作的公开声明；宿主与模型工具共用 schema，调用身份不属于参数。 */
import { z } from 'zod';
import { inputSchema, type inputVia } from '../harness/input.ts';
import { diffID, fileDiffSchema } from '../workspace/file-diffs.ts';
import { MAX_MESSAGE_ATTACHMENTS } from '../workspace/attachments.ts';
import { fileSelectionSchema, portSchema, readFileArgs, snapshotCommit, webAddressSchema } from '../workspace/files.ts';
import { fileVersionSchema } from '../workspace/file-versions.ts';
import { stateSchema as terminalStateSchema } from '../terminal/state.ts';
import { deviceSchema } from '../preview/devices.ts';
import { previewBrowsers, previewScreens, viewportEdge, workstationBrowsers } from '../preview/state.ts';

/**
 * Line 的管理动作与对应工具。停止、归档、创建、流转是必问动作，每次执行前等用户批准，见 line/tools.ts。
 * reply 是代处理收件箱与转达用户原话；自约唤醒用通用的 monitor_start。
 */
export const lineActions = ['status', 'reply', 'send', 'resume', 'stop', 'archive', 'create', 'transfer'] as const;
export type LineAction = (typeof lineActions)[number];
export const lineToolNames = ['line_status', 'line_handle', 'line_relay', 'line_control', 'line_workspace'] as const;
export const lineToolActions: Record<(typeof lineToolNames)[number], readonly LineAction[]> = {
  line_status: ['status'], line_handle: ['reply'], line_relay: ['reply'], line_control: ['send', 'resume', 'stop', 'archive'],
  line_workspace: ['create', 'transfer'],
};

/** 每个 monitor 每天最多唤醒对象代理的次数。 */
export const MONITOR_DAILY_WAKES = 40;
/** 一分钟里超过这么多事件就停掉这个来源。 */
export const MONITOR_BURST_LIMIT = 60;

const id = z.string().min(1);
const text = z.string().refine((value) => !!value.trim(), '内容不能为空');
const target = z.object({ operationId: id, instanceId: id }).strict();
const ok = z.object({ ok: z.literal(true) }).strict();
const fileEntry = z.object({ name: id, path: id, kind: z.enum(['file', 'directory', 'symlink', 'other']) }).strict();
/**
 * 三种 list 共有的字段：谁建的（没有时是用户在界面上开的）、什么时候、有没有窗口、调用方获准的操作；
 * 在子工作区里的另带所在的工作区。
 */
const listed = { instanceId: id, title: z.string(), createdBy: id.nullable(), createdAt: z.number(), window: z.boolean(), operations: z.array(id),
  workspace: z.object({ id, name: z.string() }).strict().optional() };
/**
 * 预览的一项：目标、设备、画面种类，网页另带主端口和在哪看（device 是用户设备上的网页视图），App 窗口另带 App；分给目标的端口段与进程状态同终端。
 */
const preview = { instanceId: id, title: z.string(), target: z.string(), device: deviceSchema.nullable(), screen: z.enum(previewScreens),
  port: z.number().int().optional(), browser: z.enum(previewBrowsers).optional(), app: z.string().optional(), assignedPort: z.number().int().optional(),
  ...terminalStateSchema.shape };
/** 给模型看的一帧：坐标照 width、height（网页是 CSS 像素，模拟器和 App 窗口是点）；settled 是等到了画面稳定，没等到是动画还在动。 */
/** 截图不在结果里，单独交给模型（见 operations.ts 的 takeImages），收据里不存。 */
const frame = { url: z.string().optional(), pageTitle: z.string().optional(), width: z.number(), height: z.number(), settled: z.boolean() };
const previewFrame = z.object({ ...preview, ...frame }).strict();
/** 网页画面里并排的一格：工作机上的哪个浏览器、视口多大；不带时是画面视图。 */
const cell = { browser: z.enum(workstationBrowsers).optional(), width: viewportEdge.optional(), height: viewportEdge.optional() };
const coordinate = z.array(z.number().min(0)).length(2);
const summary = z.object({
  ...listed, definitionId: id, role: z.object({ id, title: z.string() }).strict().nullable(), presentation: z.enum(['window', 'inline', 'background']),
  status: z.enum(['open', 'archived']), phase: z.enum(['idle', 'running', 'stopping', 'finishing']),
  busy: z.boolean(), waitingForResume: z.boolean(), recovery: z.string().nullable(),
  /** 一行状态：空闲、运行中、等用户批准、等确认恢复或上一回合失败。 */
  state: z.string(),
}).strict();

/**
 * 对其他代理、monitor 与终端的操作；代理按协作范围授予，这几项的授权共用一个目标范围（descendants 或 workspace），
 * 见 docs/实例操作.md「代理的协作范围」。
 */
export const scopedOperations = ['agent.list', 'agent.send', 'agent.resume', 'agent.stop', 'agent.merge',
  'monitor.list', 'monitor.stop', 'terminal.list', 'terminal.read', 'terminal.stop'] as const;

export const operationContracts = {
  'plugin.call': {
    title: '调用插件工具', description: '调用同一工作区内获准的插件实例工具。模型使用宿主登记的具体工具声明。',
    tool: null, effect: 'write', retry: 'plugin',
    input: target.extend({ tool: id, arguments: z.record(z.string(), z.unknown()) }).strict(), output: z.unknown(),
  },
  'agent.start': {
    title: '创建 agent', description: [
      '在当前工作区按角色创建 agent 实例。role 是角色 ID，省略时用默认角色 kite.work（工作）；内置的还有 kite.review（只读审查）。省略 prompt 只创建空会话；带 prompt 的回合结束时把结果回报给你。只在用户要求在界面上看着它时传 presentation: window。',
      'isolation: workspace 把它放进一个子工作区：从当前工作区最近的快照开出（含还没集成的改动），构建、测试和改动都与这里隔开。适合要改很多文件、会和别的代理互相干扰的任务；做完用 agent_merge 合回，不要的停着即可，由用户放弃。',
    ].join(''),
    tool: 'agent_start', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, role: id.optional(), title: text.optional(), prompt: text.optional(),
      presentation: z.enum(['window', 'inline', 'background']).default('background'), isolation: z.enum(['workspace']).optional() }).strict(),
    output: z.object({ instanceId: id, windowId: id.optional(), workspaceId: id.optional() }).strict(),
  },
  'agent.list': {
    title: '查询 agent', description: '查询你协作范围内的 agent 实例：谁建的、一行状态及你获准的操作。',
    tool: 'agent_list', effect: 'read', retry: 'read',
    input: z.object({}).strict(), output: z.object({ agents: z.array(summary) }).strict(),
  },
  'agent.send': {
    title: '发送消息', description: '向获准的 agent 实例发送消息，对方看到的消息标明是你发的；对方这一回合结束时把结果回报给你。',
    tool: 'agent_send', effect: 'write', retry: 'input',
    // attachments 只给界面：用户发的消息带的附件，模型的工具声明里没有；正文为空时由宿主拒绝，带附件的可以没有正文。
    input: target.extend({ text: z.string(), attachments: z.array(id).min(1).max(MAX_MESSAGE_ATTACHMENTS).optional() }).strict(), output: z.object({ id }).strict(),
  },
  'agent.resume': {
    title: '继续执行', description: '继续获准的 agent 实例。',
    tool: 'agent_resume', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'agent.stop': {
    title: '停止执行', description: '停止获准的 agent 实例，等待受管执行停止。你发给它、它还没读到的消息退回给你（returned），还要它做的停下后再用 agent_send 发，新消息会让它继续。',
    tool: 'agent_stop', effect: 'write', retry: 'stop',
    input: target.extend({ inputs: z.array(inputSchema).optional() }).strict(), output: z.object({ returned: z.array(inputSchema) }).strict(),
  },
  'agent.merge': {
    title: '合回子工作区', description: [
      '把用 isolation: workspace 开出的子工作区合回它的父工作区，instanceId 是开子工作区时建的那个代理。要求子工作区里的代理都空闲。',
      '合完（merged）或没有改动（unchanged）时子工作区连同其中的代理一起归档；有冲突时（conflict）立即返回，冲突交给子工作区里的代理解决，宿主随后接着合，合好或失败时把结果作为一条新的输入发给你。',
    ].join(''),
    tool: 'agent_merge', effect: 'write', retry: 'receipt', input: target,
    output: z.object({ status: z.enum(['merged', 'unchanged', 'conflict']), files: z.array(id).optional() }).strict(),
  },
  'files.list': {
    title: '浏览目录', description: '读取文件实例所属工作区内的一层目录，按目录优先、名称排序并分页。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, path: id.default('.'), offset: z.number().int().min(0).default(0), limit: z.number().int().min(1).max(1000).default(200) }).strict(),
    output: z.object({ path: id, entries: z.array(fileEntry), total: z.number().int(), nextOffset: z.number().int().nullable() }).strict(),
  },
  'files.search': {
    title: '搜索文件', description: '按名字找文件实例所属工作区内的文件和目录，不分大小写，跳过 .git 和 Git 忽略的路径；名字相同、开头相同的排在前面。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, query: z.string().trim().min(1).max(200), limit: z.number().int().min(1).max(1000).default(200) }).strict(),
    output: z.object({ query: z.string(), entries: z.array(fileEntry), truncated: z.boolean() }).strict(),
  },
  'files.read': {
    title: '读取文本', description: '按行读取文件实例所属工作区内的文本，与 agent 的 read 使用同一文件服务；带 version 时读那一个历史版本。',
    tool: null, effect: 'read', retry: 'read', input: readFileArgs.extend({ instanceId: id, version: snapshotCommit.optional() }).strict(),
    output: z.object({ path: id, text: z.string(), offset: z.number().int(), totalLines: z.number().int(), nextOffset: z.number().int().nullable(), version: id }).strict(),
  },
  'files.history': {
    title: '读取历史版本', description: '列出文件实例所属工作区内一个文件的历史版本：工作区快照里这个文件内容变过的那些，新的在前，最多 100 个。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, path: id }).strict(),
    output: z.object({ versions: z.array(fileVersionSchema), current: snapshotCommit.nullable(), truncated: z.boolean() }).strict(),
  },
  'files.diff': {
    title: '读取历史差异', description: '读取当前工作区某次修改保存的前后内容，不受当前文件变化影响。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, diffId: diffID }).strict(), output: fileDiffSchema,
  },
  'files.state': {
    title: '读取所选内容', description: '读取浏览实例共享且持久的选中文件或网页。',
    tool: null, effect: 'read', retry: 'read', input: z.object({ instanceId: id }).strict(), output: fileSelectionSchema,
  },
  'files.select': {
    title: '选择浏览内容', description: '选择工作区内的文件（可带历史差异 diffId，或历史版本 version），或一个网页（本工作区运行中终端或预览监听的端口 port，或互联网网址 url，这时 path 为 null），各设备共用；不修改文件内容。',
    tool: null, effect: 'write', retry: 'receipt',
    input: target.extend({ expectedRevision: id, path: id.nullable(), diffId: diffID.optional(), version: snapshotCommit.optional(),
      port: portSchema.optional(), url: webAddressSchema.optional() }).strict()
      .refine((input) => input.port === undefined && input.url === undefined || input.path === null && !input.diffId && (input.port === undefined || input.url === undefined),
        '文件和网页只能选一个，网页的端口和网址也只能选一个')
      .refine((input) => input.version === undefined || input.path !== null && !input.diffId, '历史版本要和文件一起选，不能同时带历史差异'),
    output: fileSelectionSchema,
  },
  'terminal.read': {
    title: '读取终端输出', description: '按行读取后台终端的输出：转到后台的命令读完整输出，交互终端读屏幕和回滚里的文字。不给 offset 时读最后 limit 行（默认 200）；结果带进程状态，结束了有退出码或原因。',
    tool: 'terminal_read', effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).default(200) }).strict(),
    output: terminalStateSchema.extend({ instanceId: id, title: z.string(), command: z.string().optional(),
      text: z.string(), offset: z.number().int(), totalLines: z.number().int(), nextOffset: z.number().int().nullable() }).strict(),
  },
  'terminal.list': {
    title: '列出终端', description: '列出你协作范围内的终端：转到后台的命令与用户开的交互终端，带标题、谁建的、在运行还是已退出（退出码或原因）。',
    tool: 'terminal_list', effect: 'read', retry: 'read', input: z.object({}).strict(),
    output: z.object({ terminals: z.array(terminalStateSchema.extend({ ...listed, command: z.string().optional() }).strict()) }).strict(),
  },
  'terminal.stop': {
    title: '停止终端', description: '停下后台终端里的进程，等到进程结束才返回。你自己停下的不再发结束通知。',
    tool: 'terminal_stop', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'preview.open': {
    title: '起预览', description: [
      '起项目的一个预览目标并看它：target 是 .kite/preview/ 下的可执行文件名，不知道有哪些就列出这个目录。一个目标是产品的一种运行方式，如开发服务器、装到模拟器的 iOS App、Mac App。',
      '目标在工作区目录的终端环境里运行，不在沙箱里，环境变量 PORT 是分给它的端口（同一目标另起的服务用 PORT+1 往后），每次都是同一个。',
      'device 是装到哪台设备：{simulator: "型号"}（如 "iPhone 17 Pro"）是工作区专用的模拟器，目标用到模拟器又不写时用默认型号；{physical: "设备编号"} 是与工作机配对过的真机，只装包、没有画面，每次都要用户批准。写错时错误里列出可选的。',
      '同一目标与设备同时只跑一份：已经在跑时返回那个，restart 为 true 时先停掉再起。新起的最多等 30 秒，直到画面就绪（网页端口能打开、模拟器里 App 打开、Mac App 开出窗口）或进程退出，',
      '返回画面种类 screen（web、simulator、app，没有画面是 none）、端口、进程状态与输出末尾，有画面时另带一帧截图。之后用 preview_action 操作，preview_read 看输出，preview_stop 停下，进程退出时会通知你。',
      '要给用户看网页，在回复里写 http://localhost:<端口>/路径。目标与主线上的同名文件一致时直接运行，你新加或改过的要用户批准；没写成目标的命令仍用 shell。截图会发给模型厂商，不要在预览里登录真实账号。',
    ].join(''),
    tool: 'preview_open', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, target: z.string().trim().min(1).max(255), device: deviceSchema.optional(), restart: z.boolean().optional() }).strict(),
    output: z.object({ ...preview, ...z.object(frame).partial().shape,
      /** 已经在跑、返回的是那个。 */
      reused: z.boolean(), text: z.string() }).strict(),
  },
  'preview.action': {
    title: '操作预览', description: [
      '操作预览的画面，做完等画面稳定（约 0.3 秒不变，画面一直没变的等 1 秒，最多 3 秒）再返回新的一帧截图；App 冷启动这类更慢的，用 wait 再看。coordinate 是截图里的位置 [x, y]，单位同返回的 width、height，以最近一次截图为准。',
      'action：screenshot 只截图；left_click、double_click、right_click（模拟器没有）、long_press（duration 秒）点 coordinate；left_click_drag 从 start_coordinate 拖到 coordinate，模拟器上就是滑动；',
      'scroll 在 coordinate 处按 scroll_direction（up、down、left、right）滚 scroll_amount 格（默认 3）；type 输入 text（模拟器上先点要输入的框，中文也能输入）；key 按一个键或组合键，text 写键名，如 Enter、Escape、Backspace、Tab、ArrowDown、Control+A；',
      'wait 等 duration 秒（默认 1）再截图；网页另有 navigate（text 写本端口上的路径）、back、forward、reload，模拟器另有 home（回主屏幕）。',
      '网页画面可带 browser（webkit、chromium、firefox、safari）与 width、height（视口尺寸），操作的是并排视图里同样参数的那一格页面，不带时操作画面视图。',
      '用户起的预览也能操作，用 preview_list 找；在用户设备上看的网页（browser 为 device），你操作的是宿主在工作机 WebKit 里另开的同一个地址，用户看不到。',
    ].join(''),
    tool: 'preview_action', effect: 'write', retry: 'receipt',
    input: target.extend({
      action: z.enum(['screenshot', 'left_click', 'double_click', 'right_click', 'long_press', 'left_click_drag', 'scroll', 'type', 'key', 'wait',
        'navigate', 'back', 'forward', 'reload', 'home']),
      coordinate: coordinate.optional(), start_coordinate: coordinate.optional(), text: z.string().min(1).max(10_000).optional(),
      scroll_direction: z.enum(['up', 'down', 'left', 'right']).optional(), scroll_amount: z.number().int().min(1).max(50).optional(),
      duration: z.number().min(0.1).max(10).optional(), ...cell,
    }).strict(),
    output: previewFrame,
  },
  'preview.inspect': {
    title: '读取界面结构', description: '读预览画面的界面结构：网页是无障碍树（角色、名称与文字，Safari 是近似的轮廓），模拟器和 App 窗口是控件、文字与位置。找按钮、读文字比看截图准，也更省上下文。网页可带 browser 与 width、height，读的是 preview_action 同样参数的那一格页面。',
    tool: 'preview_inspect', effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, ...cell }).strict(), output: z.object({ text: z.string() }).strict(),
  },
  'preview.read': {
    title: '读取预览输出', description: '按行读预览进程的输出（目标脚本的终端画面与回滚里的文字）。不给 offset 时读最后 limit 行（默认 200）；结果带进程状态，结束了有退出码或原因。',
    tool: 'preview_read', effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).default(200) }).strict(),
    output: terminalStateSchema.extend({ instanceId: id, title: z.string(),
      text: z.string(), offset: z.number().int(), totalLines: z.number().int(), nextOffset: z.number().int().nullable() }).strict(),
  },
  'preview.list': {
    title: '列出预览', description: '列出本工作区的预览：目标、设备、画面种类（web、simulator、app，没有画面是 none）与网页端口、在哪看（device 是用户设备上的网页视图），进程状态，谁起的（createdBy 为空是用户）、有没有窗口。',
    tool: 'preview_list', effect: 'read', retry: 'read', input: z.object({}).strict(),
    output: z.object({ previews: z.array(z.object({ ...preview, createdBy: id.nullable(), window: z.boolean() }).strict()) }).strict(),
  },
  'preview.stop': {
    title: '停止预览', description: '停下预览的进程（整个进程树），等到结束才返回；没有窗口的预览随之回收。你自己停下的不再发结束通知。',
    tool: 'preview_stop', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'preview.select': {
    title: '设置预览', description: '改预览的网页在哪看：device 是设备自己的网页视图，其余是工作机上的浏览器，所有设备共用。',
    tool: null, effect: 'write', retry: 'receipt',
    input: target.extend({ browser: z.enum(previewBrowsers) }).strict(),
    output: z.object({ browser: z.enum(workstationBrowsers).optional() }).strict(),
  },
  'monitor.start': {
    title: '开始监视', description: [
      '开一个常驻的 monitor 盯着某件事，有事件时宿主把它们交给你，你空闲时会被唤醒。title 简短写清在盯什么，会出现在每次唤醒里。',
      '两种来源选一种：command 是 shell 命令，每一行标准输出是一个事件，命令退出也是一个事件并结束这个来源；at（带时区的 ISO 8601 时间）或 minutes（多少分钟后）是定时，repeat 为 daily 或 weekly 时按天或按周重复。',
      '命令在你的沙箱里、按你的执行授权运行，不能用密钥。只输出你会据此行动的行，成功和失败的信号都要覆盖（没有输出不等于成功）；grep 加 --line-buffered；轮询远程接口间隔 30 秒以上，单次失败用 || true 吞掉；等一件事完成就让命令在那时退出。',
      `事件太密（一分钟超过 ${MONITOR_BURST_LIMIT} 个）会被停掉，每天最多唤醒你 ${MONITOR_DAILY_WAKES} 次。工作机重启后命令重新开始，事件可能重复。不需要时用 monitor_stop 停掉。`,
    ].join(''),
    tool: 'monitor_start', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, title: z.string().trim().min(1).max(80), command: z.string().min(1).max(20_000).optional(),
      at: z.string().optional(), minutes: z.number().int().min(1).max(366 * 24 * 60).optional(), repeat: z.enum(['daily', 'weekly']).optional() }).strict(),
    output: z.object({ instanceId: id }).strict(),
  },
  'monitor.list': {
    title: '查看监视', description: '列出你协作范围内开着的 monitor：标题、谁开的、来源与是否已结束、今天唤醒的次数。',
    tool: 'monitor_list', effect: 'read', retry: 'read', input: z.object({}).strict(), output: z.object({ monitors: z.array(z.unknown()) }).strict(),
  },
  'monitor.stop': {
    title: '停止监视', description: '停掉一个 monitor：停下它的来源并归档。',
    tool: 'monitor_stop', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'monitor.read': {
    title: '读取 monitor', description: '读取 monitor 的来源与时间线；Line 的 monitor 返回收件箱。',
    tool: null, effect: 'read', retry: 'read', input: z.object({ instanceId: id }).strict(), output: z.unknown(),
  },
  'monitor.delegate': {
    title: '交给 Line', description: '把 Line 收件箱里的一项交给 Line 代处理，立即唤醒 Line。',
    tool: null, effect: 'write', retry: 'receipt', input: target.extend({ item: id }).strict(), output: z.unknown(),
  },
  'monitor.dismiss': {
    title: '知道了', description: '把收件箱里结束的回合移出；其余事项随原线程的状态解除才移出。',
    tool: null, effect: 'write', retry: 'receipt', input: target.extend({ item: id }).strict(), output: ok,
  },
  'monitor.hosting': {
    title: '设置托管', description: 'Line 的两种托管：按时段托管到 until（毫秒），超时托管 timeoutMinutes；null 关闭。',
    tool: null, effect: 'write', retry: 'receipt',
    input: target.extend({ until: z.number().nullable().optional(), timeoutMinutes: z.number().int().min(1).max(24 * 60).nullable().optional() }).strict(),
    output: z.object({ until: z.number().optional(), timeoutMinutes: z.number().optional() }).strict(),
  },
} as const;

export type OperationName = keyof typeof operationContracts;
export type OperationInput<N extends OperationName> = z.infer<(typeof operationContracts)[N]['input']>;
/**
 * ui 的 via 是另一台工作机上的 Line 经界面入口调用时声明的来源，只记入输入与收据，不参与授权。
 * relayed 表示 Line 照原文转达用户的话，输入来源仍是人。
 */
export type OperationCaller = { kind: 'ui'; via?: z.infer<typeof inputVia>; relayed?: boolean } | {
  kind: 'model' | 'plugin'; instanceId: string; turnId?: string; callId?: string;
};

const previewOperations = ['preview.open', 'preview.list', 'preview.action', 'preview.inspect', 'preview.read', 'preview.stop'] as const;

/**
 * 授权的目标：created 是调用方直接创建的，instances 是显式列出的；descendants（仅后代）按创建来源逐层往下算，
 * workspace（同工作区）是所属工作区的全部。list 只取后两种，决定列出哪些。
 */
const range = z.discriminatedUnion('kind', [z.object({ kind: z.literal('descendants') }).strict(), z.object({ kind: z.literal('workspace') }).strict()]);
const targets = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('created') }).strict(),
  z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict(),
  ...range.options,
]);
export type GrantTargets = z.infer<typeof targets>;
export type GrantRange = z.infer<typeof range>;
export const operationGrantsSchema = z.array(z.discriminatedUnion('operation', [
  z.object({ operation: z.literal('plugin.call'), instanceId: id, tools: z.array(id).min(1) }).strict(),
  z.object({ operation: z.literal('agent.start'), roleIds: z.array(id) }).strict(),
  ...(['agent.list', 'monitor.list', 'terminal.list'] as const).map((operation) => z.object({ operation: z.literal(operation), targets: range }).strict()),
  ...(['agent.send', 'agent.resume', 'agent.stop', 'agent.merge', 'monitor.stop', 'terminal.read', 'terminal.stop'] as const).map((operation) => z.object({ operation: z.literal(operation), targets }).strict()),
  z.object({ operation: z.literal('monitor.start') }).strict(),
  /** 预览的操作不分目标：本工作区的预览都能起、看、操作和停，不限创建来源。 */
  ...previewOperations.map((operation) => z.object({ operation: z.literal(operation) }).strict()),
  ...(['files.list', 'files.search', 'files.read', 'files.history', 'files.diff', 'files.state', 'files.select'] as const).map((operation) => z.object({ operation: z.literal(operation),
    targets: z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict() }).strict()),
  /** Line 的管理动作，目标范围是工作机目录里的全部工作区；actions 是用户允许的白名单。 */
  z.object({ operation: z.literal('line'), actions: z.array(z.enum(lineActions)) }).strict(),
]));
export type OperationGrant = z.infer<typeof operationGrantsSchema>[number];

/** 授权对应的模型工具；文件、插件授权不经模型工具。 */
export function grantTools(grant: OperationGrant): string[] {
  if (grant.operation === 'line') return lineToolNames.filter((tool) => lineToolActions[tool].some((action) => grant.actions.includes(action)));
  const tool = operationContracts[grant.operation].tool;
  return tool ? [tool] : [];
}

/** 仅宿主登记的代理获得默认授权：可按内置角色创建代理、开 monitor、用预览，协作范围默认同工作区。自定义 manifest 不能自行授予。 */
export function defaultOperationGrants(definitionId: string): OperationGrant[] {
  if (definitionId !== 'kite.agent') return [];
  return [{ operation: 'agent.start', roleIds: ['kite.work', 'kite.review'] }, { operation: 'monitor.start' },
    ...previewOperations.map((operation) => ({ operation })),
    ...scopedOperations.map((operation) => ({ operation, targets: { kind: 'workspace' } }) as OperationGrant)];
}

/** 授权里的协作范围：目标是仅后代或同工作区的那几项共用的范围，没有这类授权时为 undefined。 */
export const grantRange = (grants: OperationGrant[]): GrantRange | undefined => grants.flatMap((grant) =>
  'targets' in grant && (grant.targets.kind === 'descendants' || grant.targets.kind === 'workspace') ? [grant.targets] : [])[0];

/** Line 实例启用时得到的管理授权；其他代理即使角色放开了 Line 的工具，也要用户另行授予。 */
export const lineGrant: OperationGrant = { operation: 'line', actions: [...lineActions] };

/**
 * 协作操作的授权只给角色允许使用对应工具的代理，例如只读审查不带。创建和改选角色都按此调整：
 * 去掉新角色用不了的；旧角色用不了、新角色能用的补上默认授权，协作范围沿用原有的。两个角色都能用的保持原样，用户撤回的不会被补回。
 * 插件与文件授权不经模型工具，不受影响。
 */
export function roleOperationGrants(definitionId: string, grants: OperationGrant[], before: readonly string[], after: readonly string[]): OperationGrant[] {
  const usable = (grant: OperationGrant, tools: readonly string[]) => {
    const granted = grantTools(grant);
    return grant.operation !== 'line' && !granted.length || granted.some((tool) => tools.includes(tool));
  };
  const kept = grants.filter((grant) => usable(grant, after));
  const scope = grantRange(grants);
  return [...kept, ...defaultOperationGrants(definitionId).filter((grant) => usable(grant, after) && !usable(grant, before)
    && !kept.some((other) => other.operation === grant.operation)).map((grant) => scope && 'targets' in grant ? { ...grant, targets: scope } as OperationGrant : grant)];
}

export const operationToolNames = ['agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop', 'agent_merge', 'monitor_start', 'monitor_list', 'monitor_stop',
  'terminal_list', 'terminal_read', 'terminal_stop', 'preview_open', 'preview_action', 'preview_inspect', 'preview_read', 'preview_list', 'preview_stop'] as const;
const failure = z.object({ error: z.string(), outcome: z.enum(['denied', 'failed', 'cancelled', 'unknown']) }).strict();

export function operationCatalog() {
  return Object.entries(operationContracts).map(([name, contract]) => ({
    name, title: contract.title, description: contract.description, effect: contract.effect, retry: contract.retry,
    callers: contract.tool || name === 'plugin.call' ? ['ui', 'model', 'plugin'] : ['ui', 'plugin'], cancellation: '提交前可取消；提交后等待确定结果，不撤销已执行的动作',
    input: z.toJSONSchema(contract.input), output: z.toJSONSchema(contract.output), error: z.toJSONSchema(failure),
  }));
}
