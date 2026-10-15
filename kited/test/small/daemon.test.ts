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
import { git, newDir, newRepo, read } from '../util.ts';

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; });

/** 带 .kite/setup 的已有仓库；script 是脚本正文（不含 #!）。先写好脚本并设成可执行再建仓库，一次提交带上可执行位。 */
function repoWithSetup(parent: string, name: string, script: string): string {
  chmodSync(join(newDir(parent, name, { '.kite/setup': `#!/bin/sh\n${script}` }), '.kite/setup'), 0o755);
  return newRepo(parent, name, { 'a.txt': 'a\n' });
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

/**
 * 建一个 setup 会失败的工作区，等它准备失败（setup 退出码 3），返回它和重跑的入口。
 * 每次 setup 都要起一个沙箱宿主进程，约 0.2 秒；一个测试只准备一个工作区、重跑一次，免得全量并行时挤过小测试的 1 秒。
 */
async function failedWorkspace(kk: Kited, script: string) {
  const repo = repoWithSetup(kk.root, 'proj', script);
  const p = await registerCheckout(kk, repo);
  const created = await kk.call('POST', '/workspaces', { checkout: p.checkout.id });
  expect(created.status).toBe(200);
  const w = created.body as WorkspaceModel;
  // since 之后这个工作区准备结束（转为 open 或 failed）时的状态和 setup 结果。
  const settled = async (since: number) => {
    const isAfter = after(kk, since);
    const end = await kk.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === w.workspace.id
      && (e.status === 'open' || e.status === 'failed') && isAfter(e));
    const setup = kk.events.find((e) => e.type === 'workspace.setup' && e.workspaceId === w.workspace.id && isAfter(e));
    return { status: end.type === 'workspace.changed' ? end.status : undefined, exit: setup?.type === 'workspace.setup' ? setup.exit : undefined };
  };
  expect(await settled(0)).toEqual({ status: 'failed', exit: 3 });
  // 重跑：接口受理后，这一轮的 setup 跑过且成功，工作区转为 open。
  const retry = async () => {
    const since = mark(kk);
    expect((await kk.call('POST', `/workspaces/${w.workspace.id}/setup`)).status).toBe(200);
    expect(await settled(since)).toEqual({ status: 'open', exit: 0 });
  };
  return { repo, workspace: w.workspace, retry };
}

/*
 * 几个部分的配合：准备流程、git worktree 的登记、重跑入口。工作树还在时重跑只跑 setup，不能再去建一次已存在的工作树，
 * 也不能删掉重建：条件是在工作树里修好的（未跟踪文件），工作树被重建就会丢掉它，setup 再失败一次。
 */
test('准备失败的工作区在工作树里修好条件后重跑，只重跑 setup，从 failed 转为 open', async () => {
  k = startKited();
  const { workspace, retry } = await failedWorkspace(k, '[ -e ready ] || exit 3\n');
  writeFileSync(join(workspace.cwd, 'ready'), '');
  await retry();
}, 1000);

/*
 * git worktree 的登记与分支：工作树目录没了而 git 仍登记着它和它的分支时，直接再 add 会失败，
 * 重跑要先重建工作树（检出原分支）再跑 setup，从 failed 转为 open。
 */
test('工作树目录丢了的失败工作区重跑先重建工作树再跑 setup，从 failed 转为 open', async () => {
  k = startKited();
  const { repo, workspace, retry } = await failedWorkspace(k, '[ -e "$KITE_MAIN_DIR/ready" ] || exit 3\n');
  rmSync(workspace.cwd, { recursive: true, force: true });
  writeFileSync(join(repo, 'ready'), '');
  await retry();
  expect(read(join(workspace.cwd, 'a.txt'))).toBe('a\n');
  expect(git(workspace.cwd, 'branch', '--show-current')).toBe(workspace.branch!);
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
