/**
 * 经 HTTP 驱动本进程里的 kited，只走不起 Claude Code 的路径：D10。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startCli } from '../cli.ts';
import { createWorkspace, machine, type Kited, registerCheckout, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { commitAll, newRepo } from '../util.ts';

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; });

/** 带 .kite/setup 的已有仓库；script 是脚本正文（不含 #!）。 */
function repoWithSetup(parent: string, name: string, script: string): string {
  const dir = newRepo(parent, name, { '.kite/setup': `#!/bin/sh\n${script}`, 'a.txt': 'a\n' });
  chmodSync(join(dir, '.kite/setup'), 0o755);
  commitAll(dir, '可执行');
  return dir;
}

/* 依赖 Bun 的流式响应与工作区准备时序；别的工作区先结束后，本订阅只收到自己的变化。 */
test('工作区 SSE 在连接开着时推送本工作区准备结果，不串入其他工作区', async () => {
  k = startKited();
  const kk = k;
  // 两个工作区的 setup 都等着各自的放行文件（工作树旁边的 <工作树>.go），放行后失败退出；不起 Claude Code
  const repo = repoWithSetup(kk.root, 'proj', 'i=0; while [ ! -e "$(pwd -P).go" ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done\nexit 1\n');
  const p = await registerCheckout(kk, repo);
  const a = await createWorkspace(kk, p.checkout.id, '会话 A');
  const b = await createWorkspace(kk, p.checkout.id, '会话 B');

  const ctl = new AbortController();
  const machineId = (await machine(kk.url)).id;
  // SSE 一旦建立就会持续占用连接；机器不匹配必须在订阅前拒绝。
  expect((await fetch(`${kk.url}/events?workspace=${a.workspace.id}`)).status).toBe(400);
  expect((await fetch(`${kk.url}/events?workspace=${a.workspace.id}`, {
    headers: { 'X-Kite-Machine': 'wrong-machine' },
  })).status).toBe(409);
  const res = await fetch(`${kk.url}/events?workspace=${a.workspace.id}`, {
    headers: { 'X-Kite-Machine': machineId }, signal: ctl.signal,
  });
  const got: Array<{ type: string; workspaceId?: string; status?: string; model?: unknown }> = [];
  let sawEnd!: () => void;
  const ended = new Promise<void>((r) => (sawEnd = r));
  const reading = (async () => {
    const r = res.body!.pipeThrough(new TextDecoderStream()).getReader();
    let buf = '';
    try {
      while (true) {
        const { value, done } = await r.read();
        if (done) return;
        buf += value;
        let i: number;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          const data = buf.slice(0, i).split('\n').find((l) => l.startsWith('data: '));
          buf = buf.slice(i + 2);
          if (!data) continue;
          const e = JSON.parse(data.slice(6)) as typeof got[number];
          got.push(e);
          if (e.type === 'workspace.changed' && e.status === 'failed') sawEnd();
        }
      }
    } catch { /* 中止 */ }
  })();

  // 先让 B 跑完，再让 A 跑完：A 的最后一个事件到达时，B 的事件如果会漏进来也早就到了
  writeFileSync(`${b.workspace.cwd}.go`, '');
  await kk.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === b.workspace.id && e.status === 'failed');
  writeFileSync(`${a.workspace.cwd}.go`, '');
  await ended;
  ctl.abort();
  await reading;

  expect(got[0]).toMatchObject({ type: 'workspace.model', workspaceId: a.workspace.id });
  expect(got.some((e) => e.type === 'workspace.setup')).toBe(true);
  expect(got.every((e) => e.workspaceId === a.workspace.id)).toBe(true);
  expect(got.every((e) => !['thread.record', 'thread.pending', 'thread.state', 'thread.idle', 'thread.check', 'thread.error'].includes(e.type))).toBe(true);
});

// CLI 子进程、HTTP 创建/发送、模型完成和 SSE 历史交接；快速结束时仍应跟到本回合结果。
test('CLI new 处理已完成历史，send 等待本回合输出', async () => {
  const model = new ManualModel();
  k = startKited(() => model);
  const kk = k;
  const repo = newRepo(kk.root, 'cli', { 'base.txt': '原始\n' });
  const checkout = await registerCheckout(kk, repo);
  const opening = startCli(kk.url, 'new', checkout.checkout.id, '首回合');
  let sending: ReturnType<typeof startCli> | undefined;
  try {
    const first = await model.call(1);
    first.response.complete();
    const opened = await opening.finished();
    expect(opened).toMatchObject({ code: 0, stderr: '' });
    const listed = await kk.call('GET', '/workspaces');
    const workspace = listed.body.find((entry: any) => entry.workspace.kind === 'worktree');
    const threadId = workspace.threads[0].instanceId as string;
    const firstHistory = await kk.call('GET', `/threads/${threadId}/history`);
    expect(firstHistory.body.state.busy).toBe(false);

    sending = startCli(kk.url, 'send', threadId, '第二回合');
    const second = await model.call(2);
    await second.response.emit({ type: 'item', item: {
      id: 'cli-second-result', raw: { type: 'message', content: [{ type: 'output_text', text: 'CLI 第二回合结果' }] },
    } });
    await sending.waitText('CLI 第二回合结果');
    second.response.complete();
    const sent = await sending.finished();
    expect(sent).toMatchObject({ code: 0, stderr: '' });
    const history = await kk.call('GET', `/threads/${threadId}/history`);
    expect(history.body.records).toContainEqual(expect.objectContaining({
      block: expect.objectContaining({ type: 'human', text: '第二回合' }),
    }));
  } finally {
    await Promise.all([opening.stop(), sending?.stop()]);
  }
}, 1000);
