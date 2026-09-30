import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const root = import.meta.dir;
mkdirSync(join(root, 'dist'), { recursive: true });
async function script(name: string, target: 'browser' | 'node') {
  const result = await Bun.build({ entrypoints: [join(root, name + '.ts')], target, format: 'esm', minify: true });
  if (!result.success) throw new AggregateError(result.logs, `无法构建 ${name}`);
  return result.outputs[0]!.text();
}
const html = (script: string, csp: string) => `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="${csp}"></head><body><div id="app"></div><script type="module">${script.replaceAll('</script', '<\\/script')}</script></body></html>`;

await Bun.write(join(root, 'dist/view.html'), html(await script('view', 'browser'), "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src data:; base-uri 'none'; form-action 'none'"));
await Bun.write(join(root, 'dist/host.html'), html(await script('host', 'browser'), "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src 'self' about:; connect-src 'none'; base-uri 'none'; form-action 'none'"));
await Bun.write(join(root, 'dist/todo-server.js'), await script('todo-server', 'node'));
console.log('已构建宿主页、插件视图和单文件工作机入口');

