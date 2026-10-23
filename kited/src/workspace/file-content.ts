/**
 * 按字节读取工作区文件，给查看器下载图片、PDF、音视频这类成果。ETag 是文件版本，设备按它缓存和重新校验；
 * 只支持单段 Range，多段时整份返回。太大没进快照的文件在整份响应（含 HEAD）与从头开始的分段上带 X-Kite-Snapshot: skipped，
 * 查看器据此标明没有历史版本；组网上的 App 按段取，从第一段读到它。
 */
import { relative } from 'node:path';
import { byteRange } from '../byte-range.ts';
import { KiteError } from '../errors.ts';
import type { WorkspaceFiles } from './files.ts';
import { gitTry } from './git.ts';
import { SNAPSHOT_FILE_LIMIT } from './snapshots.ts';

export async function fileContent(req: Request, files: WorkspaceFiles, path: string): Promise<Response> {
  let file: ReturnType<WorkspaceFiles['regular']>;
  try { file = files.regular(path); }
  catch (error) {
    if (error instanceof KiteError) throw error;
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new KiteError('文件不存在', 404);
    throw new KiteError(`读取文件失败：${error instanceof Error ? error.message : String(error)}`);
  }
  const etag = `"${file.version}"`;
  const body = Bun.file(file.target);
  const headers = new Headers({
    'Content-Type': body.type, ETag: etag, 'Last-Modified': new Date(file.modified).toUTCString(),
    'Cache-Control': 'no-cache', 'Accept-Ranges': 'bytes', 'X-Content-Type-Options': 'nosniff',
  });
  const head = req.method === 'HEAD';
  if (req.headers.get('If-None-Match')?.split(',').some((tag) => tag.trim() === etag)) return new Response(null, { status: 304, headers });
  const ifRange = req.headers.get('If-Range');
  const range = ifRange === null || ifRange === etag ? byteRange(req.headers.get('Range'), file.size) : null;
  if (range === 'unsatisfiable') {
    return Response.json({ error: '请求的范围超出文件大小' }, { status: 416, headers: { 'Content-Range': `bytes */${file.size}` } });
  }
  if ((!range || range[0] === 0) && file.size > SNAPSHOT_FILE_LIMIT
    && (await gitTry(files.root, ['cat-file', '-e', `HEAD:${relative(files.root, file.target)}`])).code !== 0) headers.set('X-Kite-Snapshot', 'skipped');
  if (range) {
    const [start, end] = range;
    headers.set('Content-Range', `bytes ${start}-${end}/${file.size}`);
    headers.set('Content-Length', String(end - start + 1));
    return new Response(head ? null : body.slice(start, end + 1), { status: 206, headers });
  }
  headers.set('Content-Length', String(file.size));
  return new Response(head ? null : body, { headers });
}
