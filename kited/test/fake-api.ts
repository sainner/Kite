/**
 * 假的 Anthropic Messages 端点：用预设回复驱动真实的 Claude Code，不调模型、不耗额度。
 * 整个测试进程共用一个，由 test/setup.ts 启动。
 *
 * 主循环请求（带 tools）按最后一条用户消息决定回复：
 *  - 含 tool_result          → 结束回合，回一句「工具完成」；
 *  - PAR <命令1> ;; <命令2>   → 一次回复里并行调两个 Bash；
 *  - CALL <工具名> <JSON 对象> → 以这个 JSON 为参数调一次该工具（名字照请求 tools 里的写，比如 check）；
 *  - RUN <命令>               → 调一次 Bash 执行这条命令；
 *  - BG <标记>                → 后台 Bash，一直等到测试调 release(标记) 才结束；
 *  - 含「冲突」               → 用 Bash 以会话分支一侧解决冲突并提交（模拟 agent 解决合并冲突）；
 *  - HOLD <标记>              → 这次请求挂起，测试调 release(标记) 后回显；用来让 agent 保持「正在工作」；
 *  - 其他                     → 回显。
 * 其他请求（标题生成之类，不带 tools）一律回一句短文本。
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export interface Logged {
  at: number;
  /** 主循环请求（带 tools）。 */
  main: boolean;
  body: any;
  /** 最后一条用户消息里的文本。 */
  lastUserText: string;
  hasToolResult: boolean;
  /** 这次回复里发出的 tool_use id。 */
  toolUseIds: string[];
  /** 因 HOLD 挂起过的标记。 */
  hold?: string;
}

export interface FakeApi {
  url: string;
  log: Logged[];
  /** 等到满足条件的请求（已收到的也算）。 */
  waitRequest(pred: (l: Logged) => boolean, timeoutMs?: number): Promise<Logged>;
  /** 等到有一次请求因 HOLD <标记> 挂起（已挂起的也算），即 agent 正在工作。 */
  held(tag: string, timeoutMs?: number): Promise<Logged>;
  /** 放行：HOLD <标记> 挂着的请求回显，BG <标记> 的后台任务结束；之后同标记的请求不再挂起。 */
  release(tag: string): void;
  /** 放行所有挂着的请求和后台任务，测试收尾用。 */
  releaseAll(): void;
  /** 关掉端点，连同还开着的连接；等它关完再删 BG 放行标记所在的目录。 */
  stop(): Promise<void>;
}

function lastUser(body: any): { text: string; hasToolResult: boolean } {
  const msgs = body.messages ?? [];
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.role !== 'user') continue;
    if (typeof m.content === 'string') return { text: m.content, hasToolResult: false };
    const blocks = m.content as any[];
    return {
      text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join('\n'),
      hasToolResult: blocks.some((b) => b.type === 'tool_result'),
    };
  }
  return { text: '', hasToolResult: false };
}

let seq = 0;
function sse(model: string, content: any[], stop: string): string {
  const ev: Array<[string, unknown]> = [[
    'message_start',
    { type: 'message_start', message: { id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } },
  ]];
  content.forEach((block, index) => {
    if (block.type === 'text') {
      ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } }]);
      ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text: block.text } }]);
    } else {
      ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } }]);
      ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }]);
    }
    ev.push(['content_block_stop', { type: 'content_block_stop', index }]);
  });
  ev.push(['message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } }]);
  ev.push(['message_stop', { type: 'message_stop' }]);
  return ev.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join('');
}

const toolUse = (name: string, input: unknown) => ({ type: 'tool_use', id: `toolu_fake_${++seq}`, name, input });
const bash = (command: string, extra: Record<string, unknown> = {}) => toolUse('Bash', { command, description: 'fake', ...extra });

/** 把会话分支一侧的版本当作冲突的解决结果并提交。 */
const RESOLVE = 'git checkout --ours -- . && git add -A && git -c user.name=agent -c user.email=agent@example.com commit -q --no-edit';

/** dir：放 BG 放行标记文件的目录。 */
export function startFakeApi(dir: string): FakeApi {
  mkdirSync(dir, { recursive: true });
  const log: Logged[] = [];
  const waiters: Array<{ pred: (l: Logged) => boolean; resolve: (l: Logged) => void }> = [];
  const released = new Set<string>();
  const holding = new Map<string, Array<() => void>>();
  const background = new Set<string>();

  const notify = (l: Logged) => {
    for (const w of [...waiters]) if (w.pred(l)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(l); }
  };

  function waitRequest(pred: (l: Logged) => boolean, timeoutMs = 10_000): Promise<Logged> {
    const hit = log.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve: (l: Logged) => { clearTimeout(t); resolve(l); } };
      const t = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('等待假端点的请求超时')); }, timeoutMs);
      waiters.push(w);
    });
  }

  function release(tag: string) {
    released.add(tag);
    writeFileSync(join(dir, tag), '');
    background.delete(tag);
    for (const go of holding.get(tag) ?? []) go();
    holding.delete(tag);
  }

  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method !== 'POST') return Response.json({}, { status: 404 });
      const body: any = await req.json().catch(() => ({}));
      if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
      if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
      const main = Array.isArray(body.tools) && body.tools.length > 0;
      const { text, hasToolResult } = lastUser(body);
      const model = body.model ?? 'claude-fake';
      let content: any[] = [{ type: 'text', text: 'ok' }];
      let stop = 'end_turn';
      let hold: string | undefined;
      if (main) {
        let m: RegExpExecArray | null;
        if (hasToolResult) content = [{ type: 'text', text: '工具完成' }];
        else if ((m = /PAR (.+?) ;; (.+)$/m.exec(text))) { content = [bash(m[1]!), bash(m[2]!)]; stop = 'tool_use'; }
        else if ((m = /CALL (\S+) (\{.*\})$/m.exec(text))) { content = [toolUse(m[1]!, JSON.parse(m[2]!))]; stop = 'tool_use'; }
        else if ((m = /RUN (.+)$/m.exec(text))) { content = [bash(m[1]!)]; stop = 'tool_use'; }
        else if ((m = /BG (\S+)/.exec(text))) {
          background.add(m[1]!);
          const flag = join(dir, m[1]!);
          content = [bash(`until [ -e '${flag}' ]; do sleep 0.02; done; echo bg-done`, { run_in_background: true })];
          stop = 'tool_use';
        }
        else if (text.includes('冲突')) { content = [bash(RESOLVE)]; stop = 'tool_use'; }
        else {
          if ((m = /HOLD (\S+)/.exec(text)) && !released.has(m[1]!)) hold = m[1]!;
          content = [{ type: 'text', text: `echo: ${text.slice(-60)}` }];
        }
      }
      const entry: Logged = {
        at: Date.now(), main, body, lastUserText: text, hasToolResult,
        toolUseIds: content.filter((b) => b.type === 'tool_use').map((b) => b.id), hold,
      };
      log.push(entry);
      if (hold) {
        const tag = hold;
        const go = new Promise<void>((resolve) => holding.set(tag, [...(holding.get(tag) ?? []), resolve]));
        notify(entry);
        await go;
      } else {
        notify(entry);
      }
      if (body.stream === false) {
        return Response.json({ id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content, stop_reason: stop, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 5 } });
      }
      return new Response(sse(model, content, stop), { headers: { 'content-type': 'text/event-stream' } });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    log,
    waitRequest,
    held: (tag, timeoutMs) => waitRequest((l) => l.hold === tag, timeoutMs),
    release,
    releaseAll() { for (const tag of [...holding.keys(), ...background]) release(tag); },
    stop: () => server.stop(true),
  };
}
