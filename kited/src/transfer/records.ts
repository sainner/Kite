/**
 * 流转材料里的 records：工作区的数据库行、各线程的会话目录（journal、控制状态、命令日志）、历史差异与 Claude 原生记录。
 * 材料按「有仓库读权限的人都能看」来定：不含锁、进程登记与凭据；工具结果里的图片换成说明文字。
 * 目标机安装时改写会话的目录与 Claude 原生记录的 cwd，通知游标随清单带过去，用来给未交接的通知重新编号。
 */
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { readClaudeControl } from '../claude/control.ts';
import { claudeRecordPath, claudeRecordTarget } from '../handoff/claude-records.ts';
import { readJournal } from '../harness/journal.ts';
import type { AgentInstance, Workspace } from '../model.ts';
import type { WorkspaceRows } from '../store.ts';

export const manifestSchema = z.object({
  version: z.literal(1),
  workspaceId: z.string().min(1),
  epoch: z.number().int().positive(),
  /** 交出执行权的工作机。 */
  machine: z.string().min(1),
  projectId: z.string().min(1),
  kind: z.enum(['root', 'worktree']),
  name: z.string(),
  branch: z.string().nullable(),
  base: z.string().nullable(),
  cwd: z.string().min(1),
  /** 根工作区交接时检出的 HEAD，目标检出须能快进到它。 */
  head: z.string().nullable(),
  threads: z.array(z.object({ instanceId: z.string().min(1), runtime: z.enum(['claude', 'harness']), nativeId: z.string().min(1),
    /** 已交接给模型的最后一条通知的序号。 */
    cursor: z.number().int().nonnegative() }).strict()),
  at: z.number().int(),
}).strict();
export type RecordsManifest = z.infer<typeof manifestSchema>;

const sessionFiles = ['journal.jsonl', 'metadata.json', 'claude-control.json'];
const IMAGE_NOTE = '[流转时去掉了一张图片]';

/** 去掉图片：Kite 工具结果的 images 合进正文说明；Anthropic 格式的图片块换成文字块。 */
function stripImages(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripImages);
  if (!value || typeof value !== 'object') return value;
  const object = value as Record<string, unknown>;
  if (object.type === 'image' && object.source && typeof object.source === 'object') return { type: 'text', text: IMAGE_NOTE };
  const result: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(object)) {
    if (key === 'images' && Array.isArray(entry)) continue;
    result[key] = stripImages(entry);
  }
  if (Array.isArray(object.images) && object.images.length && typeof object.output === 'string') {
    result.output = `${object.output}\n${object.images.map(() => IMAGE_NOTE).join('\n')}`;
  }
  return result;
}

const mapLines = (text: string, map: (entry: Record<string, unknown>) => unknown) =>
  text.split('\n').filter(Boolean).map((line) => JSON.stringify(map(JSON.parse(line)))).join('\n') + (text.trim() ? '\n' : '');

/** harness 的通知游标与它恢复时的算法一致：请求开始记录里交接的通知，以及跨后端导入时带过来的游标。 */
function journalCursor(path: string): number {
  let cursor = 0;
  for (const row of readJournal(path)) {
    if (row.type === 'request.started') for (const notification of row.notifications ?? []) cursor = Math.max(cursor, notification.sequence ?? 0);
    if (row.type === 'context.imported') cursor = Math.max(cursor, row.notificationCursor);
  }
  return cursor;
}

/** 把工作区的记录写进 dir，返回清单。线程须已停下，会话文件不再变化。 */
export function writeRecords(dir: string, options: { home: string; machine: string; projectId: string; workspace: Workspace;
  head: string | null; threads: AgentInstance[]; rows: WorkspaceRows }): RecordsManifest {
  const { home, workspace } = options;
  const threads = options.threads.map((thread) => {
    const source = join(home, 'sessions', thread.id);
    const target = join(dir, 'sessions', thread.id);
    mkdirSync(target, { recursive: true });
    for (const name of sessionFiles) {
      const path = join(source, name);
      if (!existsSync(path)) continue;
      const text = readFileSync(path, 'utf8');
      writeFileSync(join(target, name), name === 'journal.jsonl' ? mapLines(text, stripImages)
        : name === 'claude-control.json' ? JSON.stringify({ ...JSON.parse(text), processes: [] }) : text);
    }
    if (existsSync(join(source, 'commands'))) cpSync(join(source, 'commands'), join(target, 'commands'), { recursive: true });
    const claude = claudeRecordPath(workspace.cwd, thread.nativeId);
    if (claude) {
      mkdirSync(join(dir, 'claude'), { recursive: true });
      writeFileSync(join(dir, 'claude', `${thread.nativeId}.jsonl`), mapLines(readFileSync(claude, 'utf8'), stripImages));
    }
    return { instanceId: thread.id, runtime: thread.runtime, nativeId: thread.nativeId,
      cursor: thread.runtime === 'claude' ? readClaudeControl(source).through : journalCursor(join(source, 'journal.jsonl')) };
  });
  const diffs = join(home, 'diffs', workspace.id);
  if (existsSync(diffs)) cpSync(diffs, join(dir, 'diffs'), { recursive: true });
  writeFileSync(join(dir, 'rows.json'), JSON.stringify(options.rows));
  // Claude 原生记录里的 cwd 是进程的真实路径。
  const manifest: RecordsManifest = { version: 1, workspaceId: workspace.id, epoch: workspace.epoch, machine: options.machine,
    projectId: options.projectId, kind: workspace.kind, name: workspace.name, branch: workspace.branch, base: workspace.base,
    cwd: realpathSync(workspace.cwd), head: options.head, threads, at: Date.now() };
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest));
  return manifest;
}

export function readRecords(dir: string): { manifest: RecordsManifest; rows: WorkspaceRows } {
  const parsed = manifestSchema.safeParse(JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')));
  if (!parsed.success) throw new Error('流转记录的清单无效，可能来自不同版本的 Kite');
  return { manifest: parsed.data, rows: JSON.parse(readFileSync(join(dir, 'rows.json'), 'utf8')) };
}

/** installRecords 可能写到的本机路径：各线程的会话目录与 Claude 原生记录、工作区的历史差异。cwd 须已存在。 */
export function recordPaths(manifest: RecordsManifest, home: string, cwd: string): string[] {
  const real = realpathSync(cwd);
  return [...manifest.threads.flatMap((thread) => [join(home, 'sessions', thread.instanceId), claudeRecordTarget(real, thread.nativeId)]),
    join(home, 'diffs', manifest.workspaceId)];
}

/**
 * 把记录装到本机：会话目录（metadata 的 cwd 改成新目录）、历史差异，以及 Claude 原生记录（cwd 字段改成新目录，
 * 放到 CLI 按新目录查找的位置）。返回写下的路径，失败时由调用方删除。
 */
export function installRecords(dir: string, manifest: RecordsManifest, home: string, cwd: string): string[] {
  const written: string[] = [];
  const real = realpathSync(cwd);
  for (const thread of manifest.threads) {
    const source = join(dir, 'sessions', thread.instanceId);
    const target = join(home, 'sessions', thread.instanceId);
    if (existsSync(source)) {
      mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
      cpSync(source, target, { recursive: true });
      written.push(target);
      const metadata = join(target, 'metadata.json');
      if (existsSync(metadata)) writeFileSync(metadata, JSON.stringify({ ...JSON.parse(readFileSync(metadata, 'utf8')), cwd: real }, null, 2) + '\n');
    }
    const claude = join(dir, 'claude', `${thread.nativeId}.jsonl`);
    if (existsSync(claude)) {
      const path = claudeRecordTarget(real, thread.nativeId);
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      writeFileSync(path, mapLines(readFileSync(claude, 'utf8'), (entry) => entry.cwd === manifest.cwd ? { ...entry, cwd: real } : entry), { mode: 0o600 });
      written.push(path);
    }
  }
  const diffs = join(dir, 'diffs');
  if (existsSync(diffs) && statSync(diffs).isDirectory() && readdirSync(diffs).length) {
    cpSync(diffs, join(home, 'diffs', manifest.workspaceId), { recursive: true });
    written.push(join(home, 'diffs', manifest.workspaceId));
  }
  return written;
}
