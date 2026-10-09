/** 独立本地演示，不读取用户的 kited 数据，也不调用模型。Ctrl-C 后清理演示目录。 */
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../src/daemon.ts';
import { buildTodoPackage } from './build-todo-plugin.ts';
import { linkAccount, startFakeAccount } from '../test/fake-account.ts';

const root = mkdtempSync(join(tmpdir(), 'kite-todo-preview-'));
let daemon: Daemon | undefined;
// 项目必须登记到账号；演示用本机的账号服务替身，不连托管服务。
const account = startFakeAccount(join(root, 'account'));
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  await daemon?.stop();
  account.stop();
  rmSync(root, { recursive: true, force: true });
}
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => {
  void close().then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });
});

try {
  const path = join(root, '待办插件预览');
  mkdirSync(path);
  writeFileSync(join(path, 'README.md'), '# 待办插件预览\n\n此目录只用于本地功能演示，退出演示服务后清理。\n');
  linkAccount(join(root, 'data'), account);
  daemon = startDaemon({ home: join(root, 'data'), port: 5483 });
  daemon.kite.catalog.install(await buildTodoPackage());
  const { workspace } = await daemon.kite.registerCheckout({ path });
  const window = await daemon.kite.openWindow(workspace.id, { id: crypto.randomUUID(), content: { kind: 'create', definitionId: 'custom.todo.v1' } });
  for (const title of ['试着添加和完成待办', '关闭窗口，再从侧栏打开同一实例']) {
    await daemon.kite.operations.invoke({ kind: 'ui' }, workspace.id, 'plugin.call', {
      instanceId: window.target.instanceId, tool: 'todo_add', operationId: crypto.randomUUID(), arguments: { title },
    });
  }
  const agent = await daemon.kite.startAgent(workspace.id, { operationId: crypto.randomUUID(), title: '待办协作代理', presentation: 'background' });
  const grants = daemon.kite.operations.grants(agent.instanceId);
  await daemon.kite.configureOperationGrants(agent.instanceId, grants.revision,
    [...grants.grants, { operation: 'plugin.call', instanceId: window.target.instanceId, tools: ['todo_list', 'todo_add', 'todo_complete'] }]);
  console.log(JSON.stringify({ url: daemon.url, root, workspaceId: workspace.id, instanceId: window.target.instanceId, agentId: agent.instanceId }));
  console.log('待办预览已就绪；App 连接 http://127.0.0.1:5483。代理已授权但未启动，Ctrl-C 结束演示。');
} catch (error) {
  await close();
  throw error;
}
