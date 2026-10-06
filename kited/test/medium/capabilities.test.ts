import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { api, type Kited, registerCheckout, startKited } from '../harness.ts';
import { newRepo } from '../util.ts';

setDefaultTimeout(3_000);
let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop(); kited = undefined;
});

// 真实 SDK 的初始化控制请求返回模型目录；须实际启动确认目录查询不会发出模型生成请求。
test('Claude 能力查询只初始化 SDK，不请求模型', async () => {
  kited = startKited();
  const workspace = await registerCheckout(kited, newRepo(kited.root, 'project', { 'base.txt': '原始\n' }));
  const opened = await kited.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.claude' },
  });
  expect(opened.status).toBe(200);
  const id = opened.body.target.instanceId as string;
  const before = api.log.length;
  const capabilities = await kited.call('GET', `/instances/${id}/agent-capabilities`);
  expect(capabilities.status).toBe(200);
  expect(capabilities.body.models.map((model: { title: string }) => model.title.toLowerCase()).sort()).toEqual(['fable', 'opus', 'sonnet']);
  expect(api.log).toHaveLength(before);
});
