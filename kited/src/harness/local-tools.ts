/** 文件工具限定在工作目录内；shell 按宿主权限执行，本层不声称提供操作系统沙箱。 */
import { lstatSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { z } from 'zod';
import { within } from '../paths.ts';
import { runCommand, type CommandOptions } from './command.ts';
import type { Json, JsonObject, Tool, ToolResult } from './types.ts';

const readArgs = z.object({ path: z.string().min(1), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).optional() }).strict();
const writeArgs = z.object({ path: z.string().min(1), content: z.string() }).strict();
const editArgs = z.object({ path: z.string().min(1), old_text: z.string().min(1), new_text: z.string() }).strict();
const shellArgs = z.object({ command: z.string().min(1), timeout_ms: z.number().int().min(1).max(600_000).optional() }).strict();

export function localTools(options: CommandOptions): Tool[] {
  const root = realpathSync(options.cwd);
  const limit = options.outputLimit ?? 20_000;
  if (!Number.isSafeInteger(limit) || limit < 1) throw new Error('工具输出限制必须为正整数');
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
    make('read_file', '按行读取当前工作目录内的文本文件；offset 从 1 开始，默认最多 200 行。', readArgs, async ({ path, offset = 1, limit: count = 200 }) => {
      const lines = readText(pathOf(path)).split('\n');
      const selected = lines.slice(offset - 1, offset - 1 + count).map((line, i) => `${offset + i}: ${line}`).join('\n');
      const output = selected.length > limit ? `${selected.slice(0, limit)}\n（输出已截断，请缩小读取范围）` : selected;
      return { status: 'success', output: `共 ${lines.length} 行\n${output}` };
    }, true),
    make('write_file', '创建或覆盖当前工作目录内的文本文件，覆盖前先读取确认。', writeArgs, async ({ path, content }) => {
      const target = pathOf(path);
      mkdirSync(dirname(target), { recursive: true });
      writeFileSync(target, content);
      return { status: 'success', output: `已写入 ${path}，${Buffer.byteLength(content)} 字节` };
    }),
    make('edit_file', '将文本中唯一匹配的 old_text 替换为 new_text；必须先读取文件，匹配不唯一时拒绝修改。', editArgs, async ({ path, old_text, new_text }) => {
      const target = pathOf(path);
      const content = readText(target);
      const first = content.indexOf(old_text);
      if (first < 0 || content.indexOf(old_text, first + 1) >= 0) throw new Error('old_text 必须在文件中恰好出现一次');
      writeFileSync(target, content.slice(0, first) + new_text + content.slice(first + old_text.length));
      return { status: 'success', output: `已修改 ${path}` };
    }),
    make('shell', '在当前工作目录运行 shell 命令，可用 rg 搜索、运行构建及 .kite/check；不支持后台任务。输出过长时查看完整日志。', shellArgs,
      ({ command, timeout_ms = 120_000 }, signal) => runCommand(command, timeout_ms, signal, { ...options, cwd: root })),
  ];
}
