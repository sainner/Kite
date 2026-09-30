/** MCP 使用上游流传输；Kite 只负责独立进程组、沙箱及退出确认。 */
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { Client } from '@modelcontextprotocol/client';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { prepareSandbox } from './sandbox.ts';
import { processGroupAlive } from './harness/command.ts';

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
export async function startPluginProcess(options: {
  bundle: string;
  configure(client: Client): void;
  onProcess(pid: number, active: boolean): void;
}) {
  const directory = realpathSync(mkdtempSync(join(process.platform === 'darwin' ? '/private/tmp' : tmpdir(), 'kite-plugin-')));
  let sandbox: ReturnType<typeof prepareSandbox> | undefined;
  let managed = false;
  try {
    const entry = join(directory, 'main.mjs');
    const bunfig = join(directory, 'bunfig.toml');
    writeFileSync(entry, options.bundle, { mode: 0o400 });
    writeFileSync(bunfig, '[run]\nshell = "system"\n', { mode: 0o400 });
    // 插件不继承宿主 HOME、PATH、认证信息或 Bun 自动加载配置。
    const env = { HOME: directory, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' };
    const system = process.platform === 'darwin'
      ? ['/bin/sh', '/usr/lib', '/System/Library', '/Library/Apple', '/dev', '/private/etc/ssl', '/private/etc/localtime']
      : ['/bin/sh', '/lib', '/lib64', '/usr/lib', '/dev', '/etc/ssl', '/etc/ld.so.cache', '/proc'];
    sandbox = prepareSandbox(`exec ${quote(process.execPath)} run --no-env-file --no-install --config=${quote(bunfig)} ${quote(entry)}`,
      { cwd: directory, env, policy: { read: [directory, realpathSync(process.execPath), ...system.filter(existsSync)], write: [], network: [] } });
    const child = spawn(sandbox.executable, sandbox.args, { cwd: directory, env: sandbox.env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    managed = true;
    // 上游传输接受任意双向流，不负责创建进程；反向连接到子进程的 stdout / stdin 即可供 Client 使用。
    const transport = new StdioServerTransport(child.stdout, child.stdin, { maxBufferSize: 2 * 1024 * 1024 });
    const client = new Client({ name: 'Kite', version: '0.1.0' });
    let diagnostics = '';
    let closed = false;
    let closing: Promise<void> | undefined;
    const pid = child.pid;
    const cleanup = () => {
      if (pid && processGroupAlive(pid)) return;
      if (pid) options.onProcess(pid, false);
      sandbox!.dispose();
      rmSync(directory, { recursive: true, force: true });
    };
    const close = (): Promise<void> => closing ??= (async () => {
      closed = true;
      client.onclose = undefined;
      await client.close();
      const kill = (signal: NodeJS.Signals) => { if (pid) { try { process.kill(-pid, signal); } catch {} } };
      kill('SIGTERM');
      const deadline = Date.now() + 600;
      while (pid && processGroupAlive(pid) && Date.now() < deadline) {
        if (Date.now() > deadline - 400) kill('SIGKILL');
        await delay(10);
      }
      child.stdin.destroy(); child.stdout.destroy(); child.stderr.destroy();
      if (pid && processGroupAlive(pid)) throw new Error('无法确认插件进程组已停止，请检查工作机；不会自动重启');
      cleanup();
    })();
    client.onclose = () => { closed = true; void close().catch(() => {}); };
    child.stderr.setEncoding('utf8').on('data', (part: string) => { diagnostics = (diagnostics + part).slice(-8000); });
    child.on('error', () => { void close().catch(() => {}); });
    child.once('exit', () => { void close().catch(() => {}); });
    try {
      if (pid) options.onProcess(pid, true);
      options.configure(client);
      await client.connect(transport, { timeout: 5000 });
      if (closed) throw new Error('插件在握手后退出');
      return { client, close, get closed() { return closed; } };
    } catch (error) {
      await close();
      throw new Error(`插件启动失败：${String(error)}${diagnostics ? `\n${diagnostics}` : ''}`);
    }
  } catch (error) {
    // 启动前失败没有进程；启动后的目录由 close 在确认退出后清理。
    if (!managed) { sandbox?.dispose(); rmSync(directory, { recursive: true, force: true }); }
    throw error;
  }
}
