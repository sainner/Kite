// 宿主入口不静态导入插件；插件及其依赖在权限生效后才加载。
const entry = Deno.args[0];
await import(entry);
