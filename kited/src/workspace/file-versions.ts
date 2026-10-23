/**
 * 文件的历史版本：取自工作区快照链（snapshots.ts），这个文件内容变过的每一枚快照是一个版本。
 * 浏览按版本看当时的内容，只读；按版本读文本（files.read）和字节（files/content）的边界、上限同读现在的文件。
 */
import { relative } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { byteRange } from '../byte-range.ts';
import { snapshotCommit, textContent, textPage, type WorkspaceFiles } from './files.ts';
import { gitTry } from './git.ts';
import { snapshotRef } from './snapshots.ts';

export const fileVersionSchema = z.object({ commit: snapshotCommit, at: z.number(), label: z.string(), threadId: z.string().min(1).optional() }).strict();
export type FileVersion = z.infer<typeof fileVersionSchema>;

const MAX_VERSIONS = 100;

const trailer = (key: string) => `%(trailers:key=${key},valueonly,separator=%x2C)`;
// 记录以 \x1e 开头、头部以 \x1d 收尾，带 --raw 时后面是状态行；尾注都带 separator，不会多出换行
const recordFormat = `%x1e%H%x1f%ct%x1f%s%x1f${trailer('Kite-Workspace')}%x1f${trailer('Kite-At')}%x1f${trailer('Kite-Thread')}%x1d`;

/** 一条记录的提交、所属工作区与版本信息，见 recordFormat。 */
function parseRecord(record: string) {
  const [head = '', changes = ''] = record.split('\x1d');
  const [commit, seconds, label, owner, ms, thread] = head.split('\x1f');
  const version: FileVersion | undefined = commit ? { commit, at: Number(ms?.trim()) || Number(seconds) * 1000, label: label ?? '',
    ...(thread?.trim() ? { threadId: thread.trim() } : {}) } : undefined;
  // :旧模式 新模式 旧 blob 新 blob 状态；删掉了新模式是 000000，只认普通文件
  const raw = changes.match(/^:\d+ (\d+) [0-9a-f]+ ([0-9a-f]+) [A-Z]/m);
  return { version, owner: owner?.trim(), blob: raw && raw[1]!.startsWith('100') ? raw[2] : undefined };
}

/**
 * 文件的历史版本，新的在前，最多 100 个：沿快照链的第一父节点按路径过滤，遇到不属于本工作区的提交就停（同 snapshots.ts 的 list）；
 * 那一枚里文件被删掉或不是普通文件的不列。工作区开始前就在项目里的文件，第一枚快照和项目当时的 HEAD 一样、路径过滤列不出来，
 * 补上第一枚快照作为最早的一版，改之前的样子才看得到。current 是内容和工作区里现在的文件相同的那一版（只比最新一版），不同或文件不在时为 null。
 * 一次 log 带 --raw 拿到每一版的状态和 blob，和算现在文件的 blob 同时做；要补最早一版时再查一次第一枚快照。
 */
export async function fileHistory(files: WorkspaceFiles, workspaceId: string, path: string) {
  const rel = relative(files.root, files.resolve(path));
  const [log, now] = await Promise.all([
    gitTry(files.root, ['log', '--first-parent', '--diff-merges=first-parent', '--no-renames', '--raw', '--no-abbrev', `-n${MAX_VERSIONS + 1}`,
      `--format=${recordFormat}`, snapshotRef(workspaceId), '--', `:(literal)${rel}`]),
    gitTry(files.root, ['hash-object', '--', rel]),
  ]);
  const versions: FileVersion[] = [];
  const blobs: string[] = [];
  let truncated = false;
  /** 链外第一条，即项目历史里最近一次改这个文件的提交：文件那之后还在时，它就是工作区开始时的内容。 */
  let before: { commit: string; blob: string } | undefined;
  // 还没有快照时引用不存在，log 失败
  if (log.code === 0) {
    const records = log.stdout.split('\x1e').filter((record) => record.trim());
    let ended = false;
    for (const record of records) {
      const { version, owner, blob } = parseRecord(record);
      if (!version || owner !== workspaceId) {
        ended = true;
        if (version && blob) before = { commit: version.commit, blob };
        break;
      }
      if (!blob) continue;
      if (versions.length === MAX_VERSIONS) { truncated = true; break; }
      versions.push(version);
      blobs.push(blob);
    }
    // 取满了还没走到链外，后面可能还有
    if (!truncated && !ended && records.length > MAX_VERSIONS) truncated = true;
  }
  if (before && !truncated) {
    const first = await firstSnapshot(files.root, workspaceId, before.commit);
    // 第一枚快照自己就改过这个文件（开始时有没提交的改动）时已经列着了
    if (first && first.commit !== versions.at(-1)?.commit) {
      if (versions.length === MAX_VERSIONS) truncated = true;
      else {
        versions.push(first);
        blobs.push(before.blob);
      }
    }
  }
  const current = blobs[0] && now.code === 0 && now.stdout.trim() === blobs[0] ? versions[0]!.commit : null;
  return { versions, current, truncated };
}

/** 快照链上紧接在链外提交 before 之后的那一枚，即本工作区的第一枚快照。 */
async function firstSnapshot(cwd: string, workspaceId: string, before: string): Promise<FileVersion | undefined> {
  const r = await gitTry(cwd, ['log', '--first-parent', `--format=${recordFormat}`, `${before}..${snapshotRef(workspaceId)}`]);
  if (r.code !== 0) return undefined;
  const last = r.stdout.split('\x1e').filter((record) => record.trim()).at(-1);
  const parsed = last ? parseRecord(last) : undefined;
  return parsed?.owner === workspaceId ? parsed.version : undefined;
}

/** 一枚快照里的这个文件：快照须属于本工作区，文件在里面须是普通文件。at 是快照的毫秒时间。 */
async function versionFile(files: WorkspaceFiles, workspaceId: string, path: string, version: string) {
  const rel = relative(files.root, files.resolve(path));
  if (!snapshotCommit.safeParse(version).success) throw new KiteError('找不到这个工作区的快照', 404);
  const format = '%ct%x1f%(trailers:key=Kite-Workspace,valueonly,separator=%x2C)%x1f%(trailers:key=Kite-At,valueonly,separator=%x2C)';
  const [log, tree] = await Promise.all([
    gitTry(files.root, ['log', '-1', `--format=${format}`, version, '--']),
    gitTry(files.root, ['ls-tree', '-l', version, '--', rel]),
  ]);
  const [seconds, owner, ms] = log.stdout.trim().split('\x1f');
  if (log.code !== 0 || owner?.trim() !== workspaceId) throw new KiteError('找不到这个工作区的快照', 404);
  // <模式> <类型> <对象> <大小>\t<路径>
  const entry = tree.stdout.split('\n').find((line) => line.endsWith(`\t${rel}`))?.match(/^(\d+) (\w+) ([0-9a-f]+) +(\d+|-)\t/);
  if (!entry) throw new KiteError('这个版本里没有这个文件', 404);
  if (!entry[1]!.startsWith('100') || entry[2] !== 'blob') throw new KiteError('这个版本里它不是普通文件', 409);
  return { path: rel, blob: entry[3]!, size: Number(entry[4]), at: Number(ms?.trim()) || Number(seconds) * 1000 };
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
  const bytes = file.size > 2 * 1024 * 1024 ? undefined : await blobBytes(files.root, file.blob);
  return textPage(file.path, textContent(file.size, () => new TextDecoder().decode(bytes)), offset, limit);
}

/** 按字节读一个版本，同 fileContent：ETag 是 blob 的对象号，支持 HEAD、If-None-Match 和单段 Range；版本本来就在快照里，不带 X-Kite-Snapshot。 */
export async function versionContent(req: Request, files: WorkspaceFiles, workspaceId: string, path: string, version: string): Promise<Response> {
  const file = await versionFile(files, workspaceId, path, version);
  const etag = `"${file.blob}"`;
  const headers = new Headers({
    'Content-Type': Bun.file(file.path).type, ETag: etag, 'Last-Modified': new Date(file.at).toUTCString(),
    'Cache-Control': 'no-cache', 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff',
  });
  const head = req.method === 'HEAD';
  if (req.headers.get('If-None-Match')?.split(',').some((tag) => tag.trim() === etag)) return new Response(null, { status: 304, headers });
  const ifRange = req.headers.get('If-Range');
  const range = ifRange === null || ifRange === etag ? byteRange(req.headers.get('Range'), file.size) : null;
  if (range === 'unsatisfiable') {
    return Response.json({ error: '请求的范围超出文件大小' }, { status: 416, headers: { 'Content-Range': `bytes */${file.size}` } });
  }
  if (range) {
    const [start, end] = range;
    headers.set('Content-Range', `bytes ${start}-${end}/${file.size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(head ? null : (await blobBytes(files.root, file.blob)).subarray(start, end + 1), { status: 206, headers });
  }
  headers.set('Content-Length', String(file.size));
  return new Response(head ? null : await blobBytes(files.root, file.blob), { headers });
}
