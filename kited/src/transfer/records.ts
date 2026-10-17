/**
 * 工作区记录：数据库行、各线程的会话目录（journal、控制状态、命令日志）、历史差异与 Claude 原生记录。
 * 平时以副本跟进到其他工作机（replica.ts），接管时按这里装到本机：改写会话的目录与 Claude 原生记录的 cwd，
 * 通知游标随清单带过去，用来给未交接的通知重新编号。
 */
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { claudeRecordTarget } from '../handoff/claude-records.ts';
import type { WorkspaceRows } from '../store.ts';

export const manifestSchema = z.object({
  version: z.literal(1),
  workspaceId: z.string().min(1),
  epoch: z.number().int().positive(),
  /** 交出执行权的工作机。 */
  machine: z.string().min(1),
  projectId: z.string().min(1),
  name: z.string(),
  branch: z.string().min(1),
  base: z.string().min(1),
  cwd: z.string().min(1),
  threads: z.array(z.object({ instanceId: z.string().min(1), runtime: z.enum(['claude', 'harness']), nativeId: z.string().min(1),
    /** 已交接给模型的最后一条通知的序号。 */
    cursor: z.number().int().nonnegative() }).strict()),
  at: z.number().int(),
}).strict();
export type RecordsManifest = z.infer<typeof manifestSchema>;

const mapLines = (text: string, map: (entry: Record<string, unknown>) => unknown) =>
  text.split('\n').filter(Boolean).map((line) => JSON.stringify(map(JSON.parse(line)))).join('\n') + (text.trim() ? '\n' : '');

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
 * 放到 CLI 按新目录查找的位置）。调用方先按 recordPaths 备份并登记失败时的回滚。
 */
export function installRecords(dir: string, manifest: RecordsManifest, home: string, cwd: string): void {
  const real = realpathSync(cwd);
  for (const thread of manifest.threads) {
    const source = join(dir, 'sessions', thread.instanceId);
    const target = join(home, 'sessions', thread.instanceId);
    if (existsSync(source)) {
      mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
      cpSync(source, target, { recursive: true });
      const metadata = join(target, 'metadata.json');
      if (existsSync(metadata)) writeFileSync(metadata, JSON.stringify({ ...JSON.parse(readFileSync(metadata, 'utf8')), cwd: real }, null, 2) + '\n');
    }
    const claude = join(dir, 'claude', `${thread.nativeId}.jsonl`);
    if (existsSync(claude)) {
      const path = claudeRecordTarget(real, thread.nativeId);
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      writeFileSync(path, mapLines(readFileSync(claude, 'utf8'), (entry) => entry.cwd === manifest.cwd ? { ...entry, cwd: real } : entry), { mode: 0o600 });
    }
  }
  const diffs = join(dir, 'diffs');
  if (existsSync(diffs) && statSync(diffs).isDirectory() && readdirSync(diffs).length) {
    cpSync(diffs, join(home, 'diffs', manifest.workspaceId), { recursive: true });
  }
}
