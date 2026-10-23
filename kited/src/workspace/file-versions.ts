/**
 * 文件的历史版本：取自工作区快照链（snapshots.ts），这个文件内容变过的每一枚快照是一个版本。
 * 浏览按版本看当时的内容，只读；按版本读文本（files.read）和字节（files/content）的边界、上限同读现在的文件。
 */
import { relative } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { rangedResponse } from '../byte-range.ts';
import { snapshotCommit, TEXT_LIMIT, textContent, textPage, type WorkspaceFiles } from './files.ts';
import { gitHead, gitTry } from './git.ts';
import { chainBase, parseSnapshot, type Snapshot, snapshotFormat, snapshotRef } from './snapshots.ts';

export const fileVersionSchema = z.object({ commit: snapshotCommit, at: z.number(), label: z.string(), threadId: z.string().min(1).optional() }).strict();
export type FileVersion = z.infer<typeof fileVersionSchema>;

const MAX_VERSIONS = 100;

// 记录以 \x1e 开头、快照字段以 \x1d 收尾，带 --raw 时后面是状态行
const recordFormat = `%x1e${snapshotFormat}%x1d`;

/** 时间线里的一版：快照去掉工具调用。 */
const fileVersion = ({ toolUseIds: _, ...version }: Snapshot): FileVersion => version;

/** 一条记录的快照与这个文件在里面的 blob，见 recordFormat。 */
function parseRecord(record: string) {
  const [head = '', changes = ''] = record.split('\x1d');
  // :旧模式 新模式 旧 blob 新 blob 状态；删掉了新模式是 000000，只认普通文件
  const raw = changes.match(/^:\d+ (\d+) [0-9a-f]+ ([0-9a-f]+) [A-Z]/m);
  return { snapshot: parseSnapshot(head)?.snapshot, blob: raw && raw[1]!.startsWith('100') ? raw[2] : undefined };
}

/**
 * 文件的历史版本，新的在前，最多 100 个：快照链上按路径过滤，只走本工作区的快照（链外的第一条见 snapshots.ts 的 chainBase），
 * 那一枚里文件被删掉或不是普通文件的不列。工作区开始前就在项目里的文件，第一枚快照没改它时路径过滤列不出来，
 * 补上第一枚快照作为最早的一版，改之前的样子才看得到。current 是内容和工作区里现在的文件相同的那一版（只比最新一版），不同或文件不在时为 null。
 * 先找链外的第一条，再同时做：一次 log 带 --raw 拿到每一版的状态和 blob，取第一枚快照，看开始时项目里有没有这个文件，算现在文件的 blob。
 */
export async function fileHistory(files: WorkspaceFiles, workspaceId: string, path: string) {
  const rel = relative(files.root, files.resolve(path));
  const base = await chainBase(files.root, workspaceId);
  if (base === undefined) return { versions: [], current: null, truncated: false };
  const range = [snapshotRef(workspaceId), ...(base ? [`^${base}`] : [])];
  const [log, first, start, now] = await Promise.all([
    // 链到根时第一枚快照是根提交，--root 让它照样带上状态行、作为一版列出
    gitTry(files.root, ['log', '--first-parent', '--diff-merges=first-parent', '--no-renames', '--root', '--raw', '--no-abbrev',
      `-n${MAX_VERSIONS + 1}`, `--format=${recordFormat}`, ...range, '--', `:(literal)${rel}`]),
    // 倒过来第一枚排在最前，读到开头就停
    base ? gitHead(files.root, ['log', '--first-parent', '--reverse', `--format=${snapshotFormat}%x1e`, ...range], 16 * 1024).catch(() => '') : '',
    base ? treeEntry(files.root, base, rel) : undefined,
    gitTry(files.root, ['hash-object', '--', rel]),
  ]);
  const records = log.code === 0 ? log.stdout.split('\x1e').filter((record) => record.trim()).map(parseRecord) : [];
  const found = records.flatMap(({ snapshot, blob }) => (snapshot && blob ? [{ version: fileVersion(snapshot), blob }] : []));
  const firstSnapshot = parseSnapshot(first.split('\x1e')[0]!)?.snapshot;
  // 第一枚快照没改这个文件（不在记录里）时，它的内容就是开始时项目里的；记录取满时不知道，不补
  if (firstSnapshot && start?.regular && records.length <= MAX_VERSIONS && records.at(-1)?.snapshot?.commit !== firstSnapshot.commit) {
    found.push({ version: fileVersion(firstSnapshot), blob: start.blob });
  }
  const latest = found[0];
  const current = latest && now.code === 0 && now.stdout.trim() === latest.blob ? latest.version.commit : null;
  // 记录取满了，更早的可能还有
  return { versions: found.slice(0, MAX_VERSIONS).map(({ version }) => version), current,
    truncated: records.length > MAX_VERSIONS || found.length > MAX_VERSIONS };
}

/** 一个提交里这个路径的条目，不在时为 undefined；regular 表示是普通文件。 */
async function treeEntry(cwd: string, commit: string, rel: string) {
  const tree = await gitTry(cwd, ['ls-tree', '-l', commit, '--', rel]);
  // <模式> <类型> <对象> <大小>\t<路径>
  const entry = tree.stdout.split('\n').find((line) => line.endsWith(`\t${rel}`))?.match(/^(\d+) (\w+) ([0-9a-f]+) +(\d+|-)\t/);
  return entry ? { regular: entry[1]!.startsWith('100') && entry[2] === 'blob', blob: entry[3]!, size: Number(entry[4]) } : undefined;
}

/** 一枚快照里的这个文件：快照须属于本工作区，文件在里面须是普通文件。at 是快照的毫秒时间。 */
async function versionFile(files: WorkspaceFiles, workspaceId: string, path: string, version: string) {
  const rel = relative(files.root, files.resolve(path));
  if (!snapshotCommit.safeParse(version).success) throw new KiteError('找不到这个工作区的快照', 404);
  const [log, entry] = await Promise.all([
    gitTry(files.root, ['log', '-1', `--format=${snapshotFormat}`, version, '--']),
    treeEntry(files.root, version, rel),
  ]);
  const parsed = log.code === 0 ? parseSnapshot(log.stdout) : undefined;
  if (parsed?.owner !== workspaceId) throw new KiteError('找不到这个工作区的快照', 404);
  if (!entry) throw new KiteError('这个版本里没有这个文件', 404);
  if (!entry.regular) throw new KiteError('这个版本里它不是普通文件', 409);
  return { path: rel, blob: entry.blob, size: entry.size, at: parsed.snapshot.at };
}

/** 确认快照里有这个文件，选版本时用；不在时抛错。 */
export async function assertVersion(files: WorkspaceFiles, workspaceId: string, path: string, version: string): Promise<void> {
  await versionFile(files, workspaceId, path, version);
}

async function blobBytes(cwd: string, blob: string): Promise<Uint8Array<ArrayBuffer>> {
  const p = Bun.spawn(['git', 'cat-file', 'blob', blob], { cwd, env: { ...process.env }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
  const [bytes, stderr, code] = await Promise.all([new Response(p.stdout).bytes(), new Response(p.stderr).text(), p.exited]);
  if (code !== 0) throw new KiteError(`读取历史版本失败：${stderr.trim()}`);
  return bytes;
}

/** 按行读一个版本的文本，输出同 WorkspaceFiles.read。 */
export async function readVersion(files: WorkspaceFiles, workspaceId: string,
  { path, version, offset = 1, limit = 200 }: { path: string; version: string; offset?: number; limit?: number }) {
  const file = await versionFile(files, workspaceId, path, version);
  const bytes = file.size > TEXT_LIMIT ? undefined : await blobBytes(files.root, file.blob);
  return textPage(file.path, textContent(file.size, () => new TextDecoder().decode(bytes)), offset, limit);
}

/**
 * 按字节读一个版本，同 fileContent：ETag 是 blob 的对象号，支持 HEAD、If-None-Match 和单段 Range；
 * blob 不会变，分段同附件的原件（rangedResponse）。版本本来就在快照里，不带 X-Kite-Snapshot。
 */
export async function versionContent(req: Request, files: WorkspaceFiles, workspaceId: string, path: string, version: string): Promise<Response> {
  const file = await versionFile(files, workspaceId, path, version);
  const etag = `"${file.blob}"`;
  const headers = new Headers({
    'Content-Type': Bun.file(file.path).type, ETag: etag, 'Last-Modified': new Date(file.at).toUTCString(),
    'Cache-Control': 'no-cache', 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff',
  });
  if (req.headers.get('If-None-Match')?.split(',').some((tag) => tag.trim() === etag)) return new Response(null, { status: 304, headers });
  if (req.method === 'HEAD') {
    headers.set('Content-Length', String(file.size));
    return new Response(null, { headers });
  }
  return rangedResponse(req, new Blob([await blobBytes(files.root, file.blob)]), headers);
}
