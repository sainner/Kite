import { expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { dirname, join } from 'node:path';
// 询问与放行模式的沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import { runCommand, type NetworkAsk } from '../../src/execution/command.ts';
import { harnessPolicy } from '../../src/execution/policy.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import { workspacePolicy } from '../../src/execution/sandbox.ts';
import { gitWorktree, newDir, newRepo, useTemp } from '../util.ts';

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

/*
 * Seatbelt/bubblewrap 的文件解析、Git worktree 元数据、网络隔离与子进程继承不能通过检查启动参数确认。
 * localhost 一条挡住真实 bug：macOS 的 /etc 是指向 /private/etc 的符号链接，denyRead 含 / 时上游连链接本身的元数据
 * 也不给；mDNSResponder 的 socket 有意挡着，libinfo 的 getaddrinfo 连不上它就退回读 /etc/hosts，也读不到，
 * localhost 报 ENOTFOUND，vitest 一启动就失败。外部域名仍解析失败，说明放开的只是 hosts，DNS 没放开。
 * 上级目录一条挡住真实 bug：macOS 上原来只给工作区的各级上级目录元数据权限、不能打开，项目里为防符号链接从 / 起
 * 逐级 os.open(..., O_DIRECTORY|O_NOFOLLOW, dir_fd=...) 的 Python 脚本第一级就报 EPERM（'private' 或 'Users'）。
 * 能不能打开取决于 Seatbelt 怎么区分打开目录与读文件、上游把 glob 转成正则后规则的先后，上游升级可能退回打不开，
 * 也可能放宽成整棵子树可读；所以同时看上级目录里直接放着的文件仍读不到（兄弟目录里的文件由 externalRead 看）。
 * 工作区放在中文名、emoji 名的目录下，挡住真实 bug：只匹配目录本身的写法把路径最后一个 UTF-16 码元包进字符类
 * （/et[c]），上游转成 Seatbelt 正则后按字节匹配，[档] 只匹配一个字节，名字以中文结尾的上级目录永远打不开；
 * 以 emoji 结尾的还被切开代理对。两级都报 EPERM。
 */
test('harness 沙箱允许 Git 状态、工作区写入和解析 localhost，能打开各级上级目录（名字含中文、emoji 的也能），拦住宿主凭据、外部文件、上级目录里的文件、本机端口、外部域名解析和后代逃逸', async () => {
  // 临时目录前缀取短：工作区里的 Unix socket 路径在 macOS 上限 103 字节，下面两级非 ASCII 名字占了 16 字节。
  const root = temp('sandbox-');
  const main = newRepo(root, 'main', { 'tracked.txt': '原始内容\n' });
  // 一级名字以中文结尾，一级以 BMP 之外的字符（emoji）结尾。
  const parent = join(root, '文档', '项目🪁');
  mkdirSync(parent, { recursive: true });
  const cwd = gitWorktree(main, join(parent, 'workspace'), 'kite/sandbox-test');
  const outside = join(root, 'outside');
  mkdirSync(outside);
  const secret = join(outside, 'fake-secret.txt');
  writeFileSync(secret, '仅供测试的假秘密');
  // 每一级非 ASCII 名字的上级目录和临时目录本身里都直接放一个文件。
  const ancestorSecrets = [root, dirname(parent), parent].map((dir) => join(dir, 'fake-ancestor-secret.txt'));
  for (const path of ancestorSecrets) writeFileSync(path, '上级目录里的假秘密');
  // 从 / 到 cwd 的每一级；temp() 已解析符号链接，macOS 上从 /private 起。
  const levels = [cwd];
  while (levels[0] !== '/') levels.unshift(dirname(levels[0]!));
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
      'import { readdirSync, readFileSync, writeFileSync } from "node:fs";',
      'import { createConnection } from "node:net";',
      'import { lookup } from "node:dns/promises";',
      `const cwd = ${JSON.stringify(cwd)};`,
      `const levels: string[] = ${JSON.stringify(levels)};`,
      `const parent = ${JSON.stringify(parent)};`,
      `const ancestorSecrets: string[] = ${JSON.stringify(ancestorSecrets)};`,
      `const secret = ${JSON.stringify(secret)};`,
      `const authFile = ${JSON.stringify(authFile)};`,
      `const hostDatabase = ${JSON.stringify(hostDatabase)};`,
      `const commonDir = ${JSON.stringify(join(main, '.git'))};`,
      `const unixSocket = ${JSON.stringify(socketPath)};`,
      `const port = ${server.port};`,
      'function canRead(path: string) { try { readFileSync(path); return true; } catch { return false; } }',
      'function canWrite(path: string) { try { writeFileSync(path, "改写"); return true; } catch { return false; } }',
      // 打不开时记错误码，失败信息里能看出是哪一级、EPERM 还是别的。
      'function list(path: string): string[] | string { try { return readdirSync(path); } catch (error) { return (error as NodeJS.ErrnoException).code ?? "error"; } }',
      'function opened(path: string) { const entries = list(path); return Array.isArray(entries) || entries; }',
      'function dial(options: { host: string; port: number } | { path: string }) { return new Promise<string>((resolve) => {',
      '  const socket = createConnection(options);',
      '  socket.once("connect", () => { socket.destroy(); resolve("connected"); });',
      '  socket.once("error", (error: NodeJS.ErrnoException) => resolve(error.code ?? "error"));',
      '  socket.setTimeout(250, () => { socket.destroy(); resolve("timeout"); });',
      '}); }',
      'function resolve(host: string) { return new Promise<Record<string, unknown>>((done) => {',
      '  const timer = setTimeout(() => done({ error: "timeout" }), 250);',
      '  lookup(host, { all: true }).then((found) => done({ addresses: found.map((entry) => entry.address) }),',
      '    (error: NodeJS.ErrnoException) => done({ error: error.code ?? "error" })).finally(() => clearTimeout(timer));',
      '}); }',
      'const own = {',
      '  workspaceWrite: canWrite(`${cwd}/allowed.txt`),',
      '  externalRead: canRead(secret), externalWrite: canWrite(secret),',
      '  ancestorsOpened: Object.fromEntries(levels.map((dir) => [dir, opened(dir)])),',
      '  parentEntries: list(parent),',
      '  ancestorFilesRead: Object.fromEntries(ancestorSecrets.map((path) => [path, canRead(path)])),',
      '  authRead: canRead(authFile), authWrite: canWrite(authFile),',
      '  databaseRead: canRead(hostDatabase),',
      '  gitMetadataWrite: canWrite(`${commonDir}/sandbox-should-not-write`),',
      '  linkRead: canRead(`${cwd}/escape/fake-secret.txt`),',
      '  linkWrite: canWrite(`${cwd}/escape/through-link.txt`),',
      '  directNetwork: await dial({ host: "127.0.0.1", port }),',
      '  unixSocket: await dial({ path: unixSocket }),',
      '  localhost: await resolve("localhost"), externalDns: await resolve("example.com"),',
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
      // Bun 1.4 解析失败后进程要再挂约 1 秒才退出（沙箱里实测），显式退出。
      'process.exit(0);',
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
      if (process.platform === 'darwin') {
        expect(probe.localhost).toEqual({ addresses: expect.arrayContaining(['127.0.0.1']) });
        expect(probe.ancestorsOpened).toEqual(Object.fromEntries(levels.map((dir) => [dir, true])));
        expect(probe.parentEntries).toEqual(expect.arrayContaining(['workspace', 'fake-ancestor-secret.txt']));
        expect(probe.ancestorFilesRead).toEqual(Object.fromEntries(ancestorSecrets.map((path) => [path, false])));
      }
      expect(probe.externalDns).not.toHaveProperty('addresses');
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

/*
 * 依赖 git 自己按 ~/.gitconfig 的 core.excludesFile、core.attributesFile 找文件（~ 按 HOME 展开），打不开时报
 * warning: unable to access … 并当作没有这份规则；放没放行只有在 Seatbelt 里跑才知道。
 * 挡住真实 bug：沙箱只放行 git 默认位置的 ~/.config/git/{ignore,attributes}，用户在 ~/.gitconfig 里改了位置时，
 * 沙箱里每条 git 命令都报读不到 ~/.gitignore_global，全局忽略规则也不生效。HOME 放在工作区之外，否则工作区授权本来就可读；
 * 放行的只该是这两个文件，同在 HOME 里的 git 凭据仍读不到。
 */
test('~/.gitconfig 指定位置的全局忽略、属性文件在沙箱里的 git 读得到且规则生效，同在 HOME 里的 git 凭据仍读不到', async () => {
  const root = temp('sandbox-gitconfig-');
  const home = newDir(root, 'home', {
    '.gitconfig': '[core]\n\texcludesFile = ~/.gitignore_global\n\tattributesFile = ~/.gitattributes_global\n',
    '.gitignore_global': '*.kite-ignored\n',
    '.gitattributes_global': '*.txt kite-global\n',
    '.git-credentials': 'https://kite:fake-token@example.test\n',
  });
  const cwd = newRepo(root, 'workspace', { 'tracked.md': '已跟踪\n' }, null);
  writeFileSync(join(cwd, 'build.kite-ignored'), '');
  writeFileSync(join(cwd, 'visible.txt'), '');
  const selectedEnv: NodeJS.ProcessEnv = { ...env(cwd), HOME: home };
  const command = [
    'echo "--- status"; git status --porcelain 2>&1',
    'echo "--- attr"; git check-attr kite-global -- visible.txt 2>&1',
    'echo "--- credentials"; cat "$HOME/.git-credentials" 2>&1 || echo DENIED',
  ].join('; ');
  const result = await runCommand(command, 3000, new AbortController().signal,
    { cwd, logDir: join(root, 'logs'), env: selectedEnv, policy: workspacePolicy(cwd, selectedEnv) });
  expect(result).toMatchObject({ status: 'success' });
  const sections: Record<string, string[]> = {};
  let current: string[] | undefined;
  for (const line of result.output.split('\n')) {
    if (line.startsWith('--- ')) sections[line.slice(4)] = current = [];
    else if (line.trim()) current?.push(line);
  }
  // 没有 unable to access 的警告，匹配全局忽略规则的不列出；没被忽略的照常列出，说明 status 确实列了未跟踪文件。
  expect(sections.status).toEqual(['?? visible.txt']);
  expect(sections.attr).toEqual(['visible.txt: kite-global: set']);
  expect(sections.credentials).toContain('DENIED');
  expect(sections.credentials!.join('\n')).not.toContain('fake-token');
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

/*
 * 依赖上游 @anthropic-ai/sandbox-runtime 的代理：名单外主机在 DNS 解析前交给放行回调，HTTP 代理上拒绝回 403、
 * 放行后 .invalid 解析失败回 502，不靠外网也能分清放行与拒绝。回调经沙箱宿主进程与 kited 之间的 socket 往返；
 * 同一主机的决定在这条命令里复用，三条命令同时跑、各问各的；命令自己结束（curl 超时）时还挂着的询问要作废。
 * 回环一条挡住真实漏洞：.kite/setup 用的「名单外一律放行」宿主对 127.0.0.1 这类 IP 字面量和 localhost 直接放行
 * （上游的解析地址检查只判主机名，IP 字面量原样放过，localhost 也被认作该连回环），沙箱里的命令能经代理连到
 * kited 只监听回环、信任回环客户端的本机接口。上游给命令的 NO_PROXY 含回环，curl 默认直连会先被 Seatbelt 挡住，
 * 要 --noproxy '' 强制走代理才测得到；SOCKS 走上游放在 FTP_PROXY 里的 socks5h 地址。
 * 名单里写了本机地址一条挡住真实漏洞：上游只对名单外主机调回调，网络许可里写了 127.0.0.1:端口 就绕过本机检查，
 * 回调一律放行也不该连上，HTTP 与 SOCKS 都是。
 * 回应晚于命令 timeout 一条挡住真实 bug：超时计时器在等审批时照走，默认 120 秒一到就杀掉命令、询问随之作废；
 * 等人回应的时间不算命令的运行时间。这里的回应延迟就是场景本身：比 timeout 长，从沙箱启动到问出来约 0.1 秒，
 * 计时不停的话回应到达前命令已超时。
 */
test('名单外主机按询问结果放行或拒绝，同一命令里同一主机只问一次，等回应的时间不算命令超时，命令结束时没回应的询问作废；回环地址不问也连不上，写进网络许可也连不上', async () => {
  const cwd = temp('sandbox-ask-');
  const selectedEnv = env(cwd);
  let hits = 0;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => { hits += 1; return new Response('reachable'); } });
  try {
    const probe = (label: string, url: string, options = '') => `curl --silent --output /dev/null --noproxy '' ${options}`
      + ` --max-time 1 --write-out 'RESULT ${label} %{http_code}\\n' ${quote(url)};`;
    const statuses = (output: string) => Object.fromEntries(output.split('\n')
      .filter((line) => line.startsWith('RESULT ')).map((line) => line.split(' ').slice(1, 3)));
    const execute = (command: string, askNetwork: NetworkAsk, options: { timeout?: number; network?: string[] } = {}) =>
      runCommand(command, options.timeout ?? 3000, new AbortController().signal, { cwd, logDir: join(cwd, 'logs'), env: selectedEnv,
        policy: { ...workspacePolicy(cwd, selectedEnv), ...(options.network ? { network: options.network } : {}) }, askNetwork });
    const twice = `${probe('first', 'http://kite-ask.invalid:8080/')} ${probe('second', 'http://kite-ask.invalid:8080/again')}`;
    const loopback = `http://127.0.0.1:${server.port}/`;
    const asked: Record<'deny' | 'allow' | 'pending' | 'slow', Array<{ host: string; port?: number }>> = { deny: [], allow: [], pending: [], slow: [] };
    let voided!: () => void;
    const pendingVoided = new Promise<void>((resolve) => { voided = resolve; });
    const [denied, allowed, slow] = await Promise.all([
      execute(twice, async (target) => { asked.deny.push(target); return false; }),
      // 回环端口写进网络许可，回调又一律放行：两条路都不能让它连上。
      execute([twice,
        probe('loopback', loopback),
        probe('localhost', `http://localhost:${server.port}/`),
        probe('numeric', `http://2130706433:${server.port}/`),
        probe('socks', loopback, '--proxy "$FTP_PROXY"'),
      ].join(' '), async (target) => { asked.allow.push(target); return true; }, { network: [`127.0.0.1:${server.port}`] }),
      execute(probe('slow', 'http://kite-slow.invalid:8080/'), async (target) => {
        asked.slow.push(target);
        await Bun.sleep(450);
        return true;
      }, { timeout: 400 }),
      // 不回应，只在作废时结束；作废等的是 abort 事件，不卡命令返回的那一刻。
      execute(`curl --silent --max-time 0.3 http://kite-pending.invalid:8080/`, (target, signal) => new Promise<boolean>((resolve) => {
        asked.pending.push(target);
        signal.addEventListener('abort', () => { voided(); resolve(false); }, { once: true });
        if (signal.aborted) { voided(); resolve(false); }
      })),
    ]);
    expect(statuses(denied.output)).toEqual({ first: '403', second: '403' });
    expect(asked.deny).toEqual([{ host: 'kite-ask.invalid', port: 8080 }]);
    expect(statuses(allowed.output)).toEqual({
      first: '502', second: '502', loopback: '403', localhost: '403', numeric: '403', socks: '000',
    });
    expect(asked.allow).toEqual([{ host: 'kite-ask.invalid', port: 8080 }]);
    expect(hits).toBe(0);
    expect(slow).toMatchObject({ status: 'success' });
    expect(statuses(slow.output)).toEqual({ slow: '502' });
    expect(asked.slow).toEqual([{ host: 'kite-slow.invalid', port: 8080 }]);
    expect(asked.pending).toEqual([{ host: 'kite-pending.invalid', port: 8080 }]);
    await pendingVoided;
  } finally {
    await server.stop(true);
  }
}, 1000);
