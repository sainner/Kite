/**
 * 手动验证真实账号、Headscale 与 tsnet 的身份隔离和撤销传播，不属于常规 .kite/check。
 * 运行：bun kited/test/manual/verify-account-network.ts
 * KITE_ACCOUNT_URL 可覆盖账号服务；仅打印测试用户 ID，账号记录由操作者在托管实例清理。
 * 不要求控制面撤销自然产生 EOF；模拟客户端响应账号 401 后关闭网络，不验证原生 App 自动收口。
 */
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { NetworkStatus } from '../../src/network.ts';

interface Login { token: string; user: { id: string; email: string } }
interface Enrollment { device: { id: string }; controlURL: string; authKey: string }
interface Joined { daemon: Daemon; login: Login; enrollment: Enrollment; network: NetworkStatus }
type CurlProcess = Bun.Subprocess<'ignore', 'pipe', 'ignore'>;
class ProbeFailure extends Error {}

async function main() {
  const accountURL = new URL(process.env.KITE_ACCOUNT_URL ?? 'https://hs.sainner.top');
  if (!['http:', 'https:'].includes(accountURL.protocol) || accountURL.username || accountURL.password) {
    throw new ProbeFailure('KITE_ACCOUNT_URL 必须是不含凭据的 HTTP(S) 地址');
  }
  const binaryName = process.platform === 'win32' ? 'kite-net.exe' : 'kite-net';
  const binary = process.env.KITE_NETWORK_BINARY
    ? resolve(process.env.KITE_NETWORK_BINARY) : resolve(import.meta.dir, '../../net/bin', binaryName);
  if (!existsSync(binary)) throw new ProbeFailure('缺少 kited/net/bin/kite-net，请先构建组网程序');
  const root = mkdtempSync(join(tmpdir(), 'kite-account-network-'));
  const userIDs: string[] = [];
  const daemons: Daemon[] = [];
  const devices: Array<{ id: string; token: string }> = [];
  const processes: CurlProcess[] = [];
  const end = Date.now() + 90_000;
  const controller = new AbortController();
  // 留最后十秒清理；硬期限也涵盖网络请求、curl 和本机节点收尾。
  const validationTimer = setTimeout(() => controller.abort(), 80_000);
  let printedIDs = false;
  const printIDs = () => {
    if (!printedIDs) console.log(`待清理测试账号 user IDs：${JSON.stringify(userIDs)}`);
    printedIDs = true;
  };
  const hardDeadline = setTimeout(() => {
    for (const proc of processes) if (proc.exitCode === null) proc.kill('SIGKILL');
    printIDs();
    console.error('验证与清理超过 90 秒；请按上述用户 ID 检查服务端残留');
    process.exit(1);
  }, 90_000);
  const expired = new Promise<never>((_, reject) => {
    controller.signal.addEventListener('abort', () => reject(new ProbeFailure('验证超时，进入清理')), { once: true });
  });
  // 同一截止信号供所有并发入网与流读取使用，避免未被 await 的超时拒绝。
  void expired.catch(() => {});
  const bounded = <T>(pending: Promise<T>) => Promise.race([pending, expired]);
  async function within<T>(pending: Promise<T>, milliseconds: number, failure: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await bounded(Promise.race([
        pending,
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new ProbeFailure(failure)), milliseconds); }),
      ]));
    } finally { clearTimeout(timer); }
  }

  async function account<T>(method: string, path: string, token?: string, body?: unknown): Promise<T> {
    const response = await fetch(new URL(path, accountURL), {
      method, signal: controller.signal,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) throw new ProbeFailure(`账号接口 ${method} ${path.split('/').slice(0, 3).join('/')} 返回 ${response.status}`);
    return await response.json() as T;
  }
  async function signUp(email: string, password: string): Promise<Login> {
    const login = await account<Login>('POST', '/api/auth/sign-up/email', undefined, { email, password, name: '组网手动验证' });
    userIDs.push(login.user.id);
    return login;
  }
  async function enroll(login: Login, name: string, role: 'worker' | 'controller', revokeToken: string): Promise<Joined> {
    const enrollment = await account<Enrollment>('POST', '/api/devices/enroll', login.token, { name, role });
    devices.push({ id: enrollment.device.id, token: revokeToken });
    const daemon = startDaemon({ home: join(root, name), port: 0, networkBinary: binary, lightTasks: false });
    daemons.push(daemon);
    return { daemon, login, enrollment, network: daemon.network.status() };
  }
  async function connect(node: Joined) {
    await bounded(node.daemon.network.joinAccount({
      deviceId: node.enrollment.device.id, controlURL: node.enrollment.controlURL, authKey: node.enrollment.authKey,
    }));
    while (true) {
      const status = node.daemon.network.status();
      if (status.state === 'Running' && status.ips?.length && status.address && status.socksPort) {
        node.network = status;
        break;
      }
      await bounded(Bun.sleep(200));
    }
    const ip = node.network.ips!.find((value) => !value.includes(':')) ?? node.network.ips![0]!;
    await account('POST', `/api/devices/${node.enrollment.device.id}/complete`, node.login.token, { ip, port: 5483 });
  }
  function spawnCurl(socksPort: number, url: string, headers: Record<string, string>, seconds: number, stream: boolean): CurlProcess {
    const proc = Bun.spawn([
      'curl', '--disable', '--silent', '--noproxy', '', '--socks5-hostname', `127.0.0.1:${socksPort}`,
      '--connect-timeout', '2', '--max-time', String(Math.max(1, seconds)),
      ...(stream ? ['--no-buffer', '--dump-header', '-'] : ['--write-out', '\n%{http_code}']),
      ...Object.entries(headers).flatMap(([name, value]) => ['--header', `${name}: ${value}`]), url,
    ], { env: { ...(process.env as Record<string, string>) }, stdin: 'ignore', stdout: 'pipe', stderr: 'ignore' });
    processes.push(proc);
    return proc;
  }
  async function request(node: Joined, url: string, forged = false) {
    const proc = spawnCurl(node.network.socksPort!, url, forged ? { 'X-Kite-Network': 'forged-network-secret' } : {}, 3, false);
    const [exit, output] = await bounded(Promise.all([proc.exited, new Response(proc.stdout).text()]));
    const match = /\n(\d{3})$/.exec(output);
    if (!match) throw new ProbeFailure('curl 未返回 HTTP 状态；未把客户端执行错误当作授权拒绝');
    // ACL 拒绝可能表现为连接失败、超时、EOF、连接重置或 SOCKS 拒绝。
    if (![0, 7, 28, 52, 56, 97].includes(exit)) throw new ProbeFailure(`curl 执行失败，退出码 ${exit}`);
    return { status: Number(match[1]), body: output.slice(0, match.index) };
  }
  async function openEvents(node: Joined, url: string, machineId: string) {
    const seconds = Math.max(1, Math.floor((end - 10_000 - Date.now()) / 1_000));
    const proc = spawnCurl(node.network.socksPort!, url, { 'X-Kite-Machine': machineId }, seconds, true);
    const reader = proc.stdout.pipeThrough(new TextDecoderStream()).getReader();
    try {
      let buffer = '';
      while (!buffer.includes('catalog.snapshot')) {
        const chunk = await bounded(reader.read());
        if (chunk.done) throw new ProbeFailure('SSE 未返回目录快照便已结束');
        buffer += chunk.value;
        if (buffer.length > 1_048_576) throw new ProbeFailure('SSE 首帧超出验证上限');
      }
      if (!/^HTTP\/\S+ 200\b/.test(buffer)) throw new ProbeFailure('SSE 没有返回 HTTP 200');
    } catch (error) {
      reader.releaseLock();
      throw error;
    }
    const finished = (async () => {
      try { while (!(await reader.read()).done); }
      finally { reader.releaseLock(); }
      return await proc.exited;
    })();
    void finished.catch(() => {});
    return { proc, finished };
  }

  let succeeded = false;
  let cleanupFailed = false;
  try {
    const suffix = crypto.randomUUID();
    const password = `${crypto.randomUUID()}-Kite9!`;
    const owner = await signUp(`kite-network-${suffix}-a@example.com`, password);
    const sameAccount = await account<Login>('POST', '/api/auth/sign-in/email', undefined, { email: owner.user.email, password });
    if (sameAccount.token === owner.token) throw new ProbeFailure('第二设备未取得独立账号会话');
    const outsider = await signUp(`kite-network-${suffix}-b@example.com`, `${crypto.randomUUID()}-Kite9!`);
    const worker = await enroll(owner, 'worker', 'worker', owner.token);
    const peer = await enroll(sameAccount, 'controller', 'controller', owner.token);
    const other = await enroll(outsider, 'outsider', 'controller', outsider.token);
    await bounded(Promise.all([connect(worker), connect(peer), connect(other)]));
    console.log('三个临时节点已完成真实入网');

    const machineResponse = await fetch(`${worker.daemon.url}/machine`, { signal: controller.signal });
    const machine = await machineResponse.json() as { id: string };
    const machineURL = new URL('/machine', worker.network.address!).href;
    while (true) {
      const response = await request(peer, machineURL);
      if (response.status >= 200 && response.status < 300) {
        if ((JSON.parse(response.body) as { id: string }).id !== machine.id) throw new ProbeFailure('代理请求到达了错误的工作机');
        break;
      }
      await bounded(Bun.sleep(200));
    }
    const denied = await request(other, machineURL, true);
    if (denied.status >= 200 && denied.status < 300) throw new ProbeFailure('异账号携带伪造网络头仍访问到了工作机');
    console.log('同账号访问成功，异账号伪造网络头无法访问');

    const stream = await openEvents(peer, new URL('/events', worker.network.address!).href, machine.id);
    if (stream.proc.exitCode !== null) throw new ProbeFailure('设备撤销前 SSE 已断开');
    await account('DELETE', `/api/devices/${peer.enrollment.device.id}`, owner.token);
    const session = await fetch(new URL('/api/account', accountURL), {
      headers: { authorization: `Bearer ${peer.login.token}` }, signal: controller.signal,
    });
    await session.body?.cancel();
    if (session.status !== 401) throw new ProbeFailure(`被撤销的会话访问账号接口未返回 401，实际 ${session.status}`);
    // 先保留 controller 本机网络，给控制面最多十五秒传播，避免本机主动关闭掩盖服务端未撤销。
    await within((async () => {
      while (true) {
        const after = await request(peer, machineURL);
        if (after.status < 200 || after.status >= 300) return;
        await bounded(Bun.sleep(200));
      }
    })(), 15_000, '十五秒内未观察到被撤销设备的新组网请求被拒绝');
    console.log('本机网络尚未主动关闭：被撤销会话返回 401，新组网请求无法访问');

    // 模拟客户端处理 401；curl 不被主动杀死，必须由网络关闭使现有流结束。
    const exit = await within((async () => {
      await peer.daemon.network.stop();
      return await stream.finished;
    })(), 5_000, '客户端关闭网络后，既有 SSE 未在五秒内结束');
    if (![0, 18, 52, 56].includes(exit)) throw new ProbeFailure(`客户端收口后 SSE 未正常结束，curl 退出码 ${exit}`);
    succeeded = true;
    console.log('模拟客户端响应 401 关闭网络后，既有 SSE 已结束；原生 App 自动收口未在此验证');
  } finally {
    clearTimeout(validationTimer);
    controller.abort();
    for (const proc of processes) if (proc.exitCode === null) proc.kill('SIGKILL');
    // 先清理控制设备，再删持有清理会话的工作机；避免提前撤销自身会话而留下一台设备。
    for (const device of [...devices].reverse()) {
      try {
        const remaining = Math.max(1, Math.min(2_000, end - Date.now()));
        const response = await fetch(new URL(`/api/devices/${device.id}`, accountURL), {
          method: 'DELETE', headers: { authorization: `Bearer ${device.token}` }, signal: AbortSignal.timeout(remaining),
        });
        if (!response.ok && response.status !== 404) cleanupFailed = true;
        await response.body?.cancel();
      } catch { cleanupFailed = true; }
    }
    const stopped = await Promise.allSettled(daemons.map((daemon) => daemon.stop()));
    if (stopped.some((result) => result.status === 'rejected')) cleanupFailed = true;
    await Promise.all(processes.map((proc) => proc.exited));
    rmSync(root, { recursive: true, force: true });
    clearTimeout(hardDeadline);
    printIDs();
    if (cleanupFailed) {
      process.exitCode = 1;
      console.error('部分清理失败；请按上述用户 ID 检查服务端设备和账号记录');
    }
  }
  if (succeeded && !cleanupFailed) console.log('验证通过；设备及本地临时状态已清理');
}

try { await main(); }
catch (error) {
  process.exitCode = 1;
  console.error(error instanceof ProbeFailure ? error.message : '验证失败；未输出原始异常，以免泄漏认证信息');
}
