/**
 * 附件分段上传（src/http.ts 的 /workspaces/:id/attachments/:attachment/parts，src/workspace/attachments.ts）：
 * 组网上 App 把大附件按段（SEGMENT_BYTES）同时传，卡住的段换个请求重传，传完核对整份大小与 SHA-256 后照整份上传收下。
 */
import { afterEach, expect, test } from 'bun:test';
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { SEGMENT_BYTES } from '../../src/peer-fetch.ts';
import { attachmentPath } from '../../src/workspace/attachments.ts';
import { folderWorkspace, getAttachment, type Kited, startKited } from '../harness.ts';
import { newDir } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

/** PUT 一段到附件拼接文件的 offset 处，size 是整份大小；返回状态码。 */
async function putPart(k: Kited, workspaceId: string, id: string, size: number, offset: number, bytes: Uint8Array<ArrayBuffer>): Promise<number> {
  const r = await fetch(`${k.url}/workspaces/${workspaceId}/attachments/${id}/parts/${offset}?size=${size}`, {
    method: 'PUT', headers: { 'X-Kite-Machine': k.daemon.kite.store.machine.id }, body: bytes,
  });
  await r.arrayBuffer();
  return r.status;
}

/*
 * 几个请求同时按位置写同一个拼接文件：各自打开时不能截断别人写好的，请求体分块到达、各写各的位置，同一段后到的覆盖先到的，
 * 这要靠运行时与文件系统合起来的表现；核对通过后要接上整份上传那条路收下（存进附件存储、工作区里放一份）。
 * 少写中间一段时末段已经写到了文件末尾，拼接文件的大小是够的，只有内容核对拦得住；失败后拼接文件删掉，补齐全部分段重来要能收下。
 */
test('分段乱序同时写、其中一段先写半段别的内容再整段重写，收下后原件与工作区里那份都与原文件逐字节相同；少写中间一段时收下回 409，重新写齐各段后能收下', async () => {
  const k = kited = startKited();
  const { workspace } = await folderWorkspace(k, newDir(k.root, 'project', { 'base.txt': '原始\n' }));
  const content = randomBytes(2.5 * SEGMENT_BYTES + 5);
  const sha256 = createHash('sha256').update(content).digest('hex');
  const segment = (index: number) => content.subarray(index * SEGMENT_BYTES, (index + 1) * SEGMENT_BYTES);
  const put = (id: string, index: number, bytes: Uint8Array<ArrayBuffer> = segment(index)) =>
    putPart(k, workspace.id, id, content.length, index * SEGMENT_BYTES, bytes);
  const name = '数据 包.bin';
  const finish = (id: string) =>
    k.call('POST', `/workspaces/${workspace.id}/attachments/${id}/parts?name=${encodeURIComponent(name)}`, { size: content.length, sha256 });

  // 末段（不满一段）、第二段、第一段同时开始；第二段先写半段随机内容，写完再整段重写，与另两段交叠。
  const id = crypto.randomUUID();
  const written = await Promise.all([
    put(id, 2),
    (async () => [await put(id, 1, randomBytes(SEGMENT_BYTES / 2)), await put(id, 1)])(),
    put(id, 0),
  ]);
  expect(written.flat()).toEqual([200, 200, 200, 200]);
  const saved = await finish(id);
  expect(saved).toMatchObject({ status: 200, body: { id, name, size: content.length } });
  const original = await getAttachment(k, workspace.id, id);
  expect(original.status).toBe(200);
  expect(original.bytes.equals(content)).toBe(true);
  expect(readFileSync(join(workspace.cwd, attachmentPath(saved.body))).equals(content)).toBe(true);

  const other = crypto.randomUUID();
  expect(await Promise.all([put(other, 2), put(other, 0)])).toEqual([200, 200]);
  expect((await finish(other)).status).toBe(409);
  expect((await getAttachment(k, workspace.id, other)).status).toBe(404);
  expect(await Promise.all([put(other, 1), put(other, 2), put(other, 0)])).toEqual([200, 200, 200]);
  expect(await finish(other)).toMatchObject({ status: 200, body: { id: other, name, size: content.length } });
  expect((await getAttachment(k, workspace.id, other)).bytes.equals(content)).toBe(true);
}, 1000);
