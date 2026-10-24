/** 文件插件与 agent 共用工作目录边界和文本读取；不提供操作系统沙箱。 */
import { createHash } from 'node:crypto';
import { type Dirent, lstatSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { z } from 'zod';
import { userHome, within } from '../paths.ts';
import { KiteError } from '../errors.ts';
import { diffID } from './file-diffs.ts';
import { gitTry } from './git.ts';
import { localHost } from '../execution/local-address.ts';

export const readFileArgs = z.object({ path: z.string().min(1), offset: z.number().int().min(1).optional(), limit: z.number().int().min(1).max(2000).optional() }).strict();
/** 浏览插件（docs/实例操作.md「浏览」）：看工作区的文件、本工作区运行中的网页和互联网；id 沿用文件插件的。 */
export const filesDefinitionId = 'kite.files';

export const portSchema = z.number().int().min(1).max(65535);
/** 本机地址只按端口看，网址里写本机（localhost、回环、链路本地）的不收，免得绕开「只开本工作区的端口」。 */
export const webAddressSchema = z.url({ protocol: /^https?$/ }).max(8192)
  .refine((url) => !localHost(new URL(url).hostname, false), '本机的网页按端口打开');
/** 浏览看的网页（docs/成果查看与位置.md「浏览」）：本工作区运行中终端或预览监听的端口，路径、前进后退只在各设备上；或互联网上的一个网址。 */
export const pageSchema = z.union([z.object({ port: portSchema }).strict(), z.object({ url: webAddressSchema }).strict()]);
export type Page = z.infer<typeof pageSchema>;
/** 一枚工作区快照的完整提交号，见 workspace/file-versions.ts。 */
export const snapshotCommit = z.string().regex(/^[0-9a-f]{40}(?:[0-9a-f]{24})?$/);
/** 浏览实例共用的选择：一个文件（可带历史差异，或是某枚快照里的版本），或一个网页（port、url 二选一），都没有时 path 为 null。 */
export const fileSelectionSchema = z.object({ path: z.string().nullable(), diffId: diffID.optional(), version: snapshotCommit.optional(),
  port: portSchema.optional(), url: z.string().optional(), revision: z.string() }).strict();
export type FileSelection = z.infer<typeof fileSelectionSchema>;
export const fileSelection = (state: Record<string, unknown>): FileSelection => fileSelectionSchema.parse({ path: null, revision: 'initial', ...state });

/** 不是 Git 仓库时逐层找文件，最多看这么多个，免得大目录拖住服务。 */
const SEARCH_SCAN_LIMIT = 50_000;

type EntryKind = 'directory' | 'file' | 'symlink' | 'other';
const kindOf = (entry: { isDirectory(): boolean; isFile(): boolean; isSymbolicLink(): boolean }): EntryKind =>
  entry.isDirectory() ? 'directory' : entry.isFile() ? 'file' : entry.isSymbolicLink() ? 'symlink' : 'other';

/** 列目录的一页：目录在前，再按名字排；只给切出来的这一页拼路径。 */
function page<T extends { name: string; kind: EntryKind }, R>(entries: T[], offset: number, limit: number, entry: (item: T) => R) {
  entries.sort((a, b) => Number(b.kind === 'directory') - Number(a.kind === 'directory') || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { entries: entries.slice(offset, offset + limit).map(entry), total: entries.length,
    nextOffset: offset + limit < entries.length ? offset + limit : null };
}

/** 当文本读写的上限。 */
export const TEXT_LIMIT = 2 * 1024 * 1024;

/** 当文本读的内容：超过 2 MiB 或含 NUL 的不读，查看器改按字节看。按版本读的同样处理，见 file-versions.ts。 */
export function textContent(size: number, read: () => string): string {
  if (size > TEXT_LIMIT) throw new KiteError('文件超过 2 MiB，请用 shell 按范围读取', 413);
  const content = read();
  if (content.includes('\0')) throw new KiteError('文件不是可直接处理的文本', 415);
  return content;
}

/** 文本内容的版本：完整内容的 sha256，读一页（textPage）和保存（WorkspaceFiles.write）用同一个。 */
export const textVersion = (content: string): string => createHash('sha256').update(content).digest('hex');

/** 文本的一页：从 offset 行起最多 limit 行；version 是完整内容的摘要。 */
export function textPage(path: string, content: string, offset = 1, limit = 200) {
  const lines = content.split('\n');
  const end = Math.min(offset - 1 + limit, lines.length);
  return { path, text: lines.slice(offset - 1, end).join('\n'), offset,
    totalLines: lines.length, nextOffset: end < lines.length ? end + 1 : null, version: textVersion(content) };
}

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
    return textContent(size, () => readFileSync(target, 'utf8'));
  }

  read({ path, offset = 1, limit = 200 }: z.infer<typeof readFileArgs>) {
    const target = this.resolve(path);
    return textPage(relative(this.root, target), this.text(target), offset, limit);
  }

  /**
   * 把一个已有的文本文件改成 text：只改普通文件、不新建，上限同读（2 MiB、不含 NUL），现在读不成文本的也不改。
   * 现在的字节不是合法 UTF-8 的（GBK、Latin-1 等）不改：读时坏字节换成了替换符，按 UTF-8 写回会改坏原有内容。
   * 文件已是这份内容时不写（重试幂等，written 为 false）；现在的内容和打开时（baseVersion）不同又没带 force 时拒绝，免得盖掉别人的改动。
   * 原地写入，保留权限与 inode。
   */
  write({ path, text, baseVersion, force = false }: { path: string; text: string; baseVersion: string; force?: boolean }) {
    if (Buffer.byteLength(text) > TEXT_LIMIT) throw new KiteError('内容超过 2 MiB，不能按文本保存', 413);
    if (text.includes('\0')) throw new KiteError('内容含 NUL，不能按文本保存', 415);
    const { target, size } = this.regular(path);
    const current = textVersion(textContent(size, () => {
      const bytes = readFileSync(target);
      // 保留开头的 BOM，与按文本读（readFileSync 的 utf8）得到的内容一致，version 才对得上。
      try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); }
      catch { throw new KiteError('文件不是 UTF-8 编码的文本，按文本保存会改坏原有内容', 415); }
    }));
    const version = textVersion(text);
    const saved = { path: relative(this.root, target), version };
    if (current === version) return { ...saved, written: false };
    if (current !== baseVersion && !force) throw new KiteError('文件在你打开以后被改过，保存会盖掉别人的改动', 409);
    writeFileSync(target, text);
    return { ...saved, written: true };
  }

  list(path = '.', offset = 0, limit = 200) {
    const target = this.resolve(path);
    const entries = readdirSync(target, { withFileTypes: true }).map((entry) => ({ name: entry.name, kind: kindOf(entry) }));
    return { path: relative(this.root, target) || '.',
      ...page(entries, offset, limit, ({ name, kind }) => ({ name, path: relative(this.root, resolve(target, name)), kind })) };
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
      entries.push({ name: path.slice(path.lastIndexOf('/') + 1), path, kind: kindOf(stat) });
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

/**
 * 这台工作机上的一个目录，添加项目时 App 用来选文件夹和环境变量文件：只列名字，不读内容。
 * 不给路径时列主目录，~/ 开头的按主目录解析；返回的形状同 WorkspaceFiles.list，路径都是绝对的，limit 最多 1000。
 * 符号链接按目标归类后再排序，指向目录的也排在前面。
 */
export async function hostDirectory(path: string | null, offset = 0, limit = 200) {
  const target = !path ? userHome() : path === '~' || path.startsWith('~/') ? join(userHome(), path.slice(1)) : path;
  if (!isAbsolute(target)) throw new KiteError('路径要写绝对路径，或 ~/ 开头');
  const directory = resolve(target);
  let dirents: Dirent[];
  // 目录可能很大，异步读，不挡住别的请求
  try { dirents = await readdir(directory, { withFileTypes: true }); }
  catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw new KiteError(`找不到文件夹：${directory}`, 404);
    if (code === 'ENOTDIR') throw new KiteError(`不是文件夹：${directory}`);
    if (code === 'EACCES' || code === 'EPERM') throw new KiteError(`没有权限读取：${directory}`, 403);
    throw error;
  }
  const entries = await Promise.all(dirents.map(async (entry) => ({ name: entry.name,
    kind: entry.isSymbolicLink() ? await stat(join(directory, entry.name)).then(kindOf, () => 'symlink' as const) : kindOf(entry) })));
  return { path: directory, ...page(entries, offset, Math.min(limit, 1000), ({ name, kind }) => ({ name, path: join(directory, name), kind })) };
}
