#!/usr/bin/env bun
/** 自研 harness 的独立终端入口；不启动 kited 或 Claude Code。 */
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { basename, isAbsolute, join, resolve } from 'node:path';
import { createInterface, type Interface } from 'node:readline';
import { parseArgs } from 'node:util';
import { defaultAuthFile, readSubscriptionCredentials } from './harness/auth.ts';
import { CHATGPT_CONTEXT_WINDOW, ChatGPTModel } from './harness/chatgpt.ts';
import { openThreadHost, readThreadMetadata } from './harness/thread-host.ts';
import { harnessPolicy } from './execution/policy.ts';
import { projectContext } from './harness/context/project.ts';
import type { HarnessEvent } from './harness/types.ts';
import { defaultAgentModel } from './agents/models.ts';

const USAGE = `用法：
  bun run harness --cwd <目录>                     开始对话
  bun run harness --cwd <目录> --prompt "任务"      完成一轮后退出
  bun run harness --resume <会话 id 或绝对路径>     恢复已有会话

选项：
  --model <名称>         默认 ${defaultAgentModel}，可用 KITE_MODEL 设置
  --reasoning <强度>     默认 medium
  --auth <文件>         ChatGPT 登录凭据，默认 $KITE_HOME/auth/chatgpt/auth.json（KITE_HOME 默认 ~/.kite）
  --max-requests <次数>  每回合请求预算，默认 50

对话命令：/status /stop /resume /recover /exit
工作过程中直接输入可以插话；Ctrl+C 停止执行并退回队列，空闲时退出。
会话存在 $KITE_HOME/sessions（默认 ~/.kite/sessions）；命令直接操作指定目录。`;

export async function runHarnessCLI(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, strict: true, options: {
    cwd: { type: 'string' }, prompt: { type: 'string' }, resume: { type: 'string' },
    model: { type: 'string' }, reasoning: { type: 'string' }, auth: { type: 'string' },
    'max-requests': { type: 'string' }, help: { type: 'boolean', short: 'h' },
  } });
  if (values.help) { console.log(USAGE); return 0; }
  const home = resolve(process.env.KITE_HOME ?? join(homedir(), '.kite'));
  const id = values.resume ?? `terminal-${randomUUID().slice(0, 12)}`;
  if (!isAbsolute(id) && !/^[A-Za-z0-9_-]+$/.test(id)) throw new Error('会话 id 只能包含字母、数字、下划线和连字符');
  const directory = isAbsolute(id) ? id : join(home, 'sessions', id);
  const saved = values.resume ? readThreadMetadata(directory) : undefined;
  if (values.resume && saved === undefined) throw new Error(`找不到会话：${id}`);
  const cwd = resolve(values.cwd ?? saved?.cwd ?? process.cwd());
  const modelName = values.model ?? saved?.settings?.model?.model ?? process.env.KITE_MODEL ?? defaultAgentModel;
  const reasoning = values.reasoning ?? saved?.settings?.model?.reasoning ?? 'medium';
  const maxRequests = Number(values['max-requests'] ?? saved?.settings?.maxRequestsPerTurn ?? 50);
  if (!Number.isSafeInteger(maxRequests) || maxRequests < 1) throw new Error('--max-requests 必须为正整数');
  // 启动时尽早发现登录问题，每次请求仍重新读取，以跟上独立认证目录的更新。
  await readSubscriptionCredentials(values.auth);
  const model = new ChatGPTModel({ model: modelName, reasoning, threadId: basename(directory),
    credentials: () => readSubscriptionCredentials(values.auth),
  });
  let rl: Interface | undefined;
  let textOpen = false;
  let lastWasBusy = false;
  let streamedRequestId: string | undefined;
  const line = (content: string) => {
    if (textOpen) { process.stdout.write('\n'); textOpen = false; }
    console.log(content);
  };
  const reportError = (error: unknown) => line(`! ${error instanceof Error ? error.message : String(error)}`);
  const render = (event: HarnessEvent) => {
    if (event.type === 'delta' && (event.field === undefined || event.field === 'text') && !event.replace) {
      streamedRequestId = event.requestId;
      process.stdout.write(event.text); textOpen = true;
    } else if (event.type === 'record') {
      const record = event.record;
      if (record.type === 'tool.started') line(`\n→ 工具 ${record.callId}`);
      if (record.type === 'model.item' && record.item.call) {
        line(`\n· ${record.item.call.name} ${JSON.stringify(record.item.call.arguments).slice(0, 200)}`);
      }
      if (record.type === 'model.item' && !record.item.call && streamedRequestId !== record.requestId) {
        const content = record.item.raw.content;
        if (Array.isArray(content)) {
          for (const part of content) if (part && typeof part === 'object' && !Array.isArray(part) && typeof part.text === 'string') line(part.text);
        }
      }
      if (record.type === 'context.compacted') line('\n· 已压缩上下文');
      if (record.type === 'tool.finished') line(`· 工具 ${record.result.status}\n${record.result.output.slice(-1200)}`);
      if (record.type === 'turn.finished') {
        const outcome = record.outcome;
        line(`\n· ${outcome.kind}${'message' in outcome ? `：${outcome.message}` : ''}`);
      }
    } else if (event.type === 'error') line(`! ${event.message}`);
    else if (event.type === 'state') {
      if (lastWasBusy && !event.state.busy) rl?.prompt();
      lastWasBusy = event.state.busy;
    }
  };
  const settings = { model: { model: modelName, reasoning }, contextWindow: CHATGPT_CONTEXT_WINDOW, maxRequestsPerTurn: maxRequests };
  const host = await openThreadHost({
    cwd, threadDir: directory, env: { ...process.env }, onEvent: render, settings,
    policy: await harnessPolicy({ cwd, env: process.env, home, authFile: resolve(values.auth ?? defaultAuthFile()) }),
    prepareRequest: (tools) => ({ model, tools, instructions: projectContext(cwd), settings }),
  });
  const status = () => line(JSON.stringify(host.runner.state, null, 2));
  line(`Kite · ${modelName} · ${reasoning}\n工作目录：${cwd}\n会话：${basename(directory)}\n记录：${directory}`);
  if (host.runner.state.recovery) line('上次执行结果未知。确认旧命令均已停止后输入 /recover，再输入 /resume。');
  const restoreInputs = (inputs: import('./harness/types.ts').Input[]) => {
    const text = inputs.map((input) => input.text).join('\n\n');
    // readline.write 会将换行当作重新提交，退回内容只打印，留给用户重新编辑。
    if (text) { line(`已退回，编辑后可重新发送：\n${text}`); rl?.prompt(true); }
  };
  let exiting = false;
  let signalWork: Promise<void> = Promise.resolve();
  const stop = () => {
    signalWork = (async () => {
      if (host.runner.state.busy && !host.runner.state.recovery) {
        restoreInputs(await host.runner.interrupt());
      } else {
        exiting = true; rl?.close(); await host.close();
      }
    })().catch(reportError);
  };
  process.on('SIGINT', stop);
  const terminate = () => {
    exiting = true; rl?.close();
    signalWork = host.close().catch(reportError);
  };
  process.once('SIGTERM', terminate);
  try {
    if (values.prompt !== undefined) {
      await host.runner.send({ id: randomUUID(), text: values.prompt, source: 'human' });
      await host.runner.settled();
    } else {
      rl = createInterface({ input: process.stdin, output: process.stdout, terminal: !!process.stdin.isTTY, prompt: '\n你> ' });
      const pending = new Set<Promise<void>>();
      const command = async (text: string) => {
        if (!text.trim() || exiting) return;
        switch (text.trim()) {
          case '/status': status(); break;
          case '/stop': restoreInputs(await host.runner.interrupt()); break;
          case '/resume': await host.runner.resume(); break;
          case '/recover': await host.confirmRecovery(); status(); break;
          case '/exit': exiting = true; rl?.close(); await host.close(); break;
          default: await host.runner.send({ id: randomUUID(), text, source: 'human' });
        }
      };
      const eof = new Promise<void>((resolveEOF) => rl!.once('close', resolveEOF));
      rl.on('SIGINT', stop);
      rl.on('line', (text) => {
        const action = command(text).catch(reportError);
        pending.add(action);
        void action.then(() => { pending.delete(action); if (!host.runner.state.busy && !exiting) rl?.prompt(); });
      });
      if (process.stdin.isTTY) rl.prompt();
      await eof;
      await Promise.all(pending);
      await host.runner.settled();
    }
    await signalWork;
    const outcome = host.runner.state.lastOutcome;
    return outcome?.kind === 'failed' || host.runner.state.recovery ? 1 : 0;
  } finally {
    process.off('SIGINT', stop);
    process.off('SIGTERM', terminate);
    rl?.close();
    await host.close();
  }
}

if (import.meta.main) {
  try { process.exitCode = await runHarnessCLI(); }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1; }
}
