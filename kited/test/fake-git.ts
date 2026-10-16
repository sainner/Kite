/**
 * Git 平台的替身：裸仓库放在临时目录，经 git 自带的 http-backend（CGI）以智能 HTTP 提供拉取与推送，不鉴权。
 * 地址是本机 http（`http://127.0.0.1:<端口>/<名字>.git`），kited 把它当普通的远程：归一化后带端口，没绑定凭据时照原样访问。
 * 需要有远程的项目的测试用它；没有远程的项目以各工作机的检出互为远程，不用它。
 * 替身在测试进程里服务，测试自己用 util.ts 的 git（同步起进程，期间事件循环停住）经 http 访问它会卡死；要直接动远程时用 create 返回的裸仓库路径。
 */
import { mkdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { cgiResponse } from '../src/workspace/peer-git.ts';
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
