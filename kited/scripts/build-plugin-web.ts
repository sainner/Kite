/** 只构建仓库内的可信宿主页；安装插件时不运行此构建器。 */
import { join } from 'node:path';

export async function buildPluginHost(): Promise<string> {
  const built = await Bun.build({ entrypoints: [join(import.meta.dir, '../web/plugin-host.ts')], target: 'browser', minify: true });
  if (!built.success || built.outputs.length !== 1) throw new AggregateError(built.logs, '插件宿主页构建失败');
  const script = (await built.outputs[0]!.text()).replace(/<\/script/gi, '<\\/script');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src about:; connect-src 'none'; base-uri 'none'; form-action 'none'">
<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style>
</head><body><script type="module">${script}</script></body></html>`;
}

if (import.meta.main) {
  await Bun.write(join(import.meta.dir, '../../app/Kite/PluginHost.html'), await buildPluginHost());
  console.log('已构建 App 插件宿主页');
}
