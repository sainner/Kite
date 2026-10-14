/**
 * 经 HTTP 和 CLI 驱动本进程里的 kited，不启动 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, rmSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import type { WorkspaceModel } from '../../src/model.ts';
import { startCli } from '../cli.ts';
import { after, createWorkspace, machine, type Kited, mark, registerCheckout, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { connectSse } from '../sse.ts';
import { commitAll, git, newRepo, read } from '../util.ts';

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
  // 两个工作区的 setup 都等着各自的放行文件（检出目录里的 <工作树目录名>.go），放行后失败退出；不起 Claude Code。
  // setup 在沙箱里跑，检出目录可读、工作树之外的其他路径读不到，放行文件只能放在检出或工作树里。
  const repo = repoWithSetup(kk.root, 'proj', 'i=0; while [ ! -e "$KITE_MAIN_DIR/$(basename "$(pwd -P)").go" ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done\nexit 1\n');
  const release = (cwd: string) => writeFileSync(join(repo, `${basename(cwd)}.go`), '');
  const p = await registerCheckout(kk, repo);
  const a = await createWorkspace(kk, p.checkout.id, '会话 A');
  const b = await createWorkspace(kk, p.checkout.id, '会话 B');
  expect(basename(a.workspace.cwd)).not.toBe(basename(b.workspace.cwd));

  const machineId = (await machine(kk.url)).id;
  // SSE 一旦建立就会持续占用连接；机器不匹配必须在订阅前拒绝。
  expect((await fetch(`${kk.url}/events?workspace=${a.workspace.id}`)).status).toBe(400);
  expect((await fetch(`${kk.url}/events?workspace=${a.workspace.id}`, {
    headers: { 'X-Kite-Machine': 'wrong-machine' },
  })).status).toBe(409);
  const stream = await connectSse<{ type: string; workspaceId?: string; status?: string }>(
    `${kk.url}/events?workspace=${a.workspace.id}`, machineId,
  );
  try {
    // 先让 B 跑完，再让 A 跑完：A 的最后一个事件到达时，B 的事件如果会漏进来也早就到了。
    release(b.workspace.cwd);
    await kk.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === b.workspace.id && e.status === 'failed');
    release(a.workspace.cwd);
    await stream.events.wait((e) => e.type === 'workspace.changed' && e.status === 'failed');

    expect(stream.events.values[0]).toMatchObject({ type: 'workspace.model', workspaceId: a.workspace.id });
    expect(stream.events.values.some((e) => e.type === 'workspace.setup')).toBe(true);
    expect(stream.events.values.every((e) => e.workspaceId === a.workspace.id)).toBe(true);
  } finally {
    await stream.close();
  }
});

/*
 * 几个部分的配合：准备流程、git worktree 的登记与分支、重跑入口。工作树还在时重跑只跑 setup，不能再去建一次已存在的工作树；
 * 工作树目录没了而 git 仍登记着它和它的分支时，重跑要重建工作树再跑 setup。两种都要从 failed 转为 open。
 */
test('准备失败的工作区修好条件后重跑转为 open，工作树目录丢了的重跑先重建工作树再转为 open', async () => {
  k = startKited();
  const kk = k;
  const repo = repoWithSetup(kk.root, 'proj', '[ -e "$KITE_MAIN_DIR/ready" ] || exit 3\n');
  const p = await registerCheckout(kk, repo);
  const create = async () => {
    const created = await kk.call('POST', '/workspaces', { checkout: p.checkout.id });
    expect(created.status).toBe(200);
    return created.body as WorkspaceModel;
  };
  const [kept, lost] = await Promise.all([create(), create()]);
  const status = (w: WorkspaceModel, value: string, since = 0) => kk.waitEvent((e) => e.type === 'workspace.changed'
    && e.workspaceId === w.workspace.id && e.status === value && after(kk, since)(e));
  await Promise.all([status(kept, 'failed'), status(lost, 'failed')]);
  expect(kk.events.find((e) => e.type === 'workspace.setup' && e.workspaceId === kept.workspace.id)).toMatchObject({ exit: 3 });

  rmSync(lost.workspace.cwd, { recursive: true, force: true });
  writeFileSync(join(repo, 'ready'), '');
  const since = mark(kk);
  const retried = await Promise.all([kept, lost].map((w) => kk.call('POST', `/workspaces/${w.workspace.id}/setup`)));
  expect(retried.map((r) => r.status)).toEqual([200, 200]);
  await Promise.all([status(kept, 'open', since), status(lost, 'open', since)]);
  expect(read(join(lost.workspace.cwd, 'a.txt'))).toBe('a\n');
  expect(git(lost.workspace.cwd, 'branch', '--show-current')).toBe(lost.workspace.branch!);
  expect(git(kept.workspace.cwd, 'branch', '--show-current')).toBe(kept.workspace.branch!);
}, 1000);

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
