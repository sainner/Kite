import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmodSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import type { Json, ToolResult } from '../../src/harness/types.ts';
import { WorkspaceFiles } from '../../src/workspace/files.ts';
import { call, folderWorkspace, listSnapshots, machine, openWorkspace, startKited, type Kited } from '../harness.ts';
import { ENV, makeTemp, newDir, newRepo, read, writeFiles } from '../util.ts';

const operationPath = (workspaceId: string, name: string) => `/workspaces/${workspaceId}/operations/${name}`;

async function workspace(k: Kited, repo: string) {
  const { workspace } = await folderWorkspace(k, repo);
  return { id: workspace.id, cwd: workspace.cwd };
}

async function openFiles(k: Kited, workspaceId: string) {
  const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
  });
  expect(opened.status).toBe(200);
  return { instanceId: opened.body.target.instanceId as string };
}

/** 按字节读取工作区文件（GET 或 HEAD /workspaces/:id/files/content）：k.call 只处理 JSON，这里直接 fetch，带上本机的 X-Kite-Machine。 */
async function fileBytes(k: Kited, workspaceId: string, path: string, headers: Record<string, string> = {}, method = 'GET') {
  const { id } = await machine(k.url);
  return fetch(`${k.url}/workspaces/${workspaceId}/files/content?path=${encodeURIComponent(path)}`, {
    method, headers: { 'X-Kite-Machine': id, ...headers },
  });
}

/** 搜索结果的顺序另有约定，这里只比较集合：按路径排好再比。 */
const byPath = (entries: Array<{ name: string; path: string; kind: string }>) =>
  [...entries].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));

async function readTool(cwd: string, logDir: string, path: string): Promise<ToolResult> {
  const tool = localTools({ cwd, logDir, env: ENV() }).find((candidate) => candidate.name === 'read');
  if (!tool) throw new Error('缺少 read 工具');
  const args: Json = { path, offset: 2, limit: 1 };
  tool.validate(args);
  return tool.execute(args, { cwd, signal: new AbortController().signal });
}

// 真实文件系统会解析目录和文件符号链接；文件操作、按字节读取与模型 read 必须守住同一个工作区边界。
test('文件插件、按字节读取与模型 read 读取同一工作区文件，并拒绝真实符号链接与上级目录逃逸', async () => {
  const k = startKited();
  try {
    const { id, cwd } = await workspace(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }, null));
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

    const bytes = await fileBytes(k, id, 'notes/one.txt');
    expect(bytes.status).toBe(200);
    expect(await bytes.text()).toBe('甲\n乙\n丙\n');

    for (const path of [relative(cwd, join(outside, 'secret.txt')), 'escape/secret.txt', 'notes/linked.txt']) {
      const viaPlugin = await k.call('POST', operationPath(id, 'files.read'), { instanceId, path });
      expect(viaPlugin.status).not.toBe(200);
      const viaModel = await readTool(cwd, join(k.root, 'logs'), path).catch(() => ({ status: 'error' as const, output: '' }));
      expect(viaModel.status).toBe('error');
      const viaBytes = await fileBytes(k, id, path);
      expect([path, viaBytes.status]).not.toEqual([path, 200]);
      expect(await viaBytes.text()).not.toContain('外部秘密');
    }
    // 目录和不存在的文件也没有字节可读
    for (const path of ['notes', 'escape', 'notes/missing.txt']) {
      const viaBytes = await fileBytes(k, id, path);
      expect([path, viaBytes.status]).not.toEqual([path, 200]);
      await viaBytes.arrayBuffer();
    }
  } finally {
    await k.stop();
  }
}, 1000);

/*
 * 依赖 Bun 运行时，看代码确认不了：Bun.serve 的路由对 HEAD 只回头、Content-Length 仍是文件大小；Bun.file().slice
 * 作为响应体时实际发出的字节范围和长度；二进制原样发出，不经文本解码。ETag 是缓存的版本，同样长度的内容改写后也要换。
 */
test('按字节读取返回原始字节与版本头，HEAD 只回头，同一 ETag 回 304、内容改了换 ETag，单段 Range 回 206、起点越界回 416', async () => {
  const k = startKited();
  try {
    const { id, cwd } = await workspace(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }, null));
    const path = '截图 目录/首页 1.png';
    const original = Buffer.from(Array.from({ length: 1000 }, (_, i) => (i * 7 + 3) % 256));
    mkdirSync(join(cwd, '截图 目录'));
    writeFileSync(join(cwd, path), original);
    const get = (headers: Record<string, string> = {}) => fileBytes(k, id, path, headers);
    const body = async (response: Response) => Buffer.from(await response.arrayBuffer());

    const full = await get();
    expect(full.status).toBe(200);
    expect((await body(full)).equals(original)).toBe(true);
    const etag = full.headers.get('etag');
    expect(etag).toBeTruthy();
    expect(full.headers.get('content-length')).toBe('1000');
    expect(full.headers.get('content-type')).toBe('image/png');
    expect(full.headers.get('accept-ranges')).toBe('bytes');

    const head = await fileBytes(k, id, path, {}, 'HEAD');
    expect(head.status).toBe(200);
    expect(head.headers.get('content-length')).toBe('1000');
    expect(head.headers.get('etag')).toBe(etag);
    expect((await body(head)).length).toBe(0);

    const cached = await get({ 'If-None-Match': etag! });
    expect(cached.status).toBe(304);
    expect((await body(cached)).length).toBe(0);

    const middle = await get({ Range: 'bytes=10-19' });
    expect(middle.status).toBe(206);
    expect(middle.headers.get('content-range')).toBe('bytes 10-19/1000');
    expect(middle.headers.get('content-length')).toBe('10');
    expect((await body(middle)).equals(original.subarray(10, 20))).toBe(true);
    const tail = await get({ Range: 'bytes=-100' });
    expect(tail.status).toBe(206);
    expect(tail.headers.get('content-range')).toBe('bytes 900-999/1000');
    expect((await body(tail)).equals(original.subarray(900))).toBe(true);
    for (const range of ['bytes=1000-', 'bytes=5000-5009']) {
      const beyond = await get({ Range: range });
      expect([range, beyond.status]).toEqual([range, 416]);
      await beyond.arrayBuffer();
    }

    // 长度不变、内容改了：设备上按旧 ETag 缓存的版本要作废
    const changed = Buffer.from(original.map((byte) => 255 - byte));
    writeFileSync(join(cwd, path), changed);
    const fresh = await get({ 'If-None-Match': etag! });
    expect(fresh.status).toBe(200);
    expect(fresh.headers.get('etag')).not.toBe(etag);
    expect((await body(fresh)).equals(changed)).toBe(true);
  } finally {
    await k.stop();
  }
}, 1000);

// SQLite 收据和服务重启交接实例状态；实际 patch 结果须在文件实例回收后仍可由新实例读取历史 diff。
test('文件选择跨服务重启保留，回收后新实例读取历史 diff 且重试不重复写入', async () => {
  const root = makeTemp('files-plugin-');
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'docs/one.txt': '可读内容\n' }, null);
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const first = await folderWorkspace(daemon, repo);
    const workspaceId = first.workspace.id;
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
    const otherWorkspaceId = (await openWorkspace(daemon, first.project.id)).workspace.id;
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

    const cwd = first.workspace.cwd;
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
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

/*
 * 依赖几条 git 行为合起来的效果，看代码确认不了：ls-files 的 --others --exclude-standard 列出未跟踪但没被忽略的文件，
 * 不列被忽略的文件和被忽略目录里的文件；--cached 对已跟踪但在工作区里删掉的文件照样列出（它还在索引里），要另外滤掉，
 * 它推出的父目录也随之不见；-z 让中文和空格的路径原样输出，不加引号转义。
 */
test('Git 工作区按名字搜索不分大小写，未跟踪的文件和推出的目录能搜到，被忽略的、.git 里的和已删掉的已跟踪文件搜不到', async () => {
  const k = startKited();
  try {
    const repo = newRepo(k.root, 'project', {
      '.gitignore': 'cache-ignored/\n*.ignored-log\n',
      'docs/Guide/intro.md': '介绍\n',
      'docs/Guide/removed-gone.md': '会被删掉\n',
      'stale-gone/tracked-gone.txt': '整个目录会被删掉\n',
    }, null);
    const { id, cwd } = await workspace(k, repo);
    writeFiles(cwd, {
      'Untracked 笔记/草稿 untracked.md': '未跟踪\n',
      'cache-ignored/inner-ignored.bin': '被忽略目录里的文件\n',
      'trace.ignored-log': '按扩展名忽略\n',
    });
    rmSync(join(cwd, 'docs/Guide/removed-gone.md'));
    rmSync(join(cwd, 'stale-gone'), { recursive: true });
    const { instanceId } = await openFiles(k, id);
    const search = async (query: string) => {
      const r = await k.call('POST', operationPath(id, 'files.search'), { instanceId, query });
      if (r.status !== 200) throw new Error(`搜索 ${query} 失败：${r.status} ${JSON.stringify(r.body)}`);
      return r.body;
    };

    const untracked = await search('UNTRACKED');
    expect({ ...untracked, entries: byPath(untracked.entries) }).toEqual({
      query: 'UNTRACKED', truncated: false, entries: [
        { name: 'Untracked 笔记', path: 'Untracked 笔记', kind: 'directory' },
        { name: '草稿 untracked.md', path: 'Untracked 笔记/草稿 untracked.md', kind: 'file' },
      ],
    });
    expect((await search('guide')).entries).toEqual([{ name: 'Guide', path: 'docs/Guide', kind: 'directory' }]);
    for (const query of ['ignored', 'gone', 'HEAD', 'objects']) {
      expect([query, (await search(query)).entries]).toEqual([query, []]);
    }
  } finally {
    await k.stop();
  }
}, 1000);

/*
 * 不是 Git 仓库时 git ls-files 在这里失败，改为逐层查找；文件夹里嵌着别的仓库时，要跳过任何一层的 .git，
 * 否则 HEAD、objects 这些 Git 内部文件会被搜出来。经操作入口登记的文件夹都会先变成仓库，所以直接构造 WorkspaceFiles。
 */
test('不是 Git 仓库的工作区逐层查找文件和目录，嵌在里面的仓库照样能搜到，但跳过它的 .git', async () => {
  const root = makeTemp('files-search-');
  try {
    const folder = newDir(root, 'folder', { 'top-match.md': '顶层\n', 'Alpha/Beta-match.txt': '第二层\n' });
    newRepo(join(folder, 'vendor'), 'lib-match', { 'src/deep-match.ts': 'export {};\n' }, null);
    const files = new WorkspaceFiles(folder);

    const found = await files.search('match');
    expect({ ...found, entries: byPath(found.entries) }).toEqual({
      query: 'match', truncated: false, entries: [
        { name: 'Beta-match.txt', path: 'Alpha/Beta-match.txt', kind: 'file' },
        { name: 'top-match.md', path: 'top-match.md', kind: 'file' },
        { name: 'lib-match', path: 'vendor/lib-match', kind: 'directory' },
        { name: 'deep-match.ts', path: 'vendor/lib-match/src/deep-match.ts', kind: 'file' },
      ],
    });
    for (const query of ['head', 'objects']) {
      expect([query, (await files.search(query)).entries]).toEqual([query, []]);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

/*
 * 浏览里保存要几部分配合，看代码确认不了：files.write 写盘后在快照锁里打一枚快照（真实 git 把工作区的新内容收进快照树），
 * files.history 沿快照链按路径列出这一版，current 拿工作区现在的内容去比、指向它；保存回应的 version 要和 files.read
 * 给的同一算法，客户端拿它当下一次的 baseVersion。回应丢了重试时 baseVersion 还是打开时那个，内容已相同就不能报冲突、
 * 也不能再打一枚。被拒（409）之后同一工作区的锁要放开，紧接着带 force 的保存才能写进去、打上快照。
 */
test('浏览保存后快照链多一枚「编辑 文件名」、历史版本以它为最新且 current 指向它，同样内容重试照旧成功不多打快照；文件被别人改过时旧版本号保存被拒（409）、不写不打快照，带 force 覆盖并打快照', async () => {
  const k = startKited();
  try {
    const path = 'docs/说明 文档.md';
    const label = '编辑 说明 文档.md';
    const { id, cwd } = await workspace(k, newRepo(k.root, 'project', { [path]: '原来的内容\n' }, null));
    const { instanceId } = await openFiles(k, id);
    const operation = (name: string, body: object) => k.call('POST', operationPath(id, name), { instanceId, path, ...body });
    const version = async () => {
      const r = await operation('files.read', {});
      if (r.status !== 200) throw new Error(`读取失败：${r.status} ${JSON.stringify(r.body)}`);
      return r.body.version as string;
    };
    const history = async () => {
      const r = await operation('files.history', {});
      if (r.status !== 200) throw new Error(`取历史版本失败：${r.status} ${JSON.stringify(r.body)}`);
      return r.body as { versions: Array<{ commit: string; at: number; label: string; threadId?: string }>; current: string | null };
    };
    const opened = await version();
    const start = await listSnapshots(k, id);

    const text = '改过的内容\n第二行\n';
    const saved = await operation('files.write', { text, baseVersion: opened });
    expect([saved.status, saved.body]).toEqual([200, { path, version: await version() }]);
    expect(read(join(cwd, path))).toBe(text);
    const edited = await listSnapshots(k, id);
    expect(edited.slice(1)).toEqual(start);
    expect(edited[0]).toMatchObject({ label });
    expect(edited[0]!.threadId).toBeUndefined();
    const listed = await history();
    expect(listed.versions[0]).toEqual({ commit: edited[0]!.commit, at: edited[0]!.at, label });
    expect(listed.current).toBe(edited[0]!.commit);

    // 回应丢了，客户端拿打开时的版本号重发同一份内容
    const retried = await operation('files.write', { text, baseVersion: opened });
    expect([retried.status, retried.body]).toEqual([200, saved.body]);
    expect(await listSnapshots(k, id)).toEqual(edited);

    // 保存之后别人又改了这个文件，客户端还拿着上次保存回的版本号
    writeFileSync(join(cwd, path), '别人改的\n');
    const mine = '我的改动\n';
    const rejected = await operation('files.write', { text: mine, baseVersion: saved.body.version });
    expect(rejected.status).toBe(409);
    expect(read(join(cwd, path))).toBe('别人改的\n');
    expect(await listSnapshots(k, id)).toEqual(edited);

    const forced = await operation('files.write', { text: mine, baseVersion: saved.body.version, force: true });
    expect([forced.status, forced.body]).toEqual([200, { path, version: await version() }]);
    expect(read(join(cwd, path))).toBe(mine);
    const overwritten = await listSnapshots(k, id);
    expect(overwritten.slice(1)).toEqual(edited);
    expect(overwritten[0]).toMatchObject({ label });
    expect((await history()).current).toBe(overwritten[0]!.commit);
  } finally {
    await k.stop();
  }
}, 1000);
