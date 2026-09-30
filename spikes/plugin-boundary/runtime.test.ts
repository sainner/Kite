import { expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { launchPlugin } from './runtime.ts';

type PluginProcess = ReturnType<typeof launchPlugin>;

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'kite-plugin-boundary-'));
  const bundle = join(root, 'bundle');
  const cwd = join(root, 'runtime');
  const external = join(root, 'external');
  for (const path of [bundle, cwd, external]) mkdirSync(path);
  return { root, entry: join(bundle, 'plugin.js'), cwd, external };
}

async function finish(proc: PluginProcess) {
  try { proc.kill(); } catch { /* 已退出 */ }
  await proc.exited;
}

async function output(proc: PluginProcess) {
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, code };
}

// Deno 的进程权限由真实运行时判定：插件能计算，但不能越出 bundle 读取或使用宿主能力。
test('插件可运行普通 JS，文件、环境、回环网络和子进程能力都被 Deno 拒绝', async () => {
  const { root, entry, cwd, external } = fixture();
  const secret = join(external, 'fake-secret.txt');
  const written = join(cwd, 'unexpected.txt');
  let proc: PluginProcess | undefined;
  try {
    writeFileSync(secret, '仅用于实验的假秘密');
    writeFileSync(entry, `
    const attempts = {
      read: () => Deno.readTextFile(${JSON.stringify(secret)}),
      write: () => Deno.writeTextFile(${JSON.stringify(written)}, 'unexpected'),
      env: () => Deno.env.get('KITE_PLUGIN_BOUNDARY_FAKE_SECRET'),
      net: () => Deno.connect({ hostname: '127.0.0.1', port: 1 }),
      run: () => new Deno.Command('echo', { args: ['unexpected'] }).output(),
    };
    const denied = {};
    for (const [name, attempt] of Object.entries(attempts)) {
      try { await attempt(); denied[name] = false; }
      catch { denied[name] = true; }
    }
    const permissions = {
      read: await Deno.permissions.query({ name: 'read', path: ${JSON.stringify(secret)} }),
      write: await Deno.permissions.query({ name: 'write', path: ${JSON.stringify(written)} }),
      env: await Deno.permissions.query({ name: 'env', variable: 'KITE_PLUGIN_BOUNDARY_FAKE_SECRET' }),
      net: await Deno.permissions.query({ name: 'net', host: '127.0.0.1:1' }),
      run: await Deno.permissions.query({ name: 'run', command: 'echo' }),
    };
    console.log(JSON.stringify({ value: 6 * 7, denied, permissions: Object.fromEntries(
      Object.entries(permissions).map(([name, status]) => [name, status.state])
    ) }));
    `);
    proc = launchPlugin(entry, cwd);
    const result = await output(proc);
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout.trim())).toEqual({
      value: 42,
      denied: { read: true, write: true, env: true, net: true, run: true },
      // Deno 对未授予的文件路径报告 prompt；无交互时实际读取必须失败。
      permissions: { read: 'prompt', write: 'denied', env: 'denied', net: 'denied', run: 'denied' },
    });
    expect(readFileSync(secret, 'utf8')).toBe('仅用于实验的假秘密');
    expect(() => readFileSync(written)).toThrow();
  } finally {
    if (proc) await finish(proc);
    rmSync(root, { recursive: true, force: true });
  }
}, 5000);

// Deno 会先解析静态模块图，Worker 还会单独加载模块；三种入口都不能读取 bundle 外的文件。
test('静态 import、动态 import 和 Worker 都不能执行 bundle 外的本地模块', async () => {
  const { root, entry, cwd, external } = fixture();
  const outside = join(external, 'outside.js');
  const outsideURL = pathToFileURL(outside).href;
  const processes: PluginProcess[] = [];
  try {
    writeFileSync(outside, "console.log('OUTSIDE_MODULE_EXECUTED'); if (typeof postMessage === 'function') postMessage('WORKER_EXECUTED'); export const value = 1;\n");
    writeFileSync(entry, `import { value } from ${JSON.stringify(outsideURL)}; console.log('STATIC_EXECUTED', value);`);
    const staticProc = launchPlugin(entry, cwd);
    processes.push(staticProc);
    const staticResult = await output(staticProc);
    expect(staticResult.code).not.toBe(0);
    expect(staticResult.stdout).not.toContain('OUTSIDE_MODULE_EXECUTED');
    expect(staticResult.stdout).not.toContain('STATIC_EXECUTED');
    expect(staticResult.stderr).toMatch(/Requires read access|PermissionDenied|NotCapable/i);

    writeFileSync(entry, `
      try { await import(${JSON.stringify(outsideURL)}); console.log('DYNAMIC_EXECUTED'); }
      catch { console.log('DYNAMIC_DENIED'); }
    `);
    const dynamicProc = launchPlugin(entry, cwd);
    processes.push(dynamicProc);
    const dynamicResult = await output(dynamicProc);
    expect(dynamicResult.code).toBe(0);
    expect(dynamicResult.stdout.trim()).toBe('DYNAMIC_DENIED');

    writeFileSync(entry, `
      try {
        const worker = new Worker(${JSON.stringify(outsideURL)}, { type: 'module' });
        const outcome = await new Promise((resolve) => {
          worker.onmessage = (event) => resolve(event.data);
          worker.onerror = (event) => { event.preventDefault(); resolve('WORKER_DENIED'); };
        });
        worker.terminate();
        console.log(outcome);
      } catch { console.log('WORKER_DENIED'); }
    `);
    const workerProc = launchPlugin(entry, cwd);
    processes.push(workerProc);
    const workerResult = await output(workerProc);
    expect(workerResult.code).toBe(0);
    expect(workerResult.stdout.trim()).toBe('WORKER_DENIED');
  } finally {
    for (const proc of processes) await finish(proc);
    rmSync(root, { recursive: true, force: true });
  }
}, 5000);

// 子进程需要在报告 ready 后能被立即回收；无限循环不能留下后台插件进程。
test('无限循环的插件收到 kill 后退出且不残留进程', async () => {
  const { root, entry, cwd } = fixture();
  let proc: PluginProcess | undefined;
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  try {
    writeFileSync(entry, "console.log('ready'); for (;;) {}\n");
    proc = launchPlugin(entry, cwd);
    reader = proc.stdout.getReader();
    let stdout = '';
    while (!stdout.includes('\n')) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error(`插件未报告 ready：${stdout}`);
      stdout += new TextDecoder().decode(chunk.value);
    }
    expect(stdout.split('\n')[0]).toBe('ready');
    proc.kill();
    expect(await proc.exited).not.toBe(0);
    expect(() => process.kill(proc.pid, 0)).toThrow();
  } finally {
    reader?.releaseLock();
    if (proc) await finish(proc);
    rmSync(root, { recursive: true, force: true });
  }
}, 5000);
