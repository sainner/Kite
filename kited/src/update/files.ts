/**
 * 一份可在工作机之间传的文件树：清单列出每个文件的相对路径、哈希、大小与可执行位，符号链接记目标。
 * 打包时为运行目录写 files.json；提供 Mac App 时现算；拉取方按清单复用本机相同的内容、校验收到的文件。
 */
import { lstatSync, readdirSync, readlinkSync } from 'node:fs';
import { join, posix, relative, sep } from 'node:path';
import { z } from 'zod';

export const fileEntry = z.union([
  z.object({ path: z.string(), sha256: z.string().regex(/^[0-9a-f]{64}$/), size: z.number().int().min(0), executable: z.boolean() }).strict(),
  z.object({ path: z.string(), link: z.string() }).strict(),
]);
export type FileEntry = z.infer<typeof fileEntry>;
export type RegularEntry = Extract<FileEntry, { sha256: string }>;

/** 运行目录里不进 files.json 的两个文件：它们描述清单本身。打包算构建号、拉取方核对构建号都把它们除外。 */
export const MANIFEST_FILES = ['manifest.json', 'files.json'];
export const unlisted = (path: string): boolean => MANIFEST_FILES.includes(path);

/** 清单里的路径只能是树内的相对路径，不能借 .. 或绝对路径读写树外的文件。 */
export function safePath(path: string): boolean {
  return !!path && !path.startsWith('/') && !path.split('/').some((part) => part === '' || part === '.' || part === '..');
}

/**
 * 对端给的清单里第一个不安全的条目：路径不在树内，符号链接指向树外，或路径经过清单里的符号链接
 * （组装时建目录、写文件会跟着链接写到树外）。都安全时为 undefined。
 */
export function unsafeEntry(files: FileEntry[]): string | undefined {
  const links = new Set(files.flatMap((entry) => 'link' in entry ? [entry.path] : []));
  return files.find((entry) => {
    if (!safePath(entry.path)) return true;
    const parts = entry.path.split('/');
    if (parts.some((_, i) => i > 0 && links.has(parts.slice(0, i).join('/')))) return true;
    if (!('link' in entry)) return false;
    const target = posix.normalize(posix.join(posix.dirname(entry.path), entry.link));
    return entry.link.startsWith('/') || target === '..' || target.startsWith('../');
  })?.path;
}

export async function hashFile(path: string): Promise<string> {
  const hasher = new Bun.CryptoHasher('sha256');
  for await (const chunk of Bun.file(path).stream()) hasher.update(chunk);
  return hasher.digest('hex');
}

/** 列出 root 下的文件与符号链接，按路径排序；skip 对相对路径返回 true 的整个跳过（目录连同其下）。 */
export async function listFiles(root: string, skip: (path: string) => boolean = () => false): Promise<FileEntry[]> {
  const entries: FileEntry[] = [];
  const walk = async (dir: string) => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      const path = relative(root, full).split(sep).join('/');
      if (skip(path)) continue;
      const stat = lstatSync(full);
      if (stat.isSymbolicLink()) entries.push({ path, link: readlinkSync(full) });
      else if (stat.isDirectory()) await walk(full);
      else if (stat.isFile()) entries.push({ path, sha256: await hashFile(full), size: stat.size, executable: (stat.mode & 0o111) !== 0 });
    }
  };
  await walk(root);
  return entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

/** 构建号：按清单内容算，同一份运行文件总是同一个；与 JSON 里字段的先后无关。 */
export function buildOf(files: FileEntry[]): string {
  const canonical = files.map((entry) => 'link' in entry ? [entry.path, entry.link] : [entry.path, entry.sha256, entry.size, entry.executable]);
  return new Bun.CryptoHasher('sha256').update(JSON.stringify(canonical)).digest('hex').slice(0, 16);
}
