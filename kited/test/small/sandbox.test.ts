import { expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { join } from 'node:path';
import { runCommand } from '../../src/execution/command.ts';
import { harnessPolicy } from '../../src/execution/policy.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import { workspacePolicy } from '../../src/execution/sandbox.ts';
import { gitWorktree, newRepo, useTemp } from '../util.ts';

const temp = useTemp();
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
const env = (cwd: string): NodeJS.ProcessEnv => ({
  PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: cwd, TMPDIR: cwd,
});

function report(output: string): Record<string, any> {
  const line = output.split('\n').find((part) => part.startsWith('KITE_SANDBOX_RESULT='));
  if (!line) throw new Error(`沙箱 fixture 未报告结果：${output}`);
  return JSON.parse(line.slice('KITE_SANDBOX_RESULT='.length));
}

// Seatbelt/bubblewrap 的文件解析、Git worktree 元数据、网络隔离与子进程继承不能通过检查启动参数确认。
test('harness 沙箱允许 Git 状态与工作区写入，拦住宿主凭据、外部文件、本机端口和后代逃逸', async () => {
  const root = temp('sandbox-default-');
  const main = newRepo(root, 'main', { 'tracked.txt': '原始内容\n' });
  const cwd = gitWorktree(main, join(root, 'workspace'), 'kite/sandbox-test');
  const outside = join(root, 'outside');
  mkdirSync(outside);
  const secret = join(outside, 'fake-secret.txt');
  writeFileSync(secret, '仅供测试的假秘密');
  const home = join(cwd, '.kite-host');
  mkdirSync(home);
  const hostDatabase = join(home, 'kite.db');
  const authFile = join(cwd, 'fake-auth.json');
  writeFileSync(hostDatabase, '假数据库秘密');
  writeFileSync(authFile, '假订阅凭据');
  symlinkSync(outside, join(cwd, 'escape'));
  const socketPath = join(cwd, 'u');
  const unixServer = createServer((socket) => socket.end('reachable'));
  await new Promise<void>((resolve, reject) => unixServer.once('error', reject).listen(socketPath, resolve));
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('reachable') });
  try {
    expect(await (await fetch(server.url)).text()).toBe('reachable');
    const fixture = join(cwd, 'probe.ts');
    writeFileSync(fixture, [
      'import { readFileSync, writeFileSync } from "node:fs";',
      'import { createConnection } from "node:net";',
      `const cwd = ${JSON.stringify(cwd)};`,
      `const secret = ${JSON.stringify(secret)};`,
      `const authFile = ${JSON.stringify(authFile)};`,
      `const hostDatabase = ${JSON.stringify(hostDatabase)};`,
      `const commonDir = ${JSON.stringify(join(main, '.git'))};`,
      `const unixSocket = ${JSON.stringify(socketPath)};`,
      `const port = ${server.port};`,
      'function canRead(path: string) { try { readFileSync(path); return true; } catch { return false; } }',
      'function canWrite(path: string) { try { writeFileSync(path, "改写"); return true; } catch { return false; } }',
      'function dial(options: { host: string; port: number } | { path: string }) { return new Promise<string>((resolve) => {',
      '  const socket = createConnection(options);',
      '  socket.once("connect", () => { socket.destroy(); resolve("connected"); });',
      '  socket.once("error", (error: NodeJS.ErrnoException) => resolve(error.code ?? "error"));',
      '  socket.setTimeout(250, () => { socket.destroy(); resolve("timeout"); });',
      '}); }',
      'const own = {',
      '  workspaceWrite: canWrite(`${cwd}/allowed.txt`),',
      '  externalRead: canRead(secret), externalWrite: canWrite(secret),',
      '  authRead: canRead(authFile), authWrite: canWrite(authFile),',
      '  databaseRead: canRead(hostDatabase),',
      '  gitMetadataWrite: canWrite(`${commonDir}/sandbox-should-not-write`),',
      '  linkRead: canRead(`${cwd}/escape/fake-secret.txt`),',
      '  linkWrite: canWrite(`${cwd}/escape/through-link.txt`),',
      '  directNetwork: await dial({ host: "127.0.0.1", port }),',
      '  unixSocket: await dial({ path: unixSocket }),',
      '};',
      'const gitStatus = Bun.spawnSync(["git", "status", "--porcelain"],',
      '  { cwd, env: process.env, stdout: "pipe", stderr: "pipe" });',
      'const gitAdd = Bun.spawnSync(["git", "add", "allowed.txt"],',
      '  { cwd, env: process.env, stdout: "pipe", stderr: "pipe" });',
      'own.gitStatus = gitStatus.exitCode;',
      'own.gitStatusError = gitStatus.stderr.toString();',
      'own.gitAdd = gitAdd.exitCode;',
      'own.gitAddError = gitAdd.stderr.toString();',
      'if (process.argv.includes("--child")) {',
      '  console.log(JSON.stringify(own));',
      '} else {',
      '  const child = Bun.spawn([process.execPath, process.argv[1]!, "--child"],',
      '    { cwd, env: process.env, stdout: "pipe", stderr: "pipe" });',
      '  const childOutput = await new Response(child.stdout).text();',
      '  const childError = await new Response(child.stderr).text();',
      '  const childExit = await child.exited;',
      '  console.log("KITE_SANDBOX_RESULT=" + JSON.stringify({ own, childExit, childError, child: JSON.parse(childOutput) }));',
      '}',
    ].join('\n'));
    const selectedEnv = env(cwd);
    const policy = await harnessPolicy({ cwd, env: selectedEnv, home, repository: main, authFile });
    const result = await runCommand(`${quote(process.execPath)} ${quote(fixture)}`, 3000,
      new AbortController().signal, { cwd, logDir: join(root, 'logs'), env: selectedEnv, policy });
    expect(result).toMatchObject({ status: 'success' });
    const observed = report(result.output);
    expect(observed.childExit).toBe(0);
    expect(observed.childError).toBe('');
    for (const probe of [observed.own, observed.child]) {
      expect(probe.workspaceWrite).toBe(true);
      expect(probe.externalRead).toBe(false);
      expect(probe.externalWrite).toBe(false);
      expect(probe.authRead).toBe(false);
      expect(probe.authWrite).toBe(false);
      expect(probe.databaseRead).toBe(false);
      expect(probe.gitMetadataWrite).toBe(false);
      expect(probe.linkRead).toBe(false);
      expect(probe.linkWrite).toBe(false);
      expect(probe.directNetwork).not.toBe('connected');
      expect(probe.directNetwork).not.toBe('timeout');
      expect(probe.unixSocket).not.toBe('connected');
      expect(probe.unixSocket).not.toBe('timeout');
      expect(probe).toMatchObject({ gitStatus: 0 });
      expect(probe.gitAdd).not.toBe(0);
    }
    const read = localTools({ cwd, logDir: join(root, 'logs'), env: selectedEnv, policy })
      .find((tool) => tool.name === 'read');
    if (!read) throw new Error('缺少 read 工具');
    const args = { path: 'fake-auth.json' };
    read.validate(args);
    const denied = await read.execute(args, { cwd, signal: new AbortController().signal })
      .catch(() => ({ status: 'error' as const }));
    expect(denied.status).toBe('error');
    expect(readFileSync(secret, 'utf8')).toBe('仅供测试的假秘密');
    expect(readFileSync(authFile, 'utf8')).toBe('假订阅凭据');
    expect(readFileSync(hostDatabase, 'utf8')).toBe('假数据库秘密');
    expect(existsSync(join(main, '.git', 'sandbox-should-not-write'))).toBe(false);
    expect(existsSync(join(outside, 'through-link.txt'))).toBe(false);
  } finally {
    await server.stop(true);
    await new Promise<void>((resolve, reject) => unixServer.close((error) => error ? reject(error) : resolve()));
  }
}, 1000);

// 同时启动两份上游代理/Seatbelt 配置，才能发现允许目录或目标端口在实例间串用。
test('并行沙箱分别执行文件和本机端口授权，不能借用另一实例的许可', async () => {
  const root = temp('sandbox-parallel-');
  const left = join(root, 'left');
  const right = join(root, 'right');
  mkdirSync(left);
  mkdirSync(right);
  writeFileSync(join(left, 'owned.txt'), 'LEFT');
  writeFileSync(join(right, 'owned.txt'), 'RIGHT');
  const leftServer = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('LEFT_PORT') });
  const rightServer = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('RIGHT_PORT') });
  try {
    expect(await (await fetch(leftServer.url)).text()).toBe('LEFT_PORT');
    expect(await (await fetch(rightServer.url)).text()).toBe('RIGHT_PORT');
    const execute = (cwd: string, other: string, allowedPort: number, blockedPort: number) => {
      const fixture = join(cwd, 'probe.ts');
      writeFileSync(fixture, [
        'import { readFileSync, writeFileSync } from "node:fs";',
        `const own = ${JSON.stringify(join(cwd, 'owned.txt'))};`,
        `const other = ${JSON.stringify(join(other, 'owned.txt'))};`,
        `const ownNew = ${JSON.stringify(join(cwd, 'new.txt'))};`,
        `const otherNew = ${JSON.stringify(join(other, 'blocked.txt'))};`,
        `const allowedPort = ${allowedPort}; const blockedPort = ${blockedPort};`,
        'function canRead(path: string) { try { readFileSync(path); return true; } catch { return false; } }',
        'function canWrite(path: string) { try { writeFileSync(path, "写入"); return true; } catch { return false; } }',
        'function curl(port: number) {',
        '  const proxy = process.env.HTTP_PROXY ?? process.env.http_proxy ?? "";',
        '  const child = Bun.spawnSync(["/usr/bin/curl", "--proxy", proxy, "--noproxy", "",',
        '    "--silent", "--show-error", "--max-time", "1", "--write-out", "\\n%{http_code}",',
        '    `http://127.0.0.1:${port}/`], { env: process.env, stdout: "pipe", stderr: "pipe" });',
        '  const lines = child.stdout.toString().trimEnd().split("\\n");',
        '  return { proxyPresent: proxy.length > 0, code: child.exitCode, status: Number(lines.pop()), body: lines.join("\\n") };',
        '}',
        'console.log("KITE_SANDBOX_RESULT=" + JSON.stringify({',
        '  ownRead: canRead(own), otherRead: canRead(other),',
        '  ownWrite: canWrite(ownNew), otherWrite: canWrite(otherNew),',
        '  allowed: curl(allowedPort), blocked: curl(blockedPort),',
        '}));',
      ].join('\n'));
      const selectedEnv = env(cwd);
      const policy = { ...workspacePolicy(cwd, selectedEnv), network: [`127.0.0.1:${allowedPort}`] };
      return runCommand(`${quote(process.execPath)} ${quote(fixture)}`, 3000,
        new AbortController().signal, { cwd, logDir: join(root, `logs-${allowedPort}`), env: selectedEnv, policy });
    };
    const [leftResult, rightResult] = await Promise.all([
      execute(left, right, leftServer.port!, rightServer.port!),
      execute(right, left, rightServer.port!, leftServer.port!),
    ]);
    for (const [result, marker] of [[leftResult, 'LEFT_PORT'], [rightResult, 'RIGHT_PORT']] as const) {
      expect(result).toMatchObject({ status: 'success' });
      const observed = report(result.output);
      expect(observed.ownRead).toBe(true);
      expect(observed.otherRead).toBe(false);
      expect(observed.ownWrite).toBe(true);
      expect(observed.otherWrite).toBe(false);
      expect(observed.allowed.proxyPresent).toBe(true);
      expect(observed.allowed.code).toBe(0);
      expect(observed.allowed.status).toBe(200);
      expect(observed.allowed.body).toBe(marker);
      expect(observed.blocked.status).not.toBe(200);
      expect(observed.blocked.body).not.toContain(marker === 'LEFT_PORT' ? 'RIGHT_PORT' : 'LEFT_PORT');
    }
    expect(existsSync(join(left, 'blocked.txt'))).toBe(false);
    expect(existsSync(join(right, 'blocked.txt'))).toBe(false);
  } finally {
    await leftServer.stop(true);
    await rightServer.stop(true);
  }
}, 1000);
