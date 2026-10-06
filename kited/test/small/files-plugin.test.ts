import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmodSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import type { Json, ToolResult } from '../../src/harness/types.ts';
import { call, linkNewAccount, registerCheckout, startKited, type Kited } from '../harness.ts';
import { Seen } from '../harness-loop.ts';
import { ENV, makeTemp, newRepo } from '../util.ts';

const operationPath = (workspaceId: string, name: string) => `/workspaces/${workspaceId}/operations/${name}`;

async function workspace(k: Kited, repo: string) {
  const registered = await registerCheckout(k, repo);
  return { id: registered.workspace.id, cwd: registered.workspace.cwd };
}

async function openFiles(k: Kited, workspaceId: string) {
  const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
  });
  expect(opened.status).toBe(200);
  return { instanceId: opened.body.target.instanceId as string };
}

async function readTool(cwd: string, logDir: string, path: string): Promise<ToolResult> {
  const tool = localTools({ cwd, logDir, env: ENV() }).find((candidate) => candidate.name === 'read');
  if (!tool) throw new Error('缺少 read 工具');
  const args: Json = { path, offset: 2, limit: 1 };
  tool.validate(args);
  return tool.execute(args, { cwd, signal: new AbortController().signal });
}

// 真实文件系统会解析目录和文件符号链接；HTTP 文件能力与模型 read 必须守住同一个工作区边界。
test('文件插件与模型 read 读取同一工作区文本，并拒绝真实符号链接与上级目录逃逸', async () => {
  const k = startKited();
  try {
    const repo = newRepo(k.root, 'project', { 'base.txt': '原始\n' });
    const { id, cwd } = await workspace(k, repo);
    const notes = join(cwd, 'notes');
    mkdirSync(notes);
    writeFileSync(join(notes, 'one.txt'), '甲\n乙\n丙\n');
    const outside = join(k.root, 'outside');
    mkdirSync(outside);
    writeFileSync(join(outside, 'secret.txt'), '外部秘密\n');
    symlinkSync(outside, join(cwd, 'escape'));
    symlinkSync(join(outside, 'secret.txt'), join(notes, 'linked.txt'));
    const { instanceId } = await openFiles(k, id);

    const listed = await k.call('POST', operationPath(id, 'files.list'), { instanceId });
    expect(listed.status).toBe(200);
    expect(listed.body.entries).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: 'notes', kind: 'directory' }),
      expect.objectContaining({ name: 'escape', kind: 'symlink' }),
    ]));
    const selected = await k.call('POST', operationPath(id, 'files.read'), {
      instanceId, path: 'notes/one.txt', offset: 2, limit: 1,
    });
    expect(selected.status).toBe(200);
    expect(selected.body.text).toContain('乙');
    expect(selected.body.text).not.toMatch(/甲|丙/);
    const modelRead = await readTool(cwd, join(k.root, 'logs'), 'notes/one.txt');
    expect(modelRead.status).toBe('success');
    expect(modelRead.output).toContain('乙');
    expect(modelRead.output).not.toMatch(/甲|丙/);

    for (const path of [relative(cwd, join(outside, 'secret.txt')), 'escape/secret.txt', 'notes/linked.txt']) {
      const viaPlugin = await k.call('POST', operationPath(id, 'files.read'), { instanceId, path });
      expect(viaPlugin.status).not.toBe(200);
      const viaModel = await readTool(cwd, join(k.root, 'logs'), path).catch(() => ({ status: 'error' as const, output: '' }));
      expect(viaModel.status).toBe('error');
    }
  } finally {
    await k.stop();
  }
}, 1000);

// SQLite 收据和服务重启交接实例状态；实际 patch 结果须在文件实例回收后仍可由新实例读取历史 diff。
test('文件选择跨服务重启保留，回收后新实例读取历史 diff 且重试不重复写入', async () => {
  const root = makeTemp('files-plugin-');
  const home = join(root, 'kite');
  const account = linkNewAccount(home);
  const repo = newRepo(root, 'project', { 'docs/one.txt': '可读内容\n' });
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspaceId = checkout.body.workspace.id as string;
    const targetWindow = await call(daemon.url, 'POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    });
    expect(targetWindow.status).toBe(200);
    const targetId = targetWindow.body.target.instanceId as string;
    const sourceWindow = await call(daemon.url, 'POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    });
    expect(sourceWindow.status).toBe(200);
    const sourceId = sourceWindow.body.target.instanceId as string;
    const otherWorkspace = await call(daemon.url, 'POST', '/workspaces', { checkout: checkout.body.checkout.id });
    expect(otherWorkspace.status).toBe(200);
    const otherWorkspaceId = otherWorkspace.body.workspace.id as string;
    await events.wait((event) => event.type === 'workspace.changed' && event.workspaceId === otherWorkspaceId && event.status === 'open');
    const filePath = 'docs/one.txt';

    const initial = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.state'), { instanceId: targetId });
    expect(initial.status).toBe(200);
    const selection = { instanceId: targetId, operationId: 'choose-one', expectedRevision: initial.body.revision, path: `./${filePath}` };
    const selected = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.select'), selection);
    expect(selected.status).toBe(200);
    expect(selected.body.path).toBe(filePath);
    const retry = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.select'), selection);
    expect(retry.status).toBe(200);
    expect(retry.body).toEqual(selected.body);
    expect((await call(daemon.url, 'POST', operationPath(workspaceId, 'files.select'), {
      instanceId: targetId, operationId: 'stale-clear', expectedRevision: initial.body.revision, path: null,
    })).status).toBe(409);

    const pluginCaller = { kind: 'plugin' as const, instanceId: sourceId };
    await expect(daemon.kite.operations.invoke(pluginCaller, workspaceId, 'files.read', { instanceId: targetId, path: filePath }))
      .rejects.toMatchObject({ outcome: 'denied' });
    const grants = daemon.kite.operations.grants(sourceId);
    await daemon.kite.configureOperationGrants(sourceId, grants.revision, [
      { operation: 'files.read', targets: { kind: 'instances', instanceIds: [targetId] } },
    ]);
    const allowed = await daemon.kite.operations.invoke(pluginCaller, workspaceId, 'files.read', { instanceId: targetId, path: filePath });
    expect(allowed).toMatchObject({ text: expect.stringContaining('可读内容') });
    await expect(daemon.kite.operations.invoke(pluginCaller, otherWorkspaceId, 'files.read', {
      instanceId: targetId, path: filePath,
    })).rejects.toMatchObject({ outcome: 'denied' });

    const cwd = checkout.body.workspace.cwd as string;
    const patch = localTools({ cwd, logDir: join(root, 'logs'), diffDir: join(home, 'diffs', workspaceId), env: ENV() })
      .find((tool) => tool.name === 'patch');
    if (!patch) throw new Error('缺少 patch 工具');
    const executePatch = async (operations: Json[]): Promise<ToolResult> => {
      const args: Json = { operations };
      patch.validate(args);
      return patch.execute(args, { cwd, signal: new AbortController().signal });
    };
    const firstPatch = await executePatch([
      { type: 'update_file', path: filePath, diff: '@@\n-可读内容\n+第二版' },
      { type: 'create_file', path: '新文件.txt', diff: '+新增内容\n+' },
    ]);
    const secondPatch = await executePatch([{ type: 'update_file', path: filePath, diff: '@@\n-第二版\n+第三版' }]);
    const deleted = await executePatch([
      { type: 'delete_file', path: filePath }, { type: 'delete_file', path: '新文件.txt' },
    ]);
    // 规划阶段两项都有效；第二项在真实写盘时因目录权限失败，第一项必须仍有可回看的差异。
    const locked = join(cwd, '只读');
    mkdirSync(locked);
    chmodSync(locked, 0o555);
    let partial: ToolResult;
    try {
      partial = await executePatch([
        { type: 'create_file', path: '部分成功.txt', diff: '+已写入\n+' },
        { type: 'create_file', path: '只读/失败.txt', diff: '+不应产生差异\n+' },
      ]);
    } finally {
      chmodSync(locked, 0o755);
    }
    expect([firstPatch.status, secondPatch.status, deleted.status]).toEqual(['success', 'success', 'success']);
    expect(partial.status).toBe('error');
    const history = [
      { result: firstPatch, files: [
        { path: filePath, before: '可读内容\n', after: '第二版\n' },
        { path: '新文件.txt', before: null, after: '新增内容\n' },
      ] },
      { result: secondPatch, files: [{ path: filePath, before: '第二版\n', after: '第三版\n' }] },
      { result: deleted, files: [
        { path: filePath, before: '第三版\n', after: null },
        { path: '新文件.txt', before: '新增内容\n', after: null },
      ] },
      { result: partial, files: [{ path: '部分成功.txt', before: null, after: '已写入\n' }] },
    ];
    expect(new Set(history.map(({ result }) => result.diff?.id)).size).toBe(history.length);
    for (const { result, files } of history) {
      expect(result.diff?.paths).toEqual(files.map((file) => file.path));
      const readDiff = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.diff'), {
        instanceId: targetId, diffId: result.diff!.id,
      });
      if (readDiff.status !== 200) throw new Error(`读取历史 diff 失败：${readDiff.status} ${JSON.stringify(readDiff.body)}`);
      expect(readDiff.body).toEqual({ id: result.diff!.id, files });
    }

    // 当前文件已被删除，历史预览必须依靠指定 diff，而不是先校验当前文件存在。
    const historicalSelection = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.select'), {
      instanceId: targetId, operationId: 'choose-historical-diff', expectedRevision: selected.body.revision,
      path: filePath, diffId: firstPatch.diff!.id,
    });
    expect(historicalSelection.status).toBe(200);
    expect(structuredClone(historicalSelection.body)).toMatchObject({ path: filePath, diffId: firstPatch.diff!.id });

    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const restored = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.state'), { instanceId: targetId });
    expect(restored.status).toBe(200);
    expect(restored.body).toEqual(historicalSelection.body);
    const retriedAfterRestart = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.select'), selection);
    expect(retriedAfterRestart.status).toBe(200);
    expect(retriedAfterRestart.body).toEqual(selected.body);
    expect((await call(daemon.url, 'POST', operationPath(workspaceId, 'files.state'), { instanceId: targetId })).body)
      .toEqual(historicalSelection.body);
    expect((await call(daemon.url, 'DELETE', `/workspaces/${workspaceId}/windows/${targetWindow.body.id}`)).status).toBe(200);
    expect((await call(daemon.url, 'POST', operationPath(workspaceId, 'files.state'), { instanceId: targetId })).status).toBe(404);
    const replacement = await call(daemon.url, 'POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    });
    expect(replacement.status).toBe(200);
    const replacementId = replacement.body.target.instanceId as string;
    expect(replacementId).not.toBe(targetId);
    expect((await call(daemon.url, 'POST', operationPath(workspaceId, 'files.state'), { instanceId: replacementId })).body.path).toBeNull();
    for (const { result, files } of history) {
      const readDiff = await call(daemon.url, 'POST', operationPath(workspaceId, 'files.diff'), {
        instanceId: replacementId, diffId: result.diff!.id,
      });
      if (readDiff.status !== 200) throw new Error(`重建服务后读取历史 diff 失败：${readDiff.status} ${JSON.stringify(readDiff.body)}`);
      expect(readDiff.body).toEqual({ id: result.diff!.id, files });
    }
  } finally {
    await daemon?.stop();
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
