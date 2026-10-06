/** 已知样例预构建：输出可通过安装 API 接收的完整包，安装不执行构建。 */
import { join } from 'node:path';
import type { PluginPackage } from '../src/plugins/catalog.ts';

export async function buildTodoPackage(): Promise<PluginPackage> {
  const root = join(import.meta.dir, '../examples');
  const view = await Bun.build({ entrypoints: [join(root, 'todo-view.ts')], target: 'browser', minify: true });
  if (!view.success || view.outputs.length !== 1) throw new AggregateError(view.logs, '待办界面构建失败');
  const script = (await view.outputs[0]!.text()).replace(/<\/script/gi, '<\\/script');
  const html = (await Bun.file(join(root, 'todo-view.html')).text()).replace('<!--script-->', `<script type="module">${script}</script>`);
  const backend = await Bun.build({ entrypoints: [join(root, 'todo-plugin.ts')], target: 'bun', minify: true,
    define: { KITE_TODO_HTML: JSON.stringify(html) } });
  if (!backend.success || backend.outputs.length !== 1) throw new AggregateError(backend.logs, '待办插件构建失败');
  return { id: 'custom.todo.v1', title: '待办', lifetime: 'persistent', bundle: await backend.outputs[0]!.text(),
    views: [{ id: 'list', title: '待办列表', resourceUri: 'ui://kite-todo/list.html' }], defaultView: 'list' };
}

if (import.meta.main) {
  const path = process.argv[2] ?? join(import.meta.dir, '../../build/todo-plugin.json');
  await Bun.write(path, JSON.stringify(await buildTodoPackage()));
  console.log(`已构建待办插件包：${path}`);
}
