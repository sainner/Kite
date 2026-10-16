/** 文件插件与 agent 共用工作目录边界和文本读取；不提供操作系统沙箱。 */
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, readdirSync, realpathSync, statSync } from 'node:fs';
import { relative, resolve } from 'node:path';
import { z } from 'zod';
import { within } from '../paths.ts';
import { KiteError } from '../errors.ts';
import { diffID } from './file-diffs.ts';
import { gitTry } from './git.ts';

export const readFileArgs = z.object({ path: z.string().min(1), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).optional() }).strict();
export const fileSelectionSchema = z.object({ path: z.string().nullable(), diffId: diffID.optional(), revision: z.string() }).strict();
export type FileSelection = z.infer<typeof fileSelectionSchema>;
export const fileSelection = (state: Record<string, unknown>): FileSelection => fileSelectionSchema.parse({ path: null, revision: 'initial', ...state });

/** 不是 Git 仓库时逐层找文件，最多看这么多个，免得大目录拖住服务。 */
const SEARCH_SCAN_LIMIT = 50_000;

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

  /** 普通文件与它的版本：大小、修改时间和 inode 都没变就当作同一版本，不读内容。 */
  regular(path: string) {
    const target = this.resolve(path);
    const stat = statSync(target, { bigint: true });
    if (!stat.isFile()) throw new KiteError('目标不是普通文件');
    return { target, size: Number(stat.size), modified: Number(stat.mtimeMs),
      version: [stat.size, stat.mtimeNs, stat.ino].map((n) => n.toString(36)).join('-') };
  }

  text(path: string): string {
    const { target, size } = this.regular(path);
    if (size > 2 * 1024 * 1024) throw new KiteError('文件超过 2 MiB，请用 shell 按范围读取', 413);
    const content = readFileSync(target, 'utf8');
    if (content.includes('\0')) throw new KiteError('文件不是可直接处理的文本', 415);
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
    const entries = readdirSync(target, { withFileTypes: true })
      .sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    const page = entries.slice(offset, offset + limit).map((entry) => ({
      name: entry.name, path: relative(this.root, resolve(target, entry.name)),
      kind: entry.isDirectory() ? 'directory' as const : entry.isFile() ? 'file' as const : entry.isSymbolicLink() ? 'symlink' as const : 'other' as const,
    }));
    return { path: relative(this.root, target) || '.', entries: page, total: entries.length,
      nextOffset: offset + limit < entries.length ? offset + limit : null };
  }

  /** 按名字找工作区里的文件和目录：不分大小写，跳过 .git 和 Git 忽略的路径。名字和关键字一样的排最前，其次是开头一样的，再按路径短的在前；最多 limit 条。 */
  async search(query: string, limit = 200) {
    const needle = query.trim().toLowerCase();
    const found = new Map<string, number>();
    const seen = new Set<string>();
    const consider = (path: string) => {
      const name = path.slice(path.lastIndexOf('/') + 1).toLowerCase();
      const rank = name === needle ? 0 : name.startsWith(needle) ? 1 : name.includes(needle) ? 2 : -1;
      if (rank >= 0) found.set(path, rank);
    };
    if (needle) {
      for (const file of await this.paths()) {
        consider(file);
        // 文件上面的各级目录也算，同一个目录只看一次
        for (let end = file.lastIndexOf('/'); end > 0; end = file.lastIndexOf('/', end - 1)) {
          const directory = file.slice(0, end);
          if (seen.has(directory)) break;
          seen.add(directory);
          consider(directory);
        }
      }
    }
    const ranked = [...found].sort(([a, x], [b, y]) => x - y || a.length - b.length || (a < b ? -1 : a > b ? 1 : 0)).map(([path]) => path);
    const entries = [];
    for (const path of ranked) {
      if (entries.length >= limit) break;
      let stat;
      // 已跟踪但工作区里删掉了的不列
      try { stat = lstatSync(resolve(this.root, path)); } catch { continue; }
      entries.push({ name: path.slice(path.lastIndexOf('/') + 1), path,
        kind: stat.isDirectory() ? 'directory' as const : stat.isFile() ? 'file' as const : stat.isSymbolicLink() ? 'symlink' as const : 'other' as const });
    }
    return { query, entries, truncated: entries.length < ranked.length };
  }

  /** 工作区里的文件，相对路径。Git 仓库里用 ls-files（含未跟踪的，不含忽略的）；不是仓库时逐层列出，跳过 .git。 */
  private async paths(): Promise<string[]> {
    const listed = await gitTry(this.root, ['ls-files', '-z', '--cached', '--others', '--exclude-standard']);
    if (listed.code === 0) return listed.stdout.split('\0').filter(Boolean);
    const files: string[] = [];
    const walk = (directory: string) => {
      let entries;
      try { entries = readdirSync(resolve(this.root, directory), { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        if (files.length >= SEARCH_SCAN_LIMIT) return;
        if (entry.name === '.git') continue;
        const path = directory ? `${directory}/${entry.name}` : entry.name;
        if (entry.isDirectory()) walk(path);
        else files.push(path);
      }
    };
    walk('');
    return files;
  }
}
