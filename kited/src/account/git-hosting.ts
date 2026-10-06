/**
 * 托管远程：裸仓库放在服务器目录，HTTPS 访问直接交给 git 自带的 http-backend（CGI），这里只做鉴权后的转接。
 * 只开放智能协议的三个入口，不提供哑协议，也不提供网页。
 */
import { mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { credentialEnv, type GitCredential } from '../git-credential.ts';

const SMART = new Set(['/info/refs', '/git-upload-pack', '/git-receive-pack']);

async function run(args: string[], env: Record<string, string>): Promise<{ code: number; stderr: string; stdout: string }> {
  const p = Bun.spawn(['git', ...args], { env, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { code, stdout, stderr };
}

function indexOfBlankLine(buffer: Uint8Array): [number, number] {
  for (let i = 0; i < buffer.length - 1; i++) {
    if (buffer[i] === 10 && buffer[i + 1] === 10) return [i, 2];
    if (buffer[i] === 13 && buffer[i + 1] === 10 && buffer[i + 2] === 13 && buffer[i + 3] === 10) return [i, 4];
  }
  return [-1, 0];
}

/** 把 CGI 输出转成 HTTP 响应：先读出响应头，正文边读边转发，大仓库不进内存。 */
async function cgiResponse(stdout: ReadableStream<Uint8Array>): Promise<Response> {
  const reader = stdout.getReader();
  let buffer = new Uint8Array(0);
  let [end, gap] = [-1, 0];
  while (end < 0) {
    const { value, done } = await reader.read();
    if (done) return new Response('托管仓库没有响应', { status: 502 });
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

export class GitHosting {
  constructor(readonly root: string, private readonly path = process.env.PATH ?? '/usr/bin:/bin') {
    mkdirSync(root, { recursive: true, mode: 0o700 });
  }

  /** git 子进程只拿到这些环境变量，不继承服务的密钥。 */
  private env(extra: Record<string, string> = {}): Record<string, string> {
    return { PATH: this.path, HOME: this.root, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', ...extra };
  }

  private repo(id: string): string { return join(this.root, `${id}.git`); }

  async create(id: string): Promise<void> {
    const r = await run(['init', '-q', '--bare', '-b', 'main', this.repo(id)], this.env());
    if (r.code !== 0) throw new Error(`创建托管仓库失败：${r.stderr.trim()}`);
  }

  remove(id: string): void { rmSync(this.repo(id), { recursive: true, force: true }); }

  /** 智能协议请求。writable 为 false 时拒绝推送，迁移中和迁移后的托管仓库只读。 */
  async serve(request: Request, id: string, rest: string, user: string, writable: boolean): Promise<Response> {
    const url = new URL(request.url);
    if (!SMART.has(rest)) return new Response('不支持的托管仓库请求', { status: 404 });
    const service = rest === '/info/refs' ? url.searchParams.get('service') : rest.slice(1);
    if (service !== 'git-upload-pack' && service !== 'git-receive-pack') return new Response('只支持智能协议', { status: 403 });
    if (service === 'git-receive-pack' && !writable) return new Response('这个项目已迁移，托管仓库只读', { status: 403 });
    const header = (name: string, variable: string): Record<string, string> => {
      const value = request.headers.get(name);
      return value ? { [variable]: value } : {};
    };
    const p = Bun.spawn(['git', 'http-backend'], {
      env: this.env({
        GIT_PROJECT_ROOT: this.root, GIT_HTTP_EXPORT_ALL: '1',
        PATH_INFO: `/${id}.git${rest}`, REQUEST_METHOD: request.method, QUERY_STRING: url.search.slice(1),
        // 设置 REMOTE_USER 后 http-backend 才允许推送；是否允许由上面的 writable 决定。
        REMOTE_USER: user,
        ...header('content-type', 'CONTENT_TYPE'), ...header('content-length', 'CONTENT_LENGTH'),
        ...header('content-encoding', 'HTTP_CONTENT_ENCODING'), ...header('git-protocol', 'GIT_PROTOCOL'),
      }),
      stdin: request.body ?? 'ignore', stdout: 'pipe', stderr: 'ignore',
    });
    return cgiResponse(p.stdout);
  }

  /** 把托管仓库的全部分支和标签推到正式远程。仓库还没有任何分支时什么都不做。 */
  async pushAll(id: string, url: string, credential: GitCredential | null): Promise<void> {
    const repo = this.repo(id);
    const heads = await run(['-C', repo, 'for-each-ref', '--count=1', 'refs/heads'], this.env());
    if (heads.code !== 0) throw new Error('托管仓库不可读');
    if (!heads.stdout.trim()) return;
    const r = await run(['-C', repo, 'push', '--porcelain', url, 'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*'],
      this.env(credentialEnv(url, credential)));
    if (r.code !== 0) throw new Error(r.stderr.trim().split('\n').slice(-3).join('\n') || '推送到新远程失败');
  }
}
