import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { VariablePreview } from '../../src/context-variables.ts';
import { documentVariables } from '../../src/harness/context/project.ts';
import { folderWorkspace, startKited, type Kited } from '../harness.ts';
import { newRepo, read } from '../util.ts';

const sha256 = (path: string) => createHash('sha256').update(readFileSync(path)).digest('hex');

/** 按一个仓库添加项目并建好工作区，返回工作区 ID 和它的工作树。 */
async function workspaceOf(k: Kited, files: Record<string, string>) {
  const { workspace } = await folderWorkspace(k, newRepo(k.root, 'project', files, null));
  return { id: workspace.id, dir: workspace.cwd };
}

// 几部分的配合：带点的变量名经 HTTP 路由到工作区，再落到它工作树的真实文件系统（记忆索引在 .kite/memory/ 下，新建要连目录一起建），
// 写回的内容要在下一次取值里体现，返回的摘要要对得上磁盘上的字节；文件在别处改过或新建时已存在，真实请求要回 409 且不覆盖。
test('记忆索引从编辑器按工作区新建后，再取值带上这份文件和磁盘字节的摘要；重复新建或带过期摘要写回返回 409，磁盘保持别处的改动', async () => {
  const k = startKited();
  try {
    const { id, dir } = await workspaceOf(k, { 'base.txt': '原始\n' });
    const variable = `/workspaces/${id}/context-variables/project.memory`;
    const location = join(dir, documentVariables['project.memory']);

    const empty = await k.call('GET', variable);
    expect(empty.status).toBe(200);
    expect(empty.body).toEqual({ name: 'project.memory', text: '', files: [], create: location });

    const first = '# 记忆索引\n\n- [第一条](first.md) — 新建\n';
    const created = await k.call('PUT', `${variable}/file`, { path: location, content: first, expectedSha256: null });
    expect(created.status).toBe(200);
    expect(read(location)).toBe(first);
    const preview = created.body as VariablePreview;
    expect(preview.files).toEqual([{ path: location, content: first, sha256: sha256(location) }]);
    expect(preview.create).toBeUndefined();
    expect(preview.text).toContain('- [第一条](first.md) — 新建');
    expect((await k.call('GET', variable)).body).toEqual(preview);

    // 两个编辑器都按「新建」保存：后到的不能盖掉先建的
    const again = await k.call('PUT', `${variable}/file`, { path: location, content: '后到的新建\n', expectedSha256: null });
    expect(again.status).toBe(409);
    expect(read(location)).toBe(first);

    // 编辑器打开后文件在别处被改：带打开时的摘要保存不能覆盖
    const elsewhere = '# 记忆索引\n\n- [别处](elsewhere.md) — 别处改的\n';
    writeFileSync(location, elsewhere);
    const stale = await k.call('PUT', `${variable}/file`, { path: location, content: '编辑器里的旧稿\n', expectedSha256: preview.files![0]!.sha256 });
    expect(stale.status).toBe(409);
    expect(read(location)).toBe(elsewhere);

    // 重新取值拿到别处改过的摘要后，再保存就成
    const reloaded = (await k.call('GET', variable)).body as VariablePreview;
    expect(reloaded.files).toEqual([{ path: location, content: elsewhere, sha256: sha256(location) }]);
    const merged = elsewhere + '- [第二条](second.md) — 合并后\n';
    const saved = await k.call('PUT', `${variable}/file`, { path: location, content: merged, expectedSha256: reloaded.files![0]!.sha256 });
    expect(saved.status).toBe(200);
    expect(read(location)).toBe(merged);
    expect((await k.call('GET', variable)).body.files).toEqual([{ path: location, content: merged, sha256: sha256(location) }]);
  } finally {
    await k.stop();
  }
});

// 写接口能写磁盘，路径限制是安全边界：只有从仓库根到工作树逐级的 AGENTS.md 能写。
// 每个越界请求都让文件名对、摘要对（或文件不存在而按新建），只有位置不对，确认挡下它的是路径而不是摘要；
// `<工作树>/../AGENTS.md` 挡住只按前缀或文件名比对、没把 .. 归一化的判断。
// 取值的范围也是边界：按工作机只能取环境层，项目规则要按工作区取，否则 400。
test('项目规则只能按工作区写回逐级查找的 AGENTS.md：仓库外、借 .. 跳出、更深的子目录、别的变量或别的文件一律 400 且磁盘不变；按工作机取项目规则 400', async () => {
  const k = startKited();
  try {
    const { id, dir } = await workspaceOf(k, { 'base.txt': '原始\n', 'pkg/a.txt': '子目录\n' });
    const write = (path: string, expectedSha256: string | null) =>
      k.call('PUT', `/workspaces/${id}/context-variables/project.rules/file`, { path, content: '被写入\n', expectedSha256 });

    const outside = join(dir, '..', documentVariables['project.rules']);
    writeFileSync(outside, '仓库外的规则\n');
    const existing = [outside, join(dir, 'base.txt')];
    const before = existing.map(read);
    const rejected: Array<[string, string | null]> = [
      [outside, sha256(outside)],
      [`${dir}/../${documentVariables['project.rules']}`, sha256(outside)],
      [join(dir, 'pkg', documentVariables['project.rules']), null],
      [join(dir, documentVariables['project.memory']), null],
      [join(dir, 'base.txt'), sha256(join(dir, 'base.txt'))],
    ];
    for (const [path, digest] of rejected) {
      const r = await write(path, digest);
      expect({ path, status: r.status }).toEqual({ path, status: 400 });
    }
    expect(existing.map(read)).toEqual(before);
    expect(existsSync(join(dir, 'pkg', documentVariables['project.rules']))).toBe(false);
    expect(existsSync(join(dir, documentVariables['project.memory']))).toBe(false);

    // 同一个接口写逐级查找的位置是成的：上面的 400 来自位置，不是这个变量写不了
    const allowed = join(dir, documentVariables['project.rules']);
    expect((await write(allowed, null)).status).toBe(200);
    expect(read(allowed)).toBe('被写入\n');

    // 按工作机取：环境层取得到，项目层取不到；同一个变量按工作区取得到刚写的内容
    expect((await k.call('GET', '/context-variables/machine.name')).status).toBe(200);
    expect((await k.call('GET', '/context-variables/project.rules')).status).toBe(400);
    expect((await k.call('GET', `/workspaces/${id}/context-variables/project.rules`)).body.files)
      .toEqual([{ path: allowed, content: '被写入\n', sha256: sha256(allowed) }]);
  } finally {
    await k.stop();
  }
});
