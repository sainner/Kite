import { expect, test } from 'bun:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startGateway } from './gateway.ts';

type Task = { id: string; title: string; done: boolean };
type State = { revision: number; tasks: Task[] };
type Reply = { status: number; body: any };

function state(reply: Reply): State {
  expect(reply.status).toBe(200);
  expect(reply.body.isError).not.toBe(true);
  const value = reply.body.structuredContent as State | undefined;
  if (!value || !Array.isArray(value.tasks)) throw new Error('MCP 工具未返回待办状态');
  return value;
}

function rejected(reply: Reply) {
  return reply.status >= 400 || reply.body.isError === true;
}

// Bun 网关、MCP SDK、Deno 插件和宿主持久层之间的授权、并发写入与重启交接需要真实进程验证。
test('待办插件经授权桥接并发写入，重启后保留状态且拒绝伪造身份和越界读取', async () => {
  const root = mkdtempSync(join(tmpdir(), 'kite-plugin-gateway-'));
  let gateway: Awaited<ReturnType<typeof startGateway>> | undefined;
  try {
    writeFileSync(join(root, 'outside.txt'), '仅用于实验的假秘密');
    gateway = await startGateway(root);
    const endpoint = (path: string) => new URL(path, `${gateway!.url.replace(/\/$/, '')}/`);
    const post = async (path: string, body: unknown, authorized = true): Promise<Reply> => {
      const response = await fetch(endpoint(path), {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          ...(authorized ? { authorization: `Bearer ${gateway!.token}` } : {}),
        },
        body: JSON.stringify(body),
      });
      return { status: response.status, body: await response.json() };
    };
    const call = (name: string, args: Record<string, unknown> = {}) =>
      post('bridge', { kind: 'call', name, arguments: args });

    expect((await post('bridge', { kind: 'call', name: 'todo_list', arguments: {} }, false)).status).toBe(403);
    expect((await post('bridge', { kind: 'call', name: 'todo_list', arguments: {}, workspaceId: 'forged' })).status).toBe(400);
    expect((await post('bridge', { kind: 'call', name: 'todo_list', arguments: {}, caller: { kind: 'system' } })).status).toBe(400);
    expect(rejected(await call('unknown_tool'))).toBe(true);

    const resource = await post('bridge', { kind: 'resource' });
    expect(resource.status).toBe(200);
    expect(resource.body.html).toEqual(expect.any(String));
    expect(resource.body.html.length).toBeGreaterThan(0);

    const initial = state(await call('todo_list'));
    expect(initial.tasks).toEqual([]);
    const added = state(await call('todo_add', { title: '第一项' }));
    const first = added.tasks.find((task) => task.title === '第一项');
    if (!first) throw new Error('新增的待办项未返回');
    const completed = state(await call('todo_complete', { id: first.id }));
    expect(completed.tasks.find((task) => task.id === first.id)?.done).toBe(true);

    const titles = ['并发甲', '并发乙'];
    const writes = await Promise.all(titles.map((title) => call('todo_add', { title })));
    expect(writes.some((reply) => !rejected(reply))).toBe(true);
    for (const [index, reply] of writes.entries()) {
      if (rejected(reply)) state(await call('todo_add', { title: titles[index] }));
      else state(reply);
    }
    const beforeRestart = state(await call('todo_list'));
    expect(beforeRestart.revision).toBe(initial.revision + 4);
    expect(beforeRestart.tasks).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: first.id, title: '第一项', done: true }),
      expect.objectContaining({ title: '并发甲', done: false }),
      expect.objectContaining({ title: '并发乙', done: false }),
    ]));
    expect(beforeRestart.tasks).toHaveLength(3);

    const workspaceRead = await call('todo_read_workspace', { path: 'sample.txt' });
    expect(workspaceRead.status).toBe(200);
    expect(workspaceRead.body.isError).not.toBe(true);
    expect((workspaceRead.body.content as Array<{ type: string; text?: string }>)
      .filter((part) => part.type === 'text').map((part) => part.text).join('\n'))
      .toContain('工作区授权读取成功\n');
    expect(rejected(await call('todo_read_workspace', { path: '../outside.txt' }))).toBe(true);

    const restarted = await post('restart', {});
    expect(restarted.status).toBe(200);
    expect(restarted.body.ok).toBe(true);
    expect(state(await call('todo_list'))).toEqual(beforeRestart);
    expect((await post('restart', {}, false)).status).toBe(403);
  } finally {
    try { await gateway?.close(); }
    finally { rmSync(root, { recursive: true, force: true }); }
  }
}, 5000);
