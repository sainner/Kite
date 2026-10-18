#!/usr/bin/env bun
/** kite 命令行：kited 的薄客户端，第 2 步没有界面时用它走通流程。 */
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import type { EventScope } from './events.ts';

const BASE = process.env.KITE_URL ?? `http://127.0.0.1:${process.env.KITE_PORT ?? 5483}`;

const USAGE = `用法：
  kite projects                       列出项目
  kite add <文件夹|远程地址>          添加项目：远程只登记不 clone；没有远程的文件夹导入成各工作机互取的项目
  kite checkouts [项目]               列出本机检出
  kite ls [项目]                      列出工作区和线程
  kite new <项目> <消息>              在本机开新工作区（没有检出时先 clone），跟到这一轮结束
  kite send <线程> <消息>             发消息，跟到这一轮结束
  kite follow [线程]                  跟线程正文；省略时跟目录概要
  kite follow-workspace <工作区>      跟工作区操作事件
  kite interrupt <线程>               停止会话并退回排队消息
  kite resume <线程>                  继续等待中的线程
  kite recover <线程>                 确认旧执行已停止，随后用 resume 继续
  kite snapshots <工作区>               列出快照
  kite restore <工作区> <快照>          把工作树恢复到某一枚快照
  kite adopt <工作区>                   按项目的集成方式集成：直接合入或提交 PR
  kite sync <工作区>                    把主线的新改动合进工作区
  kite archive <工作区> [--force]       归档工作区，删掉工作树
  kite net [up|down|logout]           查看、开启或关闭组网，或退出 Tailscale 登录；第一次开启时给出登录地址`;

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
const printedOutcomes = new Map<string, string | undefined>();
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
    case 'thread.state': {
      // 回合失败、打断、恢复阻塞的说明只在状态里，变了才打一次。
      const outcome = e.state.error ? `! ${e.state.error}` : e.state.lastOutcome?.kind === 'interrupted' ? '· 已打断' : undefined;
      if (e.state.status === 'failed') console.log(`! 工作区准备失败${e.state.error ? `：${e.state.error}` : ''}`);
      else if (e.state.status === 'archived') console.log('· 线程已归档');
      else if (outcome && outcome !== printedOutcomes.get(e.threadId)) console.log(outcome);
      printedOutcomes.set(e.threadId, outcome);
      if (isPaused(e)) console.log(`· 会话 已停止，${e.state.recovery ? '确认旧执行停止后用 recover，再用 resume 继续' : '用 resume 继续'}`);
      break;
    }
    case 'workspace.changed': console.log(`· 工作区 ${e.workspaceId}：${e.status}`); break;
    case 'thread.changed': console.log(`· 线程 ${e.threadId}：${e.status}`); break;
    case 'checkout.changed': console.log(`· 检出 ${e.checkoutId} 已更新`); break;
    case 'catalog.snapshot': console.log(`· 已连接，${e.workspaces.length} 个工作区`); break;
    case 'workspace.model': console.log(`· 工作区 ${e.workspaceId}：${e.model.workspace.status}`); break;
    case 'thread.history':
      for (const record of e.records) print({ type: 'thread.record', threadId: e.threadId, record });
      print({ type: 'thread.state', threadId: e.threadId, state: e.state });
      break;
    case 'workspace.setup':
      console.log(e.exit === null ? '· 没有初始化脚本' : `· 初始化脚本退出码 ${e.exit}${e.exit ? `\n${e.log}` : ''}`);
      break;
    case 'workspace.snapshot': console.log(`· 快照 ${e.commit.slice(0, 8)}，${e.changedFiles} 个文件：${e.label}`); break;
    case 'workspace.adopt': printAdopt(e.result); break;
    case 'workspace.sync': printSync(e.result); break;
    case 'thread.idle': console.log('\n· 回合结束'); break;
    case 'workspace.error':
    case 'thread.error': console.log(`! ${e.message}`); break;
  }
}

function printAdopt(r: any): void {
  if (r.status === 'adopted') {
    console.log(`· 已合进主线：${r.commit.slice(0, 8)}`);
    if (r.push.status === 'pushed') console.log('· 已推送到远程');
    else if (r.push.status === 'failed') console.log(`! 推送失败：${r.push.message}`);
  }
  else if (r.status === 'proposed') console.log(`· 已推到分支 ${r.branch}：${r.url}`);
  else console.log(`· 合并冲突，已交给 agent 解决：${r.files.join('、')}`);
}

function printSync(r: any): void {
  if (r.status === 'synced') console.log(`· 已把主线合进工作区：${r.commit.slice(0, 8)}`);
  else if (r.status === 'current') console.log('· 已是最新');
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
      for (const p of await call('GET', '/projects')) console.log(`${p.id}\t${p.name}\t${p.remote}`);
      break;
    case 'add': {
      need(1);
      // 本机存在的路径按文件夹添加，其余按远程地址。
      const source = existsSync(resolve(args[0]!)) ? { path: resolve(args[0]!) } : { remote: args[0] };
      const p = await call('POST', '/project-registry', source);
      console.log(`已添加 ${p.name}（${p.remote ?? '没有远程'}，${p.integration === 'pullRequest' ? '提交 PR' : '直接合入'}）\n项目 ${p.id}`);
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
      const m = await call('POST', '/workspaces', { project: args[0], prompt: args.slice(1).join(' ') });
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
    case 'sync':
      need(1);
      printSync(await call('POST', `/workspaces/${args[0]}/sync`));
      break;
    case 'archive':
      need(1);
      await call('POST', `/workspaces/${args[0]}/archive`, { force: args.includes('--force') });
      console.log('· 已归档');
      break;
    case 'net': {
      if (args[0] === 'up' || args[0] === 'down') await call('PUT', '/network', { enabled: args[0] === 'up' });
      else if (args[0] === 'logout') await call('POST', '/network/logout');
      else if (args[0]) { console.log(USAGE); process.exit(1); }
      let s = await call('GET', '/network');
      // 开启后等节点给出登录网址或上线，最多 30 秒。
      for (let i = 0; args[0] === 'up' && i < 60 && !s.loginURL && s.state !== 'Running' && !s.error; i++) {
        await Bun.sleep(500);
        s = await call('GET', '/network');
      }
      if (!s.enabled) console.log('组网已关闭');
      else if (s.state === 'Running') {
        console.log(`组网已上线：${s.name ?? ''}（${s.user?.loginName ?? ''}）\n远程地址 ${s.address}，同一 Tailscale 用户的设备可直接访问`);
        const labels: Record<string, string> = { direct: '直连', relay: '中继', idle: '空闲' };
        for (const peer of s.peers ?? []) {
          console.log(`  ${peer.name}${peer.ip ? ` ${peer.ip}` : ''}：${labels[peer.connection] ?? peer.connection}${peer.endpoint ? ` ${peer.endpoint}` : ''}`);
        }
      }
      else if (s.loginURL) console.log(`在浏览器中打开以登录 Tailscale：\n${s.loginURL}`);
      else console.log(`组网状态：${s.state}${s.error ? `\n${s.error}` : ''}`);
      break;
    }
    default:
      console.log(USAGE);
  }
}

if (import.meta.main) await main();
