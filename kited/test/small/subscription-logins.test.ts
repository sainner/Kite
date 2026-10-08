import { expect, test } from 'bun:test';
import { existsSync, readFileSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { SubscriptionLogins } from '../../src/subscription-logins.ts';
import { ENV, useTemp } from '../util.ts';

const temp = useTemp();
type Snapshot = ReturnType<SubscriptionLogins['get']>;

const output = (stream: 1 | 2, text: string) => `writeSync(${stream}, ${JSON.stringify(text)});`;

function fixture(root: string, name: string, source: string): string[] {
  const path = join(root, `${name}.ts`);
  writeFileSync(path, [
    'import { renameSync, writeFileSync, writeSync } from "node:fs";',
    'import { join } from "node:path";',
    'const root = process.env.KITE_LOGIN_TEST_ROOT!;',
    'async function gate(name: string, data: unknown = {}) {',
    '  const resumed = new Promise<void>((resolve) => process.once("SIGUSR1", () => resolve()));',
    '  const path = join(root, name);',
    '  writeFileSync(path + ".pending", JSON.stringify({ pid: process.pid, data }));',
    '  renameSync(path + ".pending", path);',
    '  await resumed;',
    '}',
    source,
  ].join('\n'));
  return [process.execPath, path];
}

async function marker(root: string, name: string): Promise<{ pid: number; data: any }> {
  const path = join(root, name);
  if (!existsSync(path)) {
    await new Promise<void>((resolve, reject) => {
      const watcher = watch(root, () => {
        if (existsSync(path)) { clearTimeout(timer); watcher.close(); resolve(); }
      });
      const timer = setTimeout(() => {
        watcher.close();
        reject(new Error(`等待登录夹具 ${name} 超时`));
      }, 700);
      if (existsSync(path)) { clearTimeout(timer); watcher.close(); resolve(); }
    });
  }
  return JSON.parse(readFileSync(path, 'utf8'));
}

async function snapshot(logins: SubscriptionLogins, id: string, predicate: (value: Snapshot) => boolean): Promise<Snapshot> {
  const deadline = Date.now() + 700;
  while (true) {
    const value = logins.get(id);
    if (predicate(value)) return value;
    if (Date.now() >= deadline) throw new Error(`等待登录状态超时：${value.status}`);
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

function noSecrets(value: Snapshot, secrets: string[]) {
  const serialized = JSON.stringify(value);
  for (const secret of secrets) expect(serialized).not.toContain(secret);
}

// Bun 的 pipe 分块、ANSI 控制序列和异步退出一起决定 UI 能否得到完整地址与码；真实子进程不能继承外部 Codex 凭据目录。
test('ChatGPT 登录拼接分块输出并隔离凭据目录，成功快照只返回授权信息', async () => {
  const root = temp('kite-subscription-login-chatgpt-');
  const secret = 'sk-login-output-must-not-escape';
  const command = fixture(root, 'chatgpt', [
    output(2, `access_token=${secret}\nhttps://unrelated.test/${secret}\n`),
    output(1, '\u001b[36mhttps://auth.open'),
    'await gate("url-prefix", { codexHome: process.env.CODEX_HOME, marker: process.env.KITE_LOGIN_TEST_ENV });',
    output(1, 'ai.com/codex/device\u001b[0m\n\u001b[1mABCD-'),
    'await gate("code-prefix");',
    output(1, 'EFGH\u001b[0m\n'),
    'await gate("authorized");',
    'process.exit(0);',
  ].join('\n'));
  const logins = new SubscriptionLogins(root, {
    command: async () => command,
    env: { ...ENV(), KITE_LOGIN_TEST_ROOT: root, KITE_LOGIN_TEST_ENV: '显式隔离环境', CODEX_HOME: '/不得继承的目录' },
  });
  const id = crypto.randomUUID();
  try {
    expect(logins.start('chatgpt', id)).toMatchObject({ id, provider: 'chatgpt', status: 'starting', acceptsCode: false });
    const prefix = await marker(root, 'url-prefix');
    expect(prefix.data).toEqual({ codexHome: join(root, 'auth', 'chatgpt'), marker: '显式隔离环境' });
    expect(logins.get(id).url).toBeUndefined();
    noSecrets(logins.get(id), [secret]);
    process.kill(prefix.pid, 'SIGUSR1');
    await marker(root, 'code-prefix');
    const addressed = await snapshot(logins, id, (value) => value.url !== undefined);
    expect(addressed.url).toBe('https://auth.openai.com/codex/device');
    expect(addressed.userCode).toBeUndefined();
    process.kill(prefix.pid, 'SIGUSR1');
    await marker(root, 'authorized');
    const waiting = await snapshot(logins, id, (value) => value.userCode !== undefined);
    expect(waiting).toMatchObject({ status: 'waiting', userCode: 'ABCD-EFGH', acceptsCode: false });
    expect(waiting.expiresAt).toBeGreaterThan(Date.now() / 1000);
    noSecrets(waiting, [secret]);
    process.kill(prefix.pid, 'SIGUSR1');
    const complete = await snapshot(logins, id, (value) => value.status === 'complete');
    noSecrets(complete, [secret]);
  } finally { await logins.close(); }
}, 1000);

// 原生登录经 stdout 发出地址、stdin 收取授权码；换行与进程失败需要实际 pipe 验证，不能只检查参数映射。
test('Claude 登录仅接受单行授权码，进程非零退出不泄漏原始输出', async () => {
  const root = temp('kite-subscription-login-claude-');
  const secret = 'claude-raw-token-must-not-escape';
  const code = 'valid-authorization-code';
  const command = fixture(root, 'claude', [
    output(1, '\u001b[32mhttps://claude.com/cai/oauth/authorize?state=test\u001b[0m\n'),
    'await gate("addressed");',
    'let input = "";',
    'for await (const bytes of Bun.stdin.stream()) {',
    '  input += new TextDecoder().decode(bytes);',
    '  if (input.includes("\\n")) break;',
    '}',
    'await gate("received", { input });',
    output(2, `登录失败：access_token=${secret}\n`),
    'process.exit(7);',
  ].join('\n'));
  const logins = new SubscriptionLogins(root, {
    command: async () => command,
    env: { ...ENV(), KITE_LOGIN_TEST_ROOT: root },
  });
  const id = crypto.randomUUID();
  try {
    logins.start('claude', id);
    const addressed = await marker(root, 'addressed');
    const waiting = await snapshot(logins, id, (value) => value.status === 'waiting');
    expect(waiting).toMatchObject({ url: 'https://claude.com/cai/oauth/authorize?state=test', acceptsCode: true });
    for (const invalid of ['first\nsecond', 'first\rsecond', `${code}\n`]) {
      expect(() => logins.submit(id, invalid)).toThrow();
    }
    logins.submit(id, code);
    process.kill(addressed.pid, 'SIGUSR1');
    const received = await marker(root, 'received');
    expect(received.data.input).toBe(`${code}\n`);
    process.kill(received.pid, 'SIGUSR1');
    const failed = await snapshot(logins, id, (value) => value.status === 'failed');
    expect(failed.acceptsCode).toBe(false);
    expect(failed.message).toBeTruthy();
    noSecrets(failed, [secret, code]);
  } finally { await logins.close(); }
}, 1000);

// SIGTERM、stdout EOF 与退出回调会并发到达；取消中仍须阻止写同一凭据的重叠进程，旧流程和先到的取消不能影响重试。
test('取消等待进程退出并阻止重叠登录，完成后重试与旧流程隔离', async () => {
  const root = temp('kite-subscription-login-cancel-');
  const secret = 'cancelled-process-token-must-not-escape';
  const oldCommand = fixture(root, 'old', [
    'process.on("SIGTERM", () => {',
    output(1, `access_token=${secret}\n`),
    '  void gate("old-stopping").then(() => process.exit(0));',
    '});',
    output(1, 'https://claude.com/cai/oauth/authorize?state=old\n'),
    'await gate("old-waiting");',
  ].join('\n'));
  const newCommand = fixture(root, 'retry', [
    output(1, 'https://claude.com/cai/oauth/authorize?state=retry\n'),
    'await gate("retry-waiting");',
    'let input = "";',
    'for await (const bytes of Bun.stdin.stream()) {',
    '  input += new TextDecoder().decode(bytes);',
    '  if (input.includes("\\n")) break;',
    '}',
    'await gate("retry-received", { input });',
    'process.exit(0);',
  ].join('\n'));
  let starts = 0;
  const logins = new SubscriptionLogins(root, {
    command: async () => starts++ === 0 ? oldCommand : newCommand,
    env: { ...ENV(), KITE_LOGIN_TEST_ROOT: root },
  });
  const oldId = crypto.randomUUID();
  const retryId = crypto.randomUUID();
  try {
    logins.start('claude', oldId);
    const old = await marker(root, 'old-waiting');
    await snapshot(logins, oldId, (value) => value.status === 'waiting');
    const cancelling = logins.cancel(oldId);
    const stopping = await marker(root, 'old-stopping');
    expect(() => process.kill(old.pid, 0)).not.toThrow();
    let blocked: unknown;
    try { logins.start('claude', crypto.randomUUID()); }
    catch (error) { blocked = error; }
    expect(blocked).toMatchObject({ status: 409 });
    expect(starts).toBe(1);
    process.kill(stopping.pid, 'SIGUSR1');
    await cancelling;
    expect(() => process.kill(old.pid, 0)).toThrow();
    expect(logins.get(oldId)).toMatchObject({ status: 'cancelled', acceptsCode: false });
    noSecrets(logins.get(oldId), [secret]);
    logins.start('claude', retryId);
    const retry = await marker(root, 'retry-waiting');
    const waiting = await snapshot(logins, retryId, (value) => value.status === 'waiting');
    expect(waiting.url).toBe('https://claude.com/cai/oauth/authorize?state=retry');
    expect(() => logins.submit(oldId, 'stale-code')).toThrow();
    logins.submit(retryId, 'retry-code');
    process.kill(retry.pid, 'SIGUSR1');
    const received = await marker(root, 'retry-received');
    expect(received.data.input).toBe('retry-code\n');
    process.kill(received.pid, 'SIGUSR1');
    await snapshot(logins, retryId, (value) => value.status === 'complete');
    expect(logins.get(oldId).status).toBe('cancelled');
    noSecrets(logins.get(oldId), [secret]);
    noSecrets(logins.get(retryId), [secret, 'stale-code']);
    const cancelledBeforeStart = crypto.randomUUID();
    await logins.cancel(cancelledBeforeStart);
    expect(logins.start('claude', cancelledBeforeStart)).toMatchObject({
      id: cancelledBeforeStart, provider: 'claude', status: 'cancelled', acceptsCode: false,
    });
    await logins.close();
    expect(starts).toBe(2);
  } finally { await logins.close(); }
}, 1000);
