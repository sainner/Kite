/** 文件工具限定在工作目录内；shell 按宿主权限执行，本层不声称提供操作系统沙箱。 */
import { existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, relative, resolve } from 'node:path';
import { applyDiff } from '@openai/agents-core/utils';
import { z } from 'zod';
import { within } from '../paths.ts';
import { runCommand, type CommandOptions } from './command.ts';
import type { Json, JsonObject, Tool, ToolResult } from './types.ts';

const readArgs = z.object({ path: z.string().min(1), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).optional() }).strict();
const patchArgs = z.object({ operations: z.array(z.discriminatedUnion('type', [
  z.object({ type: z.literal('create_file'), path: z.string().min(1), diff: z.string() }).strict(),
  z.object({ type: z.literal('update_file'), path: z.string().min(1), diff: z.string().min(1) }).strict(),
  z.object({ type: z.literal('delete_file'), path: z.string().min(1) }).strict(),
])).min(1) }).strict();
const shellArgs = z.object({ command: z.string().min(1), timeout_ms: z.number().int().min(1).max(600_000).optional() }).strict();

const patchDescription = `用补丁创建、修改或删除当前工作目录内的文本文件，可一次处理多个文件，每个文件只列一次。
operations 中每项包含 type、path；create_file 和 update_file 还需 diff，delete_file 不带 diff。
diff 使用无文件头的 V4A 格式，不含 *** Begin Patch、*** Update File 等包装，也不用行号或行数。
创建：每行以 + 开头；例如 "+甲\\n+乙\\n+" 创建带末尾换行的两行文件，空 diff 创建空文件。目标必须不存在。
修改：以 @@ 开始，空格开头是原文上下文，- 开头是删除行，+ 开头是新增行；例如 "@@\\n 甲\\n-乙\\n+丁\\n 丙"。
提供足够上下文定位目标；必要时用 @@ 函数名等原文行作为定位锚点。补丁按当前内容匹配，匹配失败就读取后重做。
建议先 read 了解内容；没有读取记录或文件读后变化仅提示，不阻止有效补丁。成功结果中的变化提示表示还有其他改动，依赖周边内容时请重读。
整批先检查路径并计算补丁再写入；磁盘写入失败可能留下已完成的修改，结果会列明，不能盲目重试整批。`;

export function localTools(options: CommandOptions): Tool[] {
  const root = realpathSync(options.cwd);
  const limit = options.outputLimit ?? 20_000;
  if (!Number.isSafeInteger(limit) || limit < 1) throw new Error('工具输出限制必须为正整数');
  // 只记录本次运行中读取或修改后已知的版本；不代表整文件仍在模型上下文里。
  const versions = new Map<string, string>();
  const hash = (content: string) => createHash('sha256').update(content).digest('hex');
  const pathOf = (path: string) => {
    const target = resolve(root, path);
    if (!within(target, root)) throw new Error('文件路径超出当前工作目录');
    // 检查每一层已有路径，包括指向不存在位置的符号链接。
    let cursor = root;
    for (const name of relative(root, target).split('/').filter(Boolean)) {
      cursor = resolve(cursor, name);
      try { lstatSync(cursor); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
        throw error;
      }
      if (!within(realpathSync(cursor), root)) throw new Error('文件路径的符号链接超出当前工作目录');
    }
    return target;
  };
  const readText = (path: string) => {
    const stat = statSync(path);
    if (!stat.isFile()) throw new Error('目标不是普通文件');
    if (stat.size > 2 * 1024 * 1024) throw new Error('文件超过 2 MiB，请用 shell 按范围读取');
    const content = readFileSync(path, 'utf8');
    if (content.includes('\0')) throw new Error('文件不是可直接处理的文本');
    return content;
  };
  const make = <T extends z.ZodType>(name: string, description: string, schema: T,
    execute: (args: z.output<T>, signal: AbortSignal) => Promise<ToolResult>, parallel = false): Tool => ({
    name, description, parameters: z.toJSONSchema(schema) as JsonObject, parallel,
    validate: (args: Json) => { schema.parse(args); },
    execute: async (args, { signal }) => { signal.throwIfAborted(); return execute(schema.parse(args), signal); },
  });
  return [
    make('read', '按行读取当前工作目录内的文本文件；offset 从 1 开始，默认最多 200 行。', readArgs, async ({ path, offset = 1, limit: count = 200 }) => {
      const target = pathOf(path);
      const content = readText(target);
      const lines = content.split('\n');
      const selected = lines.slice(offset - 1, offset - 1 + count).map((line, i) => `${offset + i}: ${line}`).join('\n');
      const output = selected.length > limit ? `${selected.slice(0, limit)}\n（输出已截断，请缩小读取范围）` : selected;
      versions.set(realpathSync(target), hash(content));
      return { status: 'success', output: `共 ${lines.length} 行\n${output}` };
    }, true),
    make('patch', patchDescription, patchArgs, async ({ operations }) => {
      const paths = new Set<string>();
      const plan = operations.map((operation) => {
        const { path, type } = operation;
        const target = pathOf(path);
        const present = existsSync(target);
        const key = present ? realpathSync(target) : target;
        if (paths.has(key)) throw new Error(`同批补丁不能重复操作文件：${path}`);
        paths.add(key);
        if (type === 'create_file' && present) throw new Error(`新建目标已经存在：${path}`);
        const original = type === 'create_file' ? '' : readText(target);
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
        return { path, type, target, key, content, notice };
      });
      const output: string[] = [];
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
          output.push(`已${change.type === 'create_file' ? '创建' : change.type === 'delete_file' ? '删除' : '修改'} ${change.path}`);
          if (change.notice) output.push(change.notice);
        } catch (error) {
          output.push(`${change.path} 写入失败：${error instanceof Error ? error.message : String(error)}。已列出的修改不会自动回滚，请检查实际文件后继续。`);
          return { status: 'error', output: output.join('\n') };
        }
      }
      return { status: 'success', output: output.join('\n') };
    }),
    make('shell', '在当前工作目录运行 shell 命令，可用 rg 搜索、运行构建及 .kite/check；不支持后台任务。输出过长时查看完整日志。', shellArgs,
      ({ command, timeout_ms = 120_000 }, signal) => runCommand(command, timeout_ms, signal, { ...options, cwd: root })),
  ];
}
