/**
 * 编译真实 AccountHTTP，验证 Foundation Cookie 行为与生产模式 Better Auth 的配合。
 * 运行：bun kited/test/manual/verify-account-http-swift.ts；不需要编译完整 App 或访问公网。
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

// Better Auth 测试模式会跳过来源检查；必须在导入账号服务之前明确使用生产模式。
process.env.NODE_ENV = 'production';
delete process.env.TEST;
const { createAccountService } = await import('../../src/account/service.ts');

const root = mkdtempSync(join(tmpdir(), 'account-http-contract-'));
const requests: Array<{ phase: string; cookie: boolean; origin: string | null; bearer: boolean; responseCookie: boolean }> = [];
let service: Awaited<ReturnType<typeof createAccountService>> | undefined;
const server = Bun.serve({ hostname: '127.0.0.1', port: 0,
  async fetch(request) {
    if (!service) return new Response('启动中', { status: 503 });
    const observation = { phase: request.headers.get('x-kite-verification-phase') ?? '',
      cookie: request.headers.has('cookie'), origin: request.headers.get('origin'), bearer: request.headers.has('authorization') };
    // 两组各代表一个客户端，避免生产限流把旧客户端的复现请求计入修复后的登录流程。
    const headers = new Headers(request.headers);
    headers.set('x-real-ip', observation.phase.startsWith('legacy-') ? '192.0.2.1' : '192.0.2.2');
    const response = await service.fetch(new Request(request, { headers }));
    requests.push({ ...observation, responseCookie: response.headers.has('set-cookie') });
    return response;
  },
});
try {
  service = await createAccountService({ databasePath: join(root, 'account.sqlite'), baseURL: server.url.origin,
    secret: `native-account-regression-${crypto.randomUUID()}`,
    headscale: { url: 'http://127.0.0.1:1', apiKey: 'unused', controlURL: 'https://unused.example.invalid' },
  });
  const [compiler, sdk, architecture] = await Promise.all([
    command(['xcrun', '--find', 'swiftc'], root), command(['xcrun', '--show-sdk-path'], root), command(['uname', '-m'], root),
  ]);
  const executable = join(root, 'account-http-contract');
  await command([compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`, '-parse-as-library',
    join(import.meta.dir, '../../../app/Kite/Application/AccountHTTP.swift'),
    join(import.meta.dir, 'AccountHTTPVerify.swift'), '-o', executable], root, 45_000);
  // Foundation 的 shared 存储只落入本次临时 home，子进程环境由 command 显式传入。
  const output = await command(['/usr/bin/env', `CFFIXED_USER_HOME=${root}`, executable, server.url.origin, root], root, 15_000);
  const legacy = requests.find((request) => request.phase === 'legacy-missing-origin');
  const forged = requests.find((request) => request.phase === 'legacy-forged-origin');
  const native = requests.filter((request) => request.phase.startsWith('native-'));
  if (!legacy?.cookie || legacy.origin !== null || !forged?.cookie || forged.origin !== 'https://untrusted.example.invalid') {
    throw new Error('旧会话夹具未实际发送残留 Cookie 与指定 Origin');
  }
  if (native.length === 0 || native.some((request) => request.cookie || request.origin !== null)) {
    throw new Error('原生账号请求携带了自动 Cookie 或意外 Origin，或场景没有完整运行');
  }
  for (const phase of ['native-login', 'native-signup-b', 'native-relogin']) {
    if (!native.some((request) => request.phase === phase && request.responseCookie && !request.bearer)) {
      throw new Error(`${phase} 未经过真实服务端 Set-Cookie 响应`);
    }
  }
  console.log(output);
} finally {
  await server.stop(true);
  await service?.close();
  rmSync(root, { recursive: true, force: true });
}
