/**
 * 没有远程的项目以各工作机上的检出互为远程（docs/分布式架构.md「数据的归属与同步」）：kited 在组网上只读地提供本机检出的
 * Git 智能 HTTP，其他工作机从这里 clone 和拉取，不接受推送。主线只做快进，两边都有新提交时不合并，留给用户集成。
 * 服务端直接交给 git 自带的 http-backend（CGI），这里只做转接；只开放拉取的两个入口。
 */
import { rmSync } from 'node:fs';
import { basename, dirname } from 'node:path';
import { gitConfigEnv } from '../git-credential.ts';
import { fastForward, git, gitTry, revParse } from './git.ts';
import type { Peer } from '../peer-fetch.ts';
import { currentBranch, gitFailure, missingRef, type RemoteAccess } from './remote.ts';

/** 访问对端 kited 的方式：组网上经 kite-net 的本机 HTTP 代理；测试里同一进程的几台直接访问，没有代理。 */
export interface PeerRoute { proxy?: string }

const peersRef = (machine: string) => `refs/kite/peers/${machine}/`;
export const peerURL = (peer: Peer, projectId: string) => `${peer.address}/git/${projectId}`;

/** curl 的速度下限：低于 limit 字节每秒持续 time 秒就断开。 */
interface Speed { limit: number; time: number }
/** 对端睡眠或断网时连接可能挂着不断，采纳等操作持锁拉取：连续 30 秒几乎没有数据就放弃，慢中继上的大仓库只要还在传就不受影响。 */
const PATIENT: Speed = { limit: 1, time: 30 };
/**
 * 组网上一条连接遇上丢包后可能一直慢下去，新开的连接却往往很快（见 peer-fetch.ts）。Git 的包是对端现场生成的，没法按段取，
 * 只能整次重来：前两次 15 秒里平均每秒不到 32 KB 就断开换一条，之后按 PATIENT 取到底。
 */
const BRISK: Speed = { limit: 32 * 1024, time: 15 };
const BRISK_ATTEMPTS = 2;

/** 经代理访问对端检出的方式，请求带上对端的机器 ID。 */
function peerAccess(peer: Peer, projectId: string, route: PeerRoute, speed: Speed): RemoteAccess {
  return { url: peerURL(peer, projectId),
    env: gitConfigEnv([['http.extraHeader', `X-Kite-Machine: ${peer.id}`], ['http.lowSpeedLimit', String(speed.limit)], ['http.lowSpeedTime', String(speed.time)],
      ...(route.proxy ? [['http.proxy', route.proxy] as [string, string]] : [])]) };
}

/** 按 BRISK、PATIENT 的节奏跑一个访问对端的 Git 命令：太慢被 curl 断开的换个连接再来，其余结果原样交回。 */
async function briskly(peer: Peer, projectId: string, route: PeerRoute,
  run: (access: RemoteAccess) => Promise<{ code: number; stderr: string }>): Promise<{ code: number; stderr: string }> {
  for (let attempt = 1; ; attempt++) {
    const brisk = attempt <= BRISK_ATTEMPTS;
    const r = await run(peerAccess(peer, projectId, route, brisk ? BRISK : PATIENT));
    // curl 的说明不随语言变：取引用列表时是 Operation too slow，取包时 Git 报 RPC failed; curl 28。
    if (r.code === 0 || !brisk || !/Operation too slow|curl 28/i.test(r.stderr)) return r;
  }
}

/** 从对端的检出 clone 成裸仓库；origin 不留，没有远程的项目各检出平等。 */
export async function clonePeer(peer: Peer, projectId: string, dest: string, route: PeerRoute): Promise<void> {
  let attempt = 0;
  const r = await briskly(peer, projectId, route, (access) => {
    // 上一次断开时可能留下建了一半的目录。
    if (attempt++) rmSync(dest, { recursive: true, force: true });
    return gitTry('/', ['clone', '-q', '--bare', '--', access.url, dest], { env: access.env });
  });
  if (r.code !== 0) throw gitFailure(`从 ${peer.id} clone`, r.stderr);
  await git(dest, ['remote', 'remove', 'origin']);
}

/**
 * 从对端拉取全部分支到 refs/kite/peers/<机器>/，本机主线落后就快进到对端同名分支。
 * 返回 diverged 表示两边都有新提交，要用户在工作区里集成。
 */
export async function syncPeer(cwd: string, peer: Peer, projectId: string, route: PeerRoute): Promise<'current' | 'forwarded' | 'diverged' | 'absent'> {
  const prefix = peersRef(peer.id);
  const r = await briskly(peer, projectId, route,
    (access) => gitTry(cwd, ['fetch', '-q', '--no-tags', '--prune', '--', access.url, `+refs/heads/*:${prefix}*`], { env: access.env }));
  if (r.code !== 0) throw gitFailure(`从 ${peer.id} 拉取`, r.stderr);
  const branch = await currentBranch(cwd);
  const theirs = branch && await revParse(cwd, `${prefix}${branch}`);
  if (!branch || !theirs) return 'absent';
  return fastForward(cwd, branch, theirs);
}

/** 从对端的检出取几条 ref（refspec 写法），对端没有的跳过；一次取几条时缺一条整次失败，所以逐条取。 */
export async function fetchPeerRefs(cwd: string, peer: Peer, projectId: string, route: PeerRoute, specs: string[]): Promise<void> {
  for (const spec of specs) {
    const r = await briskly(peer, projectId, route,
      (access) => gitTry(cwd, ['fetch', '-q', '--no-tags', '--', access.url, spec], { env: { ...access.env, LC_ALL: 'C' } }));
    if (r.code !== 0 && !missingRef(r.stderr)) throw gitFailure(`从 ${peer.id} 取工作区的快照`, r.stderr);
  }
}

/** 对端的拉取请求：rest 为 /info/refs 或 /git-upload-pack，其余拒绝。 */
export async function serveCheckout(request: Request, checkout: string, rest: string): Promise<Response> {
  const url = new URL(request.url);
  const service = rest === '/info/refs' ? url.searchParams.get('service') : rest.slice(1);
  if (service !== 'git-upload-pack') return new Response('只提供拉取', { status: 403 });
  const header = (name: string, variable: string): Record<string, string> => {
    const value = request.headers.get(name);
    return value ? { [variable]: value } : {};
  };
  const p = Bun.spawn(['git', 'http-backend'], {
    env: {
      PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: process.env.HOME ?? '',
      // 检出是裸仓库，路径就是 Git 目录。
      GIT_PROJECT_ROOT: dirname(checkout), GIT_HTTP_EXPORT_ALL: '1',
      PATH_INFO: `/${basename(checkout)}${rest}`, REQUEST_METHOD: request.method, QUERY_STRING: url.search.slice(1),
      ...header('content-type', 'CONTENT_TYPE'), ...header('content-length', 'CONTENT_LENGTH'),
      ...header('content-encoding', 'HTTP_CONTENT_ENCODING'), ...header('git-protocol', 'GIT_PROTOCOL'),
    },
    stdin: request.body ?? 'ignore', stdout: 'pipe', stderr: 'ignore',
  });
  return cgiResponse(p.stdout);
}

function indexOfBlankLine(buffer: Uint8Array): [number, number] {
  for (let i = 0; i < buffer.length - 1; i++) {
    if (buffer[i] === 10 && buffer[i + 1] === 10) return [i, 2];
    if (buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 && buffer[i + 3] === 10) return [i, 4];
  }
  return [-1, 0];
}

/** 把 CGI 输出转成 HTTP 响应：先读出响应头，正文边读边转发，大仓库不进内存。测试的 Git 平台替身也用它。 */
export async function cgiResponse(stdout: ReadableStream<Uint8Array>): Promise<Response> {
  const reader = stdout.getReader();
  let buffer = new Uint8Array(0);
  let [end, gap] = [-1, 0];
  while (end < 0) {
    const { value, done } = await reader.read();
    if (done) return new Response('检出没有响应', { status: 502 });
    const next = new Uint8Array(buffer.length + value.length);
    next.set(buffer);
    next.set(value, buffer.length);
    buffer = next;
    [end, gap] = indexOfBlankLine(buffer);
  }
  let status = 200;
  const headers = new Headers({ 'cache-control': 'no-store' });
  for (const line of new TextDecoder().decode(buffer.subarray(0, end)).split(/\r?\n/)) {
    const colon = line.indexOf(':');
    if (colon < 0) continue;
    const name = line.slice(0, colon).trim();
    const value = line.slice(colon + 1).trim();
    if (name.toLowerCase() === 'status') status = Number.parseInt(value, 10) || 500;
    else headers.set(name, value);
  }
  const rest = buffer.subarray(end + gap);
  const body = new ReadableStream<Uint8Array>({
    start(controller) { if (rest.length) controller.enqueue(rest); },
    async pull(controller) {
      const { value, done } = await reader.read();
      if (done) controller.close();
      else controller.enqueue(value);
    },
    cancel() { return reader.cancel(); },
  });
  return new Response(body, { status, headers });
}
