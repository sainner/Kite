#!/usr/bin/env bun
/** kite 命令行：kited 的薄客户端，第 2 步没有界面时用它走通流程。 */
import { resolve } from 'node:path';
import QRCode from 'qrcode';
import type { EventScope } from './events.ts';

const BASE = process.env.KITE_URL ?? `http://127.0.0.1:${process.env.KITE_PORT ?? 5483}`;

const USAGE = `用法：
  kite projects                       列出项目
  kite add <文件夹> [项目]            登记检出，可关联已有项目
  kite checkouts [项目]               列出本机检出
  kite ls [项目]                      列出工作区和线程
  kite new <检出> <消息>              开新工作区，跟到这一轮结束
  kite send <线程> <消息>             发消息，跟到这一轮结束
  kite follow [线程]                  跟线程正文；省略时跟目录概要
  kite follow-workspace <工作区>      跟工作区操作事件
  kite interrupt <线程>               停止会话并退回排队消息
  kite resume <线程>                  继续等待中的线程
  kite recover <线程>                 确认旧执行已停止，随后用 resume 继续
  kite snapshots <工作区>               列出快照
  kite restore <工作区> <快照>          把工作树恢复到某一枚快照
  kite adopt <工作区>                   把工作区的改动合回主线
  kite archive <工作区> [--force]       归档工作区，删掉工作树
  kite net [up|down]                  查看、开启或关闭组网；首次开启后按提示登录
  kite net admin <API 密钥> [用户]    保存 headscale 管理密钥，之后入网不再经浏览器
  kite pair                           生成远程设备的配对二维码和一次性配对码
  kite devices                        列出已配对的远程设备
  kite revoke <设备>                  撤销设备授权并断开它的连接`;

function unreachable(): never {
  console.error(`连不上 kited（${BASE}）`);
  process.exit(1);
}

let targetMachine: Promise<string> | undefined;
function machine(): Promise<string> {
  return targetMachine ??= fetch(BASE + '/machine').catch(unreachable).then(async (response) => {
    const result = await response.json() as { id?: string; error?: string };
    if (!response.ok || !result.id) { console.error(result.error ?? '无法读取工作机身份'); process.exit(1); }
    return result.id;
  });
}

async function call(method: string, path: string, body?: unknown): Promise<any> {
  const r = await fetch(BASE + path, {
    method,
    headers: { 'X-Kite-Machine': await machine(), ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
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

const printedText = new Map<string, { text: string; parts: string[] }>();
const printedTools = new Map<string, string>();
const isPaused = (e: any): boolean => e.type === 'thread.state' && !e.state.busy && (e.state.waitingForResume || e.state.recovery);

function printText(key: string, parts: string[], text = parts.join('\n\n')): void {
  const previous = printedText.get(key)?.text ?? '';
  process.stdout.write(text.startsWith(previous) ? text.slice(previous.length) : `\n${text}`);
  printedText.set(key, { text, parts });
}

function print(e: any): void {
  switch (e.type) {
    case 'thread.record': {
      const r = e.record;
      const block = r.block;
      const key = `${e.threadId}:${r.id}`;
      if (block.type !== 'text') printedText.delete(key);
      if (block.type === 'text') {
        printText(key, block.parts ?? [block.text], block.text);
      } else if (block.type === 'tool_use') {
        const label = `${block.name} ${brief(block.input)}${block.stage ? ` · ${block.stage}` : ''}`;
        if (printedTools.get(key) !== label) { console.log(`\n→ ${label}`); printedTools.set(key, label); }
      }
      else if (block.type === 'tool_result') console.log(`· 工具 ${block.status}\n${block.output.slice(-1200)}`);
      else if (block.type === 'error') console.log(`! ${block.text}`);
      else if (block.type === 'interrupted') console.log('· 已打断');
      break;
    }
    case 'thread.record.delta': {
      const d = e.delta;
      const key = `${e.threadId}:${d.id}`;
      const record = printedText.get(key);
      if (d.field === 'text' && record) {
        const { parts } = record;
        const index = d.part ?? 0;
        while (parts.length <= index) parts.push('');
        parts[index] = d.replace ? d.text : parts[index]! + d.text;
        printText(key, parts);
      } else if (d.field === 'output') process.stdout.write(d.text);
      break;
    }
    case 'thread.state':
      if (e.state.status === 'failed') console.log(`! 工作区准备失败${e.state.error ? `：${e.state.error}` : ''}`);
      else if (e.state.status === 'archived') console.log('· 线程已归档');
      if (isPaused(e)) console.log(`· 会话 已停止，${e.state.recovery ? '确认旧执行停止后用 recover，再用 resume 继续' : '用 resume 继续'}`);
      break;
    case 'workspace.changed': console.log(`· 工作区 ${e.workspaceId}：${e.status}`); break;
    case 'thread.changed': console.log(`· 线程 ${e.threadId}：${e.status}`); break;
    case 'checkout.changed': console.log(`· 检出 ${e.checkoutId} 已更新`); break;
    case 'catalog.snapshot': console.log(`· 已连接，${e.workspaces.length} 个工作区`); break;
    case 'workspace.model': console.log(`· 工作区 ${e.workspaceId}：${e.model.workspace.status}`); break;
    case 'thread.history':
      for (const record of e.records) print({ type: 'thread.record', threadId: e.threadId, record });
      print({ type: 'thread.state', state: e.state });
      break;
    case 'workspace.setup':
      console.log(e.exit === null ? '· 没有初始化脚本' : `· 初始化脚本退出码 ${e.exit}${e.exit ? `\n${e.log}` : ''}`);
      break;
    case 'workspace.snapshot': console.log(`· 快照 ${e.commit.slice(0, 8)}，${e.changedFiles} 个文件：${e.label}`); break;
    case 'workspace.adopt': printAdopt(e.result); break;
    case 'thread.idle': console.log('\n· 回合结束'); break;
    case 'workspace.error':
    case 'thread.error': console.log(`! ${e.message}`); break;
  }
}

function printAdopt(r: any): void {
  if (r.status === 'adopted') console.log(`· 已合回主线：${r.commit.slice(0, 8)}`);
  else console.log(`· 合并冲突，已交给 agent 解决：${r.files.join('、')}`);
}

/** 已知线程先订阅再发控制请求；新建线程从首帧历史补齐连接前的输出。 */
async function follow(scope: EventScope, untilIdle = false, action?: () => Promise<{ id?: string } | void>): Promise<void> {
  const query = scope === 'catalog' ? '' : 'threadId' in scope
    ? `?thread=${encodeURIComponent(scope.threadId)}` : `?workspace=${encodeURIComponent(scope.workspaceId)}`;
  const res = await fetch(`${BASE}/events${query}`, { headers: { 'X-Kite-Machine': await machine() } }).catch(unreachable);
  if (!res.ok) { console.error((await res.json() as { error: string }).error); process.exit(1); }
  const reader = res.body!.pipeThrough(new TextDecoderStream()).getReader();
  let buf = '';
  let started = false;
  let inputId: string | undefined;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) throw new Error('事件连接提前断开');
      buf += value;
      let i: number;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const chunk = buf.slice(0, i);
        buf = buf.slice(i + 2);
        if (chunk.startsWith(': connected')) {
          if (action) inputId = (await action())?.id;
          continue;
        }
        const data = chunk.split('\n').find((l) => l.startsWith('data: '));
        if (!data) continue;
        const e = JSON.parse(data.slice(6));
        if (e.type === 'thread.history') {
          // send/resume 的初始 idle 属于控制请求之前，不能据此结束命令。
          if (!action) {
            print(e);
            started = e.records.length > 0 || e.pending.length > 0 || e.state.busy;
            if (untilIdle && (terminalState(e.state) || (started && e.state.phase === 'idle' && !e.state.busy && !e.pending.length))) return;
          }
          continue;
        }
        print(e);
        if (e.type === 'thread.state' && e.state.busy) started = true;
        if (inputId) {
          if ((e.type === 'thread.pending' && e.pending.some((p: { id: string }) => p.id === inputId))
            || (e.type === 'thread.record' && e.record.block.type === 'human' && e.record.block.id === inputId)) started = true;
        } else if (e.type === 'thread.record' || (e.type === 'thread.pending' && e.pending.length)) started = true;
        if (untilIdle && ((started && e.type === 'thread.idle')
          || (e.type === 'thread.state' && terminalState(e.state)) || e.type === 'thread.error')) return;
      }
    }
  } finally { await reader.cancel(); }
}

const terminalState = (state: any): boolean => ['failed', 'archived'].includes(state.status)
  || (!state.busy && (state.waitingForResume || !!state.recovery));

async function main(): Promise<void> {
  const [cmd, ...args] = process.argv.slice(2);
  const need = (n: number) => { if (args.length < n) { console.log(USAGE); process.exit(1); } };

  switch (cmd) {
    case 'projects':
      for (const p of await call('GET', '/projects')) console.log(`${p.id}\t${p.name}`);
      break;
    case 'add': {
      need(1);
      const project = args[1] ? (await call('GET', '/projects')).find((p: { id: string }) => p.id === args[1]) : undefined;
      if (args[1] && !project) { console.error('没有这个项目，请先用 kite projects 查看'); process.exit(1); }
      const m = await call('POST', '/checkouts', { path: resolve(args[0]!), project });
      console.log(`已登记 ${m.project.name}：${m.checkout.path}\n检出 ${m.checkout.id}`);
      break;
    }
    case 'checkouts':
      for (const c of await call('GET', `/checkouts${args[0] ? `?project=${encodeURIComponent(args[0])}` : ''}`)) {
        console.log(`${c.id}\t${c.projectId}\t${c.path}`);
      }
      break;
    case 'ls':
      for (const m of await call('GET', `/workspaces${args[0] ? `?project=${encodeURIComponent(args[0])}` : ''}`)) {
        console.log(`${m.workspace.id}\t${m.workspace.status}\t${m.workspace.name}\t检出 ${m.checkout.id}`);
        for (const instance of m.instances) console.log(`  ${instance.id}\t${instance.status}\t${instance.title}`);
      }
      break;
    case 'new': {
      need(2);
      const m = await call('POST', '/workspaces', { checkout: args[0], prompt: args.slice(1).join(' ') });
      console.log(`· 工作区 ${m.workspace.id}，目录 ${m.workspace.cwd}，线程 ${m.threads[0].instanceId}`);
      await follow({ threadId: m.threads[0].instanceId }, true);
      break;
    }
    case 'send':
      need(2);
      await follow({ threadId: args[0]! }, true, () => call('POST', `/threads/${args[0]}/messages`, { text: args.slice(1).join(' ') }));
      break;
    case 'follow':
      await follow(args[0] ? { threadId: args[0] } : 'catalog');
      break;
    case 'follow-workspace':
      need(1);
      await follow({ workspaceId: args[0]! });
      break;
    case 'interrupt':
      need(1);
      console.log(JSON.stringify(await call('POST', `/threads/${args[0]}/interrupt`), null, 2));
      break;
    case 'resume':
      need(1);
      await follow({ threadId: args[0]! }, true, () => call('POST', `/threads/${args[0]}/resume`));
      break;
    case 'recover':
      need(1);
      await call('POST', `/threads/${args[0]}/recover`);
      console.log('· 已确认恢复，用 resume 继续');
      break;
    case 'snapshots':
      need(1);
      for (const s of await call('GET', `/workspaces/${args[0]}/snapshots`)) {
        console.log(`${s.commit.slice(0, 8)}\t${new Date(s.at).toLocaleString('zh-CN')}\t${s.label}`);
      }
      break;
    case 'restore':
      need(2);
      await call('POST', `/workspaces/${args[0]}/restore`, { commit: args[1] });
      console.log('· 已恢复');
      break;
    case 'adopt': {
      need(1);
      printAdopt(await call('POST', `/workspaces/${args[0]}/adopt`));
      break;
    }
    case 'archive':
      need(1);
      await call('POST', `/workspaces/${args[0]}/archive`, { force: args.includes('--force') });
      console.log('· 已归档');
      break;
    case 'pair': {
      const p = await call('POST', '/pairings');
      if (p.invite) console.log(`用 iPhone 相机扫码，Kite 会自动连接：\n${await QRCode.toString(p.invite, { type: 'terminal', small: true })}`);
      console.log(`配对码 ${p.code}，${new Date(p.expiresAt).toLocaleTimeString('zh-CN')} 前有效，只能使用一次`);
      console.log(p.address ? `也可以在 App 中手动填写地址 ${p.address} 和这个配对码` : '组网尚未上线，远程设备暂时连不上；先运行 kite net up');
      break;
    }
    case 'net': {
      if (args[0] === 'admin') {
        need(2);
        await call('PUT', '/network/admin', { apiKey: args[1], user: args[2] ?? process.env.USER ?? '' });
        console.log('已保存 headscale 管理密钥');
        break;
      }
      if (args[0] === 'up' || args[0] === 'down') await call('PUT', '/network', { enabled: args[0] === 'up' });
      else if (args[0]) { console.log(USAGE); process.exit(1); }
      let s = await call('GET', '/network');
      // 开启后等节点给出登录网址或上线，最多 30 秒。
      for (let i = 0; args[0] === 'up' && i < 60 && !s.loginURL && s.state !== 'Running' && !s.error; i++) {
        await Bun.sleep(500);
        s = await call('GET', '/network');
      }
      if (!s.enabled) console.log('组网已关闭');
      else if (s.state === 'Running') console.log(`组网已上线：${s.name ?? ''}\n远程地址 ${s.address}，用 kite pair 生成配对码`);
      else if (s.loginURL) console.log(`在浏览器中打开以登录组网：\n${s.loginURL}`);
      else console.log(`组网状态：${s.state}${s.error ? `\n${s.error}` : ''}`);
      break;
    }
    case 'devices':
      for (const d of await call('GET', '/devices')) {
        const seen = d.lastSeenAt ? new Date(d.lastSeenAt).toLocaleString('zh-CN') : '未使用';
        console.log(`${d.id}\t${d.name}\t最近 ${seen}`);
      }
      break;
    case 'revoke':
      need(1);
      await call('DELETE', `/devices/${args[0]}`);
      console.log('· 已撤销');
      break;
    default:
      console.log(USAGE);
  }
}

if (import.meta.main) await main();
