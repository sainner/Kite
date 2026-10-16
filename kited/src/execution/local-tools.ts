/** 文件工具限定在工作目录内；shell 通过工作机共用的操作系统沙箱执行。 */
import { existsSync, mkdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { dirname, join, relative } from 'node:path';
import { applyDiff } from '@openai/agents-core/utils';
import { z } from 'zod';
import { WorkspaceFiles, readFileArgs } from '../workspace/files.ts';
import { PDF_PAGE_SPAN, PdfReader, fileKind, readImage } from '../workspace/documents.ts';
import { FileDiffStore, type FileDiff } from '../workspace/file-diffs.ts';
import { runCommand, type BackgroundCommand, type CommandOptions } from './command.ts';
import { assertFileAccess, commandEnvironment, workspacePolicy, type ExecutionPolicy } from './sandbox.ts';
import type { Json, JsonObject, Tool, ToolResult } from '../harness/types.ts';
import { secretBindings, secretValue, type SecretProvider, type SecretValue } from '../secrets.ts';

export const patchArgs = z.object({ operations: z.array(z.discriminatedUnion('type', [
  z.object({ type: z.literal('create_file'), path: z.string().min(1), diff: z.string() }).strict(),
  z.object({ type: z.literal('update_file'), path: z.string().min(1), diff: z.string().min(1) }).strict(),
  z.object({ type: z.literal('delete_file'), path: z.string().min(1) }).strict(),
])).min(1) }).strict();
const readArgs = readFileArgs.extend({
  pages: z.string().regex(/^\d+(-\d+)?$/, 'pages 须为页码或范围，如 "3" 或 "3-5"').optional()
    .describe(`只用于 PDF：要读取的页码或范围，如 "3" 或 "3-5"，一次最多 ${PDF_PAGE_SPAN} 页；省略时从第 1 页开始。`),
}).strict();
const shellArgs = z.object({
  description: z.string().min(1).regex(/\S/, 'description 不能为空白')
    .describe('用简短的话说明本次命令的用途，直接展示给用户，不重复命令文本。'),
  command: z.string().min(1),
  secrets: secretBindings.optional().describe('密钥引用绑定，如 {"KITE_SECRET_TOKEN":"{account.api_key}"}。命令中用 "$KITE_SECRET_TOKEN"；文件类型变量是临时文件路径。先用 credentials 查看可用引用。'),
  timeout_ms: z.number().int().min(1).max(600_000).optional(),
}).strict();
const backgroundArg = z.boolean().optional().describe('true 时命令一开始就在后台终端里运行，立刻返回；用于开发服务器、监听构建这类不会自己结束或要跑很久的命令。');
const outsideArg = z.boolean().optional().describe('true 时申请这条命令不进沙箱，以用户身份运行；description 写清用途和为什么沙箱里跑不了。');
const fullShellArgs = shellArgs.extend({ background: backgroundArg, outside_sandbox: outsideArg }).strict();

/** 宿主决定一条命令能不能在沙箱外运行（docs/工具审批与提问.md）。 */
export interface ShellOutside {
  /** 按生效的沙箱外命令与项目禁止判断这条调用：allowed 直接出沙箱，denied 不能出沙箱，unlisted 要申请。 */
  verdict(command: string): 'allowed' | 'denied' | 'unlisted';
  /** 申请出沙箱：按审批模式放行、拒绝或问人；「允许并记住」由宿主写进实例。 */
  ask(command: string, description: string, signal: AbortSignal): Promise<boolean>;
}

/** 宿主提供后台终端时，shell 的长命令转到后台接着跑，见 terminal/terminals.ts。 */
export interface ShellBackground {
  /** 用户发来了消息：正在跑的命令转后台，好让消息送到模型。返回取消订阅。 */
  interjected(listener: () => void): () => void;
  /** 把转到后台的命令交给一个终端实例，返回告诉模型的说明。 */
  adopt(command: BackgroundCommand, info: { description: string; command: string; turnId?: string; callId?: string }): string;
}

const patchDescription = `用补丁创建、修改或删除当前工作目录内的文本文件，可一次处理多个文件，每个文件只列一次。
operations 中每项包含 type、path；create_file 和 update_file 还需 diff，delete_file 不带 diff。
diff 使用无文件头的 V4A 格式，不含 *** Begin Patch、*** Update File 等包装，也不用行号或行数。
创建：每行以 + 开头；例如 "+甲\\n+乙\\n+" 创建带末尾换行的两行文件，空 diff 创建空文件。目标必须不存在。
修改：以 @@ 开始，空格开头是原文上下文，- 开头是删除行，+ 开头是新增行；例如 "@@\\n 甲\\n-乙\\n+丁\\n 丙"。
提供足够上下文定位目标；必要时用 @@ 函数名等原文行作为定位锚点。补丁按当前内容匹配，匹配失败就读取后重做。
建议先 read 了解内容；没有读取记录或文件读后变化仅提示，不阻止有效补丁。成功结果中的变化提示表示还有其他改动，依赖周边内容时请重读。
整批先检查路径并计算补丁再写入；磁盘写入失败可能留下已完成的修改，结果会列明，不能盲目重试整批。
结果中的 path:diffId 是这次已完成修改的历史引用，可直接在回复中使用；可写 path:diffId:10-20 定位修改后的文件行号，不需要区分旧侧和新侧。`;

const readDescription = `读取当前工作目录内的文件，按内容自动区分：
文本按行返回并带行号，offset 从 1 开始，默认最多 200 行。
图片（PNG、JPEG、WebP、GIF、BMP、TIFF、HEIC）附给你直接查看，过大时先缩放。
PDF 转为 Markdown 按页返回，用 pages 选页；结果会说明总页数和续读的 pages。没有文本层的扫描页给出 OCR 结果并附上页面图片。`;

export function localTools(options: Omit<CommandOptions, 'policy' | 'credentials' | 'background'> & { diffDir?: string; policy?: ExecutionPolicy | (() => ExecutionPolicy);
  secrets?: SecretProvider; background?: ShellBackground; outside?: ShellOutside }): Tool[] {
  const files = new WorkspaceFiles(options.cwd);
  const root = files.root;
  const policy = () => typeof options.policy === 'function' ? options.policy() : options.policy ?? workspacePolicy(root, options.env);
  const diffs = new FileDiffStore(options.diffDir ?? join(options.logDir, 'diffs'));
  const limit = options.outputLimit ?? 20_000;
  if (!Number.isSafeInteger(limit) || limit < 1) throw new Error('工具输出限制必须为正整数');
  // 只记录本次运行中读取或修改后已知的版本；不代表整文件仍在模型上下文里。
  const versions = new Map<string, string>();
  const pdfs = new PdfReader(commandEnvironment(options.env));
  const hash = (content: string) => createHash('sha256').update(content).digest('hex');
  const make = <T extends z.ZodType>(name: string, description: string, schema: T,
    execute: (args: z.output<T>, signal: AbortSignal, output: Parameters<Tool['execute']>[1]['output'], context: Parameters<Tool['execute']>[1]) => Promise<ToolResult>,
    parallel = false): Tool => ({
    name, description, parameters: z.toJSONSchema(schema) as JsonObject, parallel,
    validate: (args: Json) => { schema.parse(args); },
    execute: async (args, context) => { context.signal.throwIfAborted(); return execute(schema.parse(args), context.signal, context.output, context); },
  });
  const background = options.background;
  const shellDescription = '在当前工作目录的操作系统沙箱中运行 shell 命令，可用 rg 搜索、运行构建及 .kite/check。网络和工作区外的资源按宿主授权访问，连接授权之外的主机时可能要等用户批准；被禁止或拒绝时说明所需权限，不自行绕过或重放。'
    + (background
      ? '命令到 timeout_ms（默认 2 分钟）还没结束、或者用户发来新消息时不会被停掉，而是转到后台终端接着跑，工具立刻返回终端的实例 ID；开发服务器这类不会自己结束的命令直接传 background: true。后台命令结束时宿主会通知你，不要用 sleep 或轮询等它；要看中途输出用 terminal_read，不再需要时用 terminal_stop 停下。转到后台后连接名单外的主机直接拒绝，不再问人。带 secrets 的命令不转后台，到时限就停。'
      : '不支持后台任务。')
    + (options.outside
      ? '沙箱里跑不了的命令（开发服务器监听端口、docker、打开 App 或浏览器、连本机的服务、ssh 和数据库客户端这类不走代理的网络工具）传 outside_sandbox: true 申请在沙箱外运行，description 写清用途和为什么要出沙箱；获准后以用户身份运行，不受执行授权限制。用户事先允许的沙箱外命令不用申请，直接在沙箱外运行。不要为绕开执行授权申请出沙箱。'
      : '')
    + 'Git 元数据只读，快照与采纳由宿主执行。输出过长时查看完整日志。使用 secrets 绑定密钥时只返回执行状态，隐藏全部标准输出和错误输出；不要把密钥写入工作区文件、命令参数或日志。';
  return [
    make('read', readDescription, readArgs, async ({ pages, ...args }, signal) => {
      const target = files.resolve(args.path);
      assertFileAccess(target, 'read', policy());
      const kind = fileKind(target);
      if (kind !== 'pdf' && pages !== undefined) throw new Error('pages 只用于 PDF');
      if (kind !== 'text' && (args.offset !== undefined || args.limit !== undefined)) throw new Error('offset 和 limit 只用于文本文件');
      if (kind !== 'text') {
        try {
          if (kind === 'pdf') return { status: 'success', ...await pdfs.read(target, pages, limit, signal) };
          const { image, width, height, source } = await readImage(target);
          const size = width === source.width && height === source.height ? `${width}×${height}` : `原始 ${source.width}×${source.height}，已缩放到 ${width}×${height}`;
          return { status: 'success', output: `图片 ${relative(root, target)}（${source.format.toUpperCase()}，${size}），已附上供查看。`, images: [image] };
        } catch (error) {
          // 读取没有副作用，停止时按普通错误结束，不进入结果未知的恢复流程。
          if (signal.aborted) return { status: 'error', output: '读取已停止' };
          throw error;
        }
      }
      const result = files.read(args);
      const selected = result.offset > result.totalLines ? '' : result.text.split('\n').map((line, i) => `${result.offset + i}: ${line}`).join('\n');
      const output = selected.length > limit ? `${selected.slice(0, limit)}\n（输出已截断，请缩小读取范围）` : selected;
      versions.set(realpathSync(files.resolve(args.path)), result.version);
      return { status: 'success', output: `共 ${result.totalLines} 行\n${output}` };
    }, true),
    make('patch', patchDescription, patchArgs, async ({ operations }) => {
      // 同一工作区的线程并行时，整批的读、算、写在一个同步段里完成：同一进程里别的线程的 patch 插不进来，
      // 后到的按新内容匹配，改到同一处就明确失败。这里不能在读到写之间 await。
      const granted = policy();
      const paths = new Set<string>();
      const plan = operations.map((operation) => {
        const { path, type } = operation;
        const target = files.resolve(path);
        assertFileAccess(target, 'write', granted);
        if (type !== 'create_file') assertFileAccess(target, 'read', granted);
        const present = existsSync(target);
        const key = present ? realpathSync(target) : target;
        if (paths.has(key)) throw new Error(`同批补丁不能重复操作文件：${path}`);
        paths.add(key);
        if (type === 'create_file' && present) throw new Error(`新建目标已经存在：${path}`);
        const original = type === 'create_file' ? '' : files.text(target);
        const known = versions.get(key);
        const notice = type === 'create_file' ? '' : known === undefined
          ? `提示：${path} 没有本次运行的读取或修改记录；依赖周边内容时请先 read。`
          : known !== hash(original) ? `提示：${path} 自上次读取或修改后已有其他变化；依赖周边内容时请重新 read。` : '';
        let content: string | null = null;
        if (type !== 'delete_file') {
          // applyDiff 接收单文件正文；拒绝包装头，避免上游把它当终止符而忽略后续内容。
          const lines = operation.diff.replace(/\r\n/g, '\n').split('\n');
          if (lines.at(-1) === '') lines.pop();
          if (lines.some((line, i) => line.startsWith('***') && (line !== '*** End of File' || i !== lines.length - 1))) {
            throw new Error(`${path} 的 diff 必须是无文件头的 V4A 补丁`);
          }
          try { content = applyDiff(original, operation.diff, type === 'create_file' ? 'create' : 'default'); }
          catch (error) { throw new Error(`${path} 的补丁无法应用，请 read 后重新生成：${error instanceof Error ? error.message : String(error)}`); }
          if (content.includes('\0')) throw new Error(`补丁只支持文本文件：${path}`);
        }
        return { path: relative(root, target), type, target, key, original: type === 'create_file' ? null : original, content, notice };
      });
      const output: string[] = [];
      const diff: FileDiff = { id: `diff_${randomUUID()}`, files: [] };
      const reference = () => diff.files.length ? { id: diff.id, paths: diff.files.map((file) => file.path) } : undefined;
      for (const change of plan) {
        try {
          if (change.content === null) {
            unlinkSync(change.target);
            versions.delete(change.key);
          } else {
            mkdirSync(dirname(change.target), { recursive: true });
            writeFileSync(change.target, change.content, { flag: change.type === 'create_file' ? 'wx' : 'w' });
            versions.set(realpathSync(change.target), hash(change.content));
          }
          const completed = { path: change.path, before: change.original, after: change.content };
          try { diffs.save({ ...diff, files: [...diff.files, completed] }); }
          catch (error) {
            return { status: 'error', output: [...output, `${change.path} 已修改，但保存历史差异失败：${String(error)}`].join('\n'), diff: reference() };
          }
          diff.files.push(completed);
          output.push(`引用：${change.path}:${diff.id}`);
          output.push(`已${change.type === 'create_file' ? '创建' : change.type === 'delete_file' ? '删除' : '修改'} ${change.path}`);
          if (change.notice) output.push(change.notice);
        } catch (error) {
          output.push(`${change.path} 写入失败：${error instanceof Error ? error.message : String(error)}。已列出的修改不会自动回滚，请检查实际文件后继续。`);
          return { status: 'error', output: output.join('\n'), diff: reference() };
        }
      }
      return { status: 'success', output: output.join('\n'), diff: reference() };
    }),
    // 宿主给了哪项能力，shell 才收对应的参数；执行时按全部参数读，没收的自然为空。
    make('shell', shellDescription, (background && options.outside ? fullShellArgs
      : background ? shellArgs.extend({ background: backgroundArg }).strict()
        : options.outside ? shellArgs.extend({ outside_sandbox: outsideArg }).strict() : shellArgs) as typeof fullShellArgs,
      async (args, signal, output, context) => {
        const { command, description, secrets, timeout_ms = 120_000 } = args;
        const confidential = !!secrets && Object.keys(secrets).length > 0;
        // 带凭据的命令总在沙箱里；用户允许过的沙箱外命令直接出沙箱，没允许过的要申请。
        const verdict = options.outside && !confidential ? options.outside.verdict(command) : 'unlisted';
        let unsandboxed = verdict === 'allowed';
        if (args.outside_sandbox && !unsandboxed) {
          if (!options.outside) return { status: 'error', output: '这里不能申请在沙箱外运行命令。' };
          if (confidential) return { status: 'error', output: '带 secrets 的命令只能在沙箱里运行，命令没有执行。' };
          if (verdict === 'denied') return { status: 'error', output: '项目禁止这条命令在沙箱外运行，命令没有执行。' };
          if (!await options.outside.ask(command, description, signal)) return { status: 'error', output: '没有获准在沙箱外运行，命令没有执行。' };
          signal.throwIfAborted();
          unsandboxed = true;
        }
        const credentials: Record<string, SecretValue> = {};
        if (secrets && Object.keys(secrets).length) {
          if (!options.secrets) throw new Error('当前宿主未连接凭据服务');
          const references = [...new Set(Object.values(secrets))];
          const resolved = await options.secrets.resolve(references, signal);
          signal.throwIfAborted();
          for (const [key, reference] of Object.entries(secrets)) {
            const found = resolved.find((entry) => entry.reference === reference);
            const parsed = found && secretValue.safeParse({ kind: found.kind, value: found.value });
            if (!parsed?.success) throw new Error(`无法使用密钥 ${reference}`);
            credentials[key] = parsed.data;
          }
        }
        // 只有这次命令运行期间到的消息才让它转后台。
        const interjection = new AbortController();
        const unsubscribe = background?.interjected(() => interjection.abort());
        try {
          return await runCommand(command, timeout_ms, signal, { ...options, cwd: root, policy: policy(), credentials, onOutput: output ?? options.onOutput,
            ...(unsandboxed ? { unsandboxed: true, askNetwork: undefined } : {}),
            background: background && { now: interjection.signal, immediately: args.background === true,
              adopt: (adopted) => background.adopt(adopted, { description, command, turnId: context.turnId, callId: context.callId }) } });
        } finally { unsubscribe?.(); }
      }),
    make('credentials', '列出本账号共享和当前项目的可用密钥引用及类型，不返回密钥内容。仅在 shell 的 secrets 参数里使用这些引用，项目身份由宿主固定。', z.object({}).strict(), async (_, signal) => {
      if (!options.secrets?.list) throw new Error('当前宿主未连接凭据服务');
      const entries = await options.secrets.list(signal);
      // 即使服务误带额外字段，也不能将明文作为工具结果返回。
      return { status: 'success', output: JSON.stringify(entries.map(({ reference, kind }) => ({ reference, kind }))) };
    }, true),
  ];
}
