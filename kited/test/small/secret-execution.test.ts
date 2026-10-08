import { expect, test } from 'bun:test';
import { createReadStream, createWriteStream, existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { localTools } from '../../src/execution/local-tools.ts';
import type { Json, ToolResult } from '../../src/harness/types.ts';
import { deferred } from '../harness-loop.ts';
import { ENV, useTemp } from '../util.ts';

const temp = useTemp();
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
type Tools = ReturnType<typeof localTools>;
type Secret = { reference: string; kind: 'text' | 'file'; value: string };

async function shell(tools: Tools, cwd: string, command: string, secrets?: Record<string, string>,
  signal = new AbortController().signal, output?: (text: string, limit: number) => void): Promise<ToolResult> {
  const tool = tools.find((candidate) => candidate.name === 'shell');
  if (!tool) throw new Error('缺少 shell 工具');
  const args: Json = { description: '验证凭据命令', command, ...(secrets ? { secrets } : {}) };
  tool.validate(args);
  return tool.execute(args, { cwd, signal, output });
}

function logContents(directory: string): string {
  if (!existsSync(directory)) return '';
  return readdirSync(directory, { recursive: true }).flatMap((entry) => {
    const path = join(directory, String(entry));
    try { return [readFileSync(path, 'utf8')]; } catch { return []; }
  }).join('\n');
}

// Bun.spawn 显式环境与真实文件权限必须运行确认：引号/命令替换保持字面值，文件路径交给子进程后及时删除。
test('真实命令只从环境取得文本和 0600 凭据文件，退出后文件删除且下次命令不继承凭据', async () => {
  const root = temp('secret-env-');
  const value = '字面密钥\'" $(touch injected)\n第二行-97fa1b';
  const fileValue = '-----BEGIN TEST KEY-----\n临时文件假秘密-4583b2\n-----END TEST KEY-----\n';
  const fixture = join(root, 'probe.ts');
  const observation = join(root, 'observation.json');
  writeFileSync(fixture, [
    'import { readFileSync, statSync, writeFileSync } from "node:fs";',
    'const path = process.env.KITE_SECRET_SSH!;',
    'writeFileSync("observation.json", JSON.stringify({',
    '  text: process.env.KITE_SECRET_TOKEN, path, contents: readFileSync(path, "utf8"),',
    '  mode: statSync(path).mode & 0o777, argv: process.argv,',
    '}));',
  ].join('\n'));
  const tools = localTools({
    cwd: root, logDir: join(root, 'logs'), env: ENV(),
    secrets: { async resolve() {
      return [
        { reference: '{account.api_key}', kind: 'text', value },
        { reference: '{project.ssh_key}', kind: 'file', value: fileValue },
      ];
    } },
  });
  const result = await shell(tools, root, `exec ${quote(process.execPath)} ${quote(fixture)}`,
    { KITE_SECRET_TOKEN: '{account.api_key}', KITE_SECRET_SSH: '{project.ssh_key}' });
  expect(result.status).toBe('success');
  expect(result.output).toContain('凭据命令的输出已隐藏');
  const observed = JSON.parse(readFileSync(observation, 'utf8'));
  expect(observed.text).toBe(value);
  expect(observed.contents).toBe(fileValue);
  expect(observed.mode).toBe(0o600);
  expect(typeof observed.path).toBe('string');
  expect(observed.path).not.toBe(fileValue);
  expect(existsSync(observed.path)).toBe(false);
  expect(JSON.stringify(observed.argv)).not.toContain(value);
  expect(JSON.stringify(observed.argv)).not.toContain(fileValue);
  expect(existsSync(join(root, 'injected'))).toBe(false);
  const ordinary = await shell(tools, root,
    'test -z "${KITE_SECRET_TOKEN+x}" && test -z "${KITE_SECRET_SSH+x}" && printf "普通命令已执行"');
  expect(ordinary.status).toBe('success');
  expect(ordinary.output).toContain('普通命令已执行');
  expect(logContents(join(root, 'logs'))).not.toContain(value);
  expect(logContents(join(root, 'logs'))).not.toContain(fileValue);
}, 1_000);

// 真实 stdout/stderr 管道会分段解码和截断；用工作区 FIFO 卡住两段之间，任何编码的输出都不能进入回调、结果或日志。
test('凭据命令的分段中文、编码输出和超限输出在成功与失败时均完全隐藏', async () => {
  const root = temp('secret-output-');
  const value = '密钥跨段假秘密-45bca2';
  const readyPath = join(root, 'ready.pipe');
  const releasePath = join(root, 'release.pipe');
  const pipes = Bun.spawnSync(['mkfifo', readyPath, releasePath], { env: ENV(), stdout: 'pipe', stderr: 'pipe' });
  expect(pipes.exitCode).toBe(0);
  const reader = createReadStream(readyPath, { flags: 'r+' });
  let writer: ReturnType<typeof createWriteStream> | undefined;
  const ready = new Promise<void>((resolve, reject) => {
    reader.once('data', () => resolve());
    reader.once('error', reject);
  });
  const fixture = join(root, 'output.ts');
  writeFileSync(fixture, [
    'import { readFileSync, writeFileSync, writeSync } from "node:fs";',
    'const bytes = Buffer.from(process.env.KITE_SECRET_TOKEN!);',
    'writeSync(1, bytes.subarray(0, 1));',
    `writeFileSync(${JSON.stringify(readyPath)}, "首段已写入");`,
    `readFileSync(${JSON.stringify(releasePath)});`,
    'writeSync(1, bytes.subarray(1));',
    'process.stderr.write(bytes.toString("base64"));',
    'process.stdout.write("超限输出不应外泄".repeat(2048));',
  ].join('\n'));
  const contextOutput: string[] = [];
  const optionsOutput: string[] = [];
  const logDir = join(root, 'logs');
  const tools = localTools({
    cwd: root, logDir, env: ENV(), outputLimit: 32,
    onOutput(text) { optionsOutput.push(text); },
    secrets: { async resolve() { return [{ reference: '{account.api_key}', kind: 'text', value }]; } },
  });
  let running: Promise<ToolResult> | undefined;
  const controller = new AbortController();
  let phase = '等待首段输出后的事件';
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    running = shell(tools, root, `exec ${quote(process.execPath)} ${quote(fixture)}`,
      { KITE_SECRET_TOKEN: '{account.api_key}' }, controller.signal, (text) => contextOutput.push(text));
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error(`输出测试未完成：${phase}`)); }, 800);
    });
    await Promise.race([ready, deadline,
      running.then((result) => { throw new Error(`事件到达前命令退出：${JSON.stringify(result)}`); })]);
    expect(contextOutput).toEqual([]);
    expect(optionsOutput).toEqual([]);
    writer = createWriteStream(releasePath);
    writer.end('继续');
    phase = '首段事件已收到，等待命令退出';
    const success = await Promise.race([running, deadline]);
    const failure = await shell(tools, root, 'printf "%s" "$KITE_SECRET_TOKEN" >&2; exit 9',
      { KITE_SECRET_TOKEN: '{account.api_key}' }, undefined, (text) => contextOutput.push(text));
    expect(success.status).toBe('success');
    expect(failure.status).toBe('error');
    expect(success.output).toContain('退出码：0');
    expect(failure.output).toContain('退出码：9');
    for (const result of [success, failure]) expect(result.output).toContain('凭据命令的输出已隐藏');
    expect(contextOutput).toEqual([]);
    expect(optionsOutput).toEqual([]);
    const exposed = [success.output, failure.output, logContents(logDir)].join('\n');
    for (const privateText of [value, Buffer.from(value).toString('base64'), '超限输出不应外泄']) {
      expect(exposed).not.toContain(privateText);
    }
  } finally {
    clearTimeout(timer);
    controller.abort();
    writer?.end();
    await running?.catch(() => undefined);
    reader.destroy();
    writer?.destroy();
  }
}, 1_000);

// 凭据 HTTP 请求与命令启动的交接必须实际执行：请求失败、预先取消、取值期间取消都不能产生命令副作用。
test('解析失败或取值期间取消均不启动命令，随后普通命令仍能执行且没有凭据残留', async () => {
  const root = temp('secret-abort-');
  const started = deferred();
  const resolved = deferred<Secret[]>();
  let mode: 'fail' | 'hold' = 'fail';
  const processes: Array<{ pid: number; active: boolean }> = [];
  const output: string[] = [];
  const tools = localTools({
    cwd: root, logDir: join(root, 'logs'), env: ENV(),
    onProcess(pid, active) { processes.push({ pid, active }); },
    secrets: { async resolve() {
      if (mode === 'fail') throw new Error('测试解析失败');
      started.resolve();
      return resolved.promise;
    } },
  });
  const bindings = { KITE_SECRET_TOKEN: '{account.api_key}' };
  const rejected = async (operation: Promise<ToolResult>) => {
    const result = await operation.catch(() => ({ status: 'error', output: '' }));
    expect(result.status).not.toBe('success');
  };
  await rejected(shell(tools, root, 'printf started > failed-command', bindings,
    undefined, (text) => output.push(text)));
  const alreadyCancelled = new AbortController();
  alreadyCancelled.abort();
  await rejected(shell(tools, root, 'printf started > pre-aborted-command', bindings, alreadyCancelled.signal));

  mode = 'hold';
  const controller = new AbortController();
  const pending = shell(tools, root, 'printf started > cancelled-command', bindings, controller.signal);
  await started.promise;
  controller.abort();
  resolved.resolve([{ reference: '{account.api_key}', kind: 'text', value: '取消后不得使用的假秘密-214fa1' }]);
  await rejected(pending);
  expect(processes).toEqual([]);
  expect(output).toEqual([]);
  for (const marker of ['failed-command', 'pre-aborted-command', 'cancelled-command']) {
    expect(existsSync(join(root, marker))).toBe(false);
  }
  const ordinary = await shell(tools, root, 'test -z "${KITE_SECRET_TOKEN+x}" && printf "取消后的普通命令"');
  expect(ordinary.status).toBe('success');
  expect(ordinary.output).toContain('取消后的普通命令');
}, 1_000);
