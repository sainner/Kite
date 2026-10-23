/**
 * 按字节范围交出内容：只支持单段 Range，多段或不是字节范围时整份。组网上的接收方按段取，一条连接卡住时换个请求重取那一段，
 * 见 peer-fetch.ts 的 peerDownload 与 App 的 KitedClient.download。
 */

/** 解析 bytes=a-b、bytes=a-、bytes=-n；不是单段字节范围时返回 null，按整份处理。 */
export function byteRange(value: string | null, size: number): [number, number] | 'unsatisfiable' | null {
  const match = value?.trim().match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (match[1] === '' && match[2] === '')) return null;
  let start: number, end: number;
  if (match[1] === '') {
    const suffix = Number(match[2]);
    if (suffix === 0) return 'unsatisfiable';
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] === '' ? size - 1 : Math.min(Number(match[2]), size - 1);
    if (match[2] !== '' && Number(match[2]) < start) return null;
  }
  return start >= size ? 'unsatisfiable' : [start, end];
}

/** 一份不会变的内容按请求的 Range 交出：给了单段范围回 206 与那一段，否则 200 整份；超出大小 416。 */
export function rangedResponse(req: Request, body: Blob, headers: Headers): Response {
  headers.set('Accept-Ranges', 'bytes');
  const range = byteRange(req.headers.get('Range'), body.size);
  if (range === 'unsatisfiable') {
    return Response.json({ error: '请求的范围超出大小' }, { status: 416, headers: { 'Content-Range': `bytes */${body.size}` } });
  }
  if (!range) {
    headers.set('Content-Length', String(body.size));
    return new Response(body, { headers });
  }
  const [start, end] = range;
  headers.set('Content-Range', `bytes ${start}-${end}/${body.size}`);
  headers.set('Content-Length', String(end - start + 1));
  return new Response(body.slice(start, end + 1), { status: 206, headers });
}
