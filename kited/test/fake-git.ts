/**
 * Git 平台的替身：裸仓库放在临时目录，经 git 自带的 http-backend（CGI）以智能 HTTP 提供拉取与推送，不鉴权。
 * 地址是本机 http（`http://127.0.0.1:<端口>/<名字>.git`），kited 把它当普通的远程：归一化后带端口，没绑定凭据时照原样访问。
 * 需要有远程的项目的测试用它；没有远程的项目以各工作机的检出互为远程，不用它。
 * 替身在测试进程里服务，测试自己用 util.ts 的 git（同步起进程，期间事件循环停住）经 http 访问它会卡死；要直接动远程时用 create 返回的裸仓库路径。
 */
import { mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { git, makeTemp } from './util.ts';

export interface FakeGit {
  /** 新建空的裸仓库 `<name>.git`（默认分支 main），返回访问地址和裸仓库路径。 */
  create(name: string): { url: string; bare: string };
  /**
   * 推送开始前（客户端取 receive-pack 引用广告时）调用，测试可以趁这时让远程多出提交，
   * 使这次推送在客户端被判为非快进而被拒。
   */
  beforePush?: (name: string) => void | Promise<void>;
  /** 拉取引用广告前调用（clone、fetch、ls-remote 都经过这里），测试可以挂起它，或返回失败响应。 */
  beforeFetch?: (name: string) => void | Response | Promise<void | Response>;
  stop(): void;
}

function blankLine(buffer: Uint8Array): [number, number] {
  for (let i = 0; i < buffer.length - 1; i++) {
    if (buffer[i] === 10 && buffer[i + 1] === 10) return [i, 2];
    if (buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 && buffer[i + 3] === 10) return [i, 4];
  }
  return [-1, 0];
}

/** CGI 输出转成 HTTP 响应：先读出响应头，正文照转。 */
async function cgiResponse(stdout: ReadableStream<Uint8Array>): Promise<Response> {
  const reader = stdout.getReader();
  let buffer = new Uint8Array(0);
  let [end, gap] = [-1, 0];
  while (end < 0) {
    const { value, done } = await reader.read();
    if (done) return new Response('http-backend 没有响应', { status: 502 });
    const next = new Uint8Array(buffer.length + value.length);
    next.set(buffer);
    next.set(value, buffer.length);
    buffer = next;
    [end, gap] = blankLine(buffer);
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

export function startFakeGit(): FakeGit {
  const root = makeTemp('fake-git-');
  const repos = join(root, 'repos');
  mkdirSync(repos);
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const matched = /^\/([^/]+)\.git(\/info\/refs|\/git-upload-pack|\/git-receive-pack)$/.exec(url.pathname);
      if (!matched) return new Response('不支持的请求', { status: 404 });
      const [, name, rest] = matched as unknown as [string, string, string];
      const service = rest === '/info/refs' ? url.searchParams.get('service') : rest.slice(1);
      if (service !== 'git-upload-pack' && service !== 'git-receive-pack') return new Response('只支持智能协议', { status: 403 });
      if (rest === '/info/refs' && service === 'git-receive-pack') await fake.beforePush?.(name);
      if (rest === '/info/refs' && service === 'git-upload-pack') {
        const response = await fake.beforeFetch?.(name);
        if (response) return response;
      }
      const header = (key: string, variable: string): Record<string, string> => {
        const value = request.headers.get(key);
        return value ? { [variable]: value } : {};
      };
      const p = Bun.spawn(['git', 'http-backend'], {
        env: {
          PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: root, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
          GIT_PROJECT_ROOT: repos, GIT_HTTP_EXPORT_ALL: '1',
          PATH_INFO: `/${name}.git${rest}`, REQUEST_METHOD: request.method, QUERY_STRING: url.search.slice(1),
          // 设了 REMOTE_USER，http-backend 才接受推送。
          REMOTE_USER: 'tester',
          ...header('content-type', 'CONTENT_TYPE'), ...header('content-length', 'CONTENT_LENGTH'),
          ...header('content-encoding', 'HTTP_CONTENT_ENCODING'), ...header('git-protocol', 'GIT_PROTOCOL'),
        },
        stdin: request.body ?? 'ignore', stdout: 'pipe', stderr: 'ignore',
      });
      return cgiResponse(p.stdout);
    },
  });
  const fake: FakeGit = {
    create(name) {
      const bare = join(repos, `${name}.git`);
      git(root, 'init', '-q', '--bare', '-b', 'main', bare);
      return { url: `http://127.0.0.1:${server.port}/${name}.git`, bare };
    },
    stop() {
      void server.stop(true);
      rmSync(root, { recursive: true, force: true });
    },
  };
  return fake;
}
