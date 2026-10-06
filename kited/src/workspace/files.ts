/** 文件插件与 agent 共用工作目录边界和文本读取；不提供操作系统沙箱。 */
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { z } from 'zod';
import { within } from '../paths.ts';
import { KiteError } from '../errors.ts';
import { diffID } from './file-diffs.ts';

export const readFileArgs = z.object({ path: z.string().min(1), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).optional() }).strict();
export const fileSelectionSchema = z.object({ path: z.string().nullable(), diffId: diffID.optional(), revision: z.string() }).strict();
export type FileSelection = z.infer<typeof fileSelectionSchema>;
export const fileSelection = (state: Record<string, unknown>): FileSelection => fileSelectionSchema.parse({ path: null, revision: 'initial', ...state });

export class WorkspaceFiles {
  readonly root: string;
  constructor(cwd: string) { this.root = realpathSync(cwd); }

  resolve(path: string): string {
    const target = resolve(this.root, path);
    if (!within(target, this.root)) throw new KiteError('文件路径超出当前工作目录', 403);
    // 每一层已有路径都核验，包含指向不存在位置的符号链接。
    let cursor = this.root;
    for (const name of relative(this.root, target).split('/').filter(Boolean)) {
      cursor = resolve(cursor, name);
      try { lstatSync(cursor); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
        throw error;
      }
      if (!within(realpathSync(cursor), this.root)) throw new KiteError('文件路径的符号链接超出当前工作目录', 403);
    }
    return target;
  }

  text(path: string): string {
    const target = this.resolve(path);
    const stat = statSync(target);
    if (!stat.isFile()) throw new KiteError('目标不是普通文件');
    if (stat.size > 2 * 1024 * 1024) throw new KiteError('文件超过 2 MiB，请用 shell 按范围读取');
    const content = readFileSync(target, 'utf8');
    if (content.includes('\0')) throw new KiteError('文件不是可直接处理的文本');
    return content;
  }

  read({ path, offset = 1, limit = 200 }: z.infer<typeof readFileArgs>) {
    const target = this.resolve(path);
    const content = this.text(target);
    const lines = content.split('\n');
    const end = Math.min(offset - 1 + limit, lines.length);
    return { path: relative(this.root, target), text: lines.slice(offset - 1, end).join('\n'), offset,
      totalLines: lines.length, nextOffset: end < lines.length ? end + 1 : null,
      version: createHash('sha256').update(content).digest('hex') };
  }

  list(path = '.', offset = 0, limit = 200) {
    const target = this.resolve(path);
    const entries = readdirSync(target, { withFileTypes: true }).map((entry) => ({
      name: entry.name, path: relative(this.root, resolve(target, entry.name)),
      kind: entry.isDirectory() ? 'directory' as const : entry.isFile() ? 'file' as const : entry.isSymbolicLink() ? 'symlink' as const : 'other' as const,
    })).sort((a, b) => Number(b.kind === 'directory') - Number(a.kind === 'directory') || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return { path: relative(this.root, target) || '.', entries: entries.slice(offset, offset + limit), total: entries.length,
      nextOffset: offset + limit < entries.length ? offset + limit : null };
  }
}
