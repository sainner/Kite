#!/usr/bin/env bun
/** kite 命令行：kited 的薄客户端，第 2 步没有界面时用它走通流程。 */
import { resolve } from 'node:path';

const BASE = process.env.KITE_URL ?? `http://127.0.0.1:${process.env.KITE_PORT ?? 5483}`;

const USAGE = `用法：
  kite projects                       列出项目
  kite add <文件夹>                   登记项目
  kite ls [项目]                      列出会话
  kite new <项目> <消息>              开新会话，跟到这一轮结束
  kite send <会话> <消息>             发消息，跟到这一轮结束
  kite follow [会话]                  一直跟事件
  kite interrupt <会话>               打断当前回合
  kite snapshots <会话>               列出快照
  kite restore <会话> <快照>          把工作树恢复到某一枚快照
  kite adopt <会话>                   把会话的改动合回主线
  kite archive <会话> [--force]       归档会话，删掉工作树`;

function unreachable(): never {
  console.error(`连不上 kited（${BASE}）`);
  process.exit(1);
}

async function call(method: string, path: string, body?: unknown): Promise<any> {
  const r = await fetch(BASE + path, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }).catch(unreachable);
  const j: any = await r.json();
  if (!r.ok) { console.error(j.error); process.exit(1); }
  return j;
}

function brief(input: any): string {
  const v = input?.command ?? input?.file_path ?? input?.pattern ?? input?.description ?? JSON.stringify(input);
  return String(v).split('\n')[0]!.slice(0, 100);
}

function print(e: any): void {
  switch (e.type) {
    case 'sdk': {
      const m = e.message;
      if (m.type === 'assistant') {
        for (const b of m.message.content) {
          if (b.type === 'text') console.log(b.text);
          else if (b.type === 'tool_use') console.log(`→ ${b.name} ${brief(b.input)}`);
        }
      } else if (m.type === 'result') {
        console.log(`· ${m.subtype}，${(m.duration_ms / 1000).toFixed(1)} 秒${m.total_cost_usd ? `，$${m.total_cost_usd.toFixed(4)}` : ''}`);
      } else if (m.type === 'system' && m.subtype === 'init') {
        console.log(`· Claude Code ${m.claude_code_version}，${m.model}`);
      }
      break;
    }
    case 'status': console.log(`· 会话状态：${e.status}`); break;
    case 'runner': console.log(`· 进程：${e.state}${e.error ? `\n${e.error}` : ''}`); break;
    case 'setup':
      console.log(e.exit === null ? '· 没有初始化脚本' : `· 初始化脚本退出码 ${e.exit}${e.exit ? `\n${e.log}` : ''}`);
      break;
    case 'snapshot': console.log(`· 快照 ${e.commit.slice(0, 8)}，${e.changedFiles} 个文件：${e.label}`); break;
    case 'adopt': printAdopt(e.result); break;
    case 'idle': console.log('· 回合结束'); break;
    case 'error': console.log(`! ${e.message}`); break;
  }
}

function printAdopt(r: any): void {
  if (r.status === 'adopted') console.log(`· 已合回主线：${r.commit.slice(0, 8)}`);
  else console.log(`· 合并冲突，已交给 agent 解决：${r.files.join('、')}`);
}

/**
 * 订阅事件流，连上之后执行 action（它返回要跟的会话 id），打印这个会话的事件，直到 stop 返回 true。
 * 先订阅再执行，事件不会漏。事先知道会话 id 时传 known，只订阅这个会话。
 */
async function follow(action: () => Promise<string | undefined>, stop: (e: any) => boolean = () => false, known?: string): Promise<void> {
  const res = await fetch(`${BASE}/events${known ? `?session=${encodeURIComponent(known)}` : ''}`).catch(unreachable);
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let session: string | undefined;
  let decided = false;
  const early: any[] = [];
  const handle = (e: any): boolean => {
    if (session && e.session !== session) return false;
    print(e);
    return stop(e);
  };
  let buf = '';
  let acted = false;
  while (true) {
    const { value, done } = await reader.read();
    if (done) return;
    buf += value;
    let i: number;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i);
      buf = buf.slice(i + 2);
      if (chunk.startsWith(': connected') && !acted) {
        acted = true;
        void action().then((id) => {
          session = id;
          decided = true;
          for (const e of early.splice(0)) if (handle(e)) process.exit(0);
        });
        continue;
      }
      const data = chunk.split('\n').find((l) => l.startsWith('data: '));
      if (!data) continue;
      const e = JSON.parse(data.slice(6));
      if (!decided) { early.push(e); continue; }
      if (handle(e)) process.exit(0);
    }
  }
}

const turnOver = (e: any) => e.type === 'idle' || (e.type === 'status' && e.status === 'prepare_failed');

const [cmd, ...args] = process.argv.slice(2);
const need = (n: number) => { if (args.length < n) { console.log(USAGE); process.exit(1); } };

switch (cmd) {
  case 'projects':
    for (const p of await call('GET', '/projects')) console.log(`${p.id}\t${p.commits === 'kite' ? 'Kite 代管提交' : '用户仓库'}\t${p.path}`);
    break;
  case 'add': {
    need(1);
    const p = await call('POST', '/projects', { path: resolve(args[0]!) });
    console.log(`已登记 ${p.id}：${p.path}`);
    break;
  }
  case 'ls':
    for (const s of await call('GET', `/sessions${args[0] ? `?project=${args[0]}` : ''}`)) {
      console.log(`${s.id}\t${s.projectId}\t${s.status}${s.busy ? '，工作中' : ''}\t${s.title}`);
    }
    break;
  case 'new':
    need(2);
    await follow(async () => {
      const s = await call('POST', '/sessions', { project: args[0], prompt: args.slice(1).join(' ') });
      console.log(`· 会话 ${s.id}，工作树 ${s.worktree}`);
      return s.id;
    }, turnOver);
    break;
  case 'send':
    need(2);
    await follow(async () => { await call('POST', `/sessions/${args[0]}/messages`, { text: args.slice(1).join(' ') }); return args[0]; }, turnOver, args[0]);
    break;
  case 'follow':
    await follow(async () => args[0], undefined, args[0]);
    break;
  case 'interrupt':
    need(1);
    await call('POST', `/sessions/${args[0]}/interrupt`);
    break;
  case 'snapshots':
    need(1);
    for (const s of await call('GET', `/sessions/${args[0]}/snapshots`)) {
      console.log(`${s.commit.slice(0, 8)}\t${new Date(s.at).toLocaleString('zh-CN')}\t${s.label}`);
    }
    break;
  case 'restore':
    need(2);
    await call('POST', `/sessions/${args[0]}/restore`, { commit: args[1] });
    console.log('· 已恢复');
    break;
  case 'adopt': {
    need(1);
    let conflicts = 0;
    // 冲突时 kited 把冲突交给 agent，它这一轮结束后自动重试；跟到合回主线，或第二次冲突为止
    await follow(async () => { await call('POST', `/sessions/${args[0]}/adopt`); return args[0]; },
      (e) => e.type === 'error' || (e.type === 'adopt' && (e.result.status === 'adopted' || ++conflicts > 1)), args[0]);
    break;
  }
  case 'archive':
    need(1);
    await call('POST', `/sessions/${args[0]}/archive`, { force: args.includes('--force') });
    console.log('· 已归档');
    break;
  default:
    console.log(USAGE);
}
