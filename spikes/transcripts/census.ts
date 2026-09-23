/**
 * 1c 会话记录普查：统计 ~/.claude/projects 下所有会话记录的结构。
 * 只输出结构（记录类型、字段名、次数、字节、版本），不输出对话内容。
 * 用法：bun census.ts [根目录，默认 ~/.claude/projects] > 报告.md
 */
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

const root = process.argv[2] ?? join(homedir(), '.claude/projects');

type Kind = { count: number; files: Set<string>; bytes: number; keys: Map<string, number>; minV?: string; maxV?: string };
const kinds = new Map<string, Kind>();
const cmpV = (a: string, b: string) => {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) - (pb[i] ?? 0);
  return 0;
};
function bump(scope: string, kind: string, file: string, bytes: number, obj: any, keysOf?: any) {
  const k = `${scope} ${kind}`;
  let e = kinds.get(k);
  if (!e) kinds.set(k, (e = { count: 0, files: new Set(), bytes: 0, keys: new Map() }));
  e.count++; e.files.add(file); e.bytes += bytes;
  const v = obj?.version;
  if (typeof v === 'string' && /^\d+\.\d+\.\d+/.test(v)) {
    if (!e.minV || cmpV(v, e.minV) < 0) e.minV = v;
    if (!e.maxV || cmpV(v, e.maxV) > 0) e.maxV = v;
  }
  if (keysOf && typeof keysOf === 'object') for (const key of Object.keys(keysOf)) e.keys.set(key, (e.keys.get(key) ?? 0) + 1);
}

const versions = new Map<string, number>(); // 文件的首个版本
const instr: string[] = [];
const snapshots: string[] = [];
const enums = new Map<string, Map<string, number>>(); // 小枚举字段的取值分布
const enumVal = (k: string, v: unknown) => { let m = enums.get(k); if (!m) enums.set(k, (m = new Map())); const key = JSON.stringify(v); m.set(key, (m.get(key) ?? 0) + 1); };
const branchKinds = new Map<string, number>(); // 分叉点的子节点种类组合
const msgSplit = { assistantRecords: 0, distinctMessageIds: 0, maxRecordsPerMessage: 0 };
const tree = { files: 0, branchPoints: 0, filesWithBranches: 0, roots: 0, multiRootFiles: 0, logicalParent: 0 };
let lines = 0, badLines = 0, totalBytes = 0;

function scanFile(path: string, scope: 'main' | 'subagent' | 'legacy-agent') {
  const text = readFileSync(path, 'utf8');
  const all = text.split('\n').filter(Boolean);
  const file = path;
  const children = new Map<string, number>();
  const kidsOf = new Map<string, string[]>();
  const kindOf = (o: any) => o.type === 'attachment' ? `attachment:${o.attachment?.type}` : o.type === 'system' ? `system:${o.subtype}` : o.type === 'user' ? (Array.isArray(o.message?.content) && o.message.content.some((b: any) => b.type === 'tool_result') ? 'user(tool_result)' : 'user(文本)') : o.type === 'assistant' ? `assistant(${(o.message?.content ?? []).map((b: any) => b.type).join('+')})` : o.type;
  const perMsg = new Map<string, number>();
  let roots = 0, firstV: string | undefined, envSeen = 0;
  const vset = new Set<string>();
  all.forEach((line, idx) => {
    lines++; totalBytes += line.length + 1;
    let o: any;
    try { o = JSON.parse(line); } catch { badLines++; return; }
    if (typeof o.version === 'string') { firstV ??= o.version; vset.add(o.version); }
    const bytes = line.length + 1;
    const t = o.type ?? '(无 type)';
    if (o.uuid) {
      if (o.parentUuid) {
        children.set(o.parentUuid, (children.get(o.parentUuid) ?? 0) + 1);
        const arr = kidsOf.get(o.parentUuid) ?? []; arr.push(kindOf(o)); kidsOf.set(o.parentUuid, arr);
      } else roots++;
      if (o.logicalParentUuid) tree.logicalParent++;
    }
    if (o.type === 'assistant' && o.message?.id) { msgSplit.assistantRecords++; perMsg.set(o.message.id, (perMsg.get(o.message.id) ?? 0) + 1); }
    if (t === 'attachment' && o.attachment) {
      const at = o.attachment.type ?? '(无)';
      bump(scope, `attachment:${at}`, file, bytes, o, o.attachment);
      if (at === 'environment') envSeen++;
      if (at === 'instructions') {
        const types = (o.attachment.files ?? []).map((f: any) => f.type).join('+');
        instr.push(`| ${basename(path).slice(0, 8)} | ${scope} | ${o.version ?? '?'} | 第 ${idx + 1}/${all.length} 行 | 之前 environment 附件 ${envSeen} 个 | ${types} | ${o.attachment.reason ?? ''} ${o.attachment.changed !== undefined ? 'changed=' + JSON.stringify(o.attachment.changed) : ''} |`);
        enumVal('instructions.reason', o.attachment.reason ?? null);
      }
      if (at === 'prompt_snapshot') snapshots.push(`| ${basename(path).slice(0, 8)} | ${scope} | ${o.version ?? '?'} | 第 ${idx + 1}/${all.length} 行 | 之前 environment 附件 ${envSeen} 个 | systemPrompt ${Array.isArray(o.attachment.systemPrompt) ? o.attachment.systemPrompt.length + ' 段' : typeof o.attachment.systemPrompt} | tools ${Array.isArray(o.attachment.tools) ? o.attachment.tools.length + ' 个' : '无'} |`);
      if (at === 'environment' && o.attachment.changes) enumVal('environment.changes 的键', Object.keys(o.attachment.changes).sort().join(','));
    } else if (t === 'queue-operation') {
      bump(scope, t, file, bytes, o, o);
      enumVal('queue-operation.operation+reason', `${o.operation} ${o.reason ?? ''}`.trim());
    } else if (t === 'system') {
      bump(scope, `system:${o.subtype ?? '(无)'}`, file, bytes, o, o);
    } else if (t === 'user' || t === 'assistant') {
      const flags = Object.entries(o).filter(([, v]) => v === true).map(([k]) => k).sort();
      bump(scope, `${t}${flags.length ? ' [' + flags.join(',') + ']' : ''}`, file, bytes, o, o);
      const c = o.message?.content;
      if (typeof c === 'string') bump(scope, `${t}.content:string`, file, c.length, o);
      else if (Array.isArray(c)) for (const b of c) bump(scope, `${t}.block:${b?.type ?? '?'}`, file, JSON.stringify(b).length, o, b);
      if (o.toolUseResult !== undefined) bump(scope, `${t}.toolUseResult`, file, JSON.stringify(o.toolUseResult ?? null).length, o);
      if (t === 'user') { enumVal('user.userType', o.userType ?? null); enumVal('user.entrypoint', o.entrypoint ?? null); }
    } else {
      bump(scope, t, file, bytes, o, o);
    }
  });
  tree.files++;
  for (const kids of kidsOf.values()) if (kids.length > 1) { const key = kids.sort().join(' ＋ '); branchKinds.set(key, (branchKinds.get(key) ?? 0) + 1); }
  msgSplit.distinctMessageIds += perMsg.size;
  for (const n of perMsg.values()) msgSplit.maxRecordsPerMessage = Math.max(msgSplit.maxRecordsPerMessage, n);
  const bp = [...children.values()].filter((n) => n > 1).length;
  tree.branchPoints += bp; if (bp) tree.filesWithBranches++;
  tree.roots += roots; if (roots > 1) tree.multiRootFiles++;
  if (scope === 'main' && firstV) versions.set(firstV, (versions.get(firstV) ?? 0) + 1);
}

const sideFiles = new Map<string, { n: number; bytes: number; keys: Map<string, number> }>();
function side(kind: string, path: string, json = false) {
  let e = sideFiles.get(kind);
  if (!e) sideFiles.set(kind, (e = { n: 0, bytes: 0, keys: new Map() }));
  e.n++; e.bytes += statSync(path).size;
  if (json) { try { for (const k of Object.keys(JSON.parse(readFileSync(path, 'utf8')))) e.keys.set(k, (e.keys.get(k) ?? 0) + 1); } catch {} }
}

for (const proj of readdirSync(root)) {
  const pdir = join(root, proj);
  if (!statSync(pdir).isDirectory()) continue;
  for (const ent of readdirSync(pdir)) {
    const p = join(pdir, ent);
    const st = statSync(p);
    if (st.isFile() && ent.endsWith('.jsonl')) scanFile(p, ent.startsWith('agent-') ? 'legacy-agent' : 'main');
    else if (st.isDirectory() && /^[0-9a-f-]{36}$/.test(ent)) {
      for (const sub of readdirSync(p)) {
        const sp = join(p, sub);
        if (sub === 'subagents') for (const f of readdirSync(sp)) {
          if (f.endsWith('.jsonl')) scanFile(join(sp, f), 'subagent');
          else if (f.endsWith('.json')) side('subagents/*.json（子 agent 元数据）', join(sp, f), true);
        }
        else if (sub === 'tool-results') for (const f of readdirSync(sp)) side('tool-results/*（外置的大工具输出）', join(sp, f));
        else if (statSync(sp).isFile()) side(`<会话>/${sub.replace(/^[^.]+/, '*')}`, sp, sub.endsWith('.json'));
        else side(`<会话>/${sub}/（目录）`, sp);
      }
    }
  }
}

const mb = (b: number) => (b / 1024 / 1024).toFixed(2);
const out: string[] = [];
out.push(`# 会话记录普查\n\n根目录：\`${root.replace(homedir(), '~')}\`，${lines} 行记录，${mb(totalBytes)} MB，解析失败 ${badLines} 行。\n`);
out.push(`## 主会话首条记录的 Claude Code 版本\n`);
out.push([...versions.entries()].sort((a, b) => cmpV(a[0], b[0])).map(([v, n]) => `${v}×${n}`).join('，') + '\n');
out.push(`## 记录种类\n\n「范围」：main 是主会话，subagent 是 subagents/ 下的子 agent 记录，legacy-agent 是项目目录下的老格式子 agent 记录。块（block）的字节只算块本身。\n`);
out.push('| 范围 | 种类 | 条数 | 文件数 | MB | 版本范围 | 常见字段 |\n|---|---|---|---|---|---|---|');
for (const [k, e] of [...kinds.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  const [scope, ...rest] = k.split(' ');
  const keys = [...e.keys.entries()].sort((a, b) => b[1] - a[1]).slice(0, 14).map(([key, n]) => n === e.count ? key : `${key}(${n})`).join(', ');
  out.push(`| ${scope} | ${rest.join(' ')} | ${e.count} | ${e.files.size} | ${mb(e.bytes)} | ${e.minV ?? ''}–${e.maxV ?? ''} | ${keys} |`);
}
out.push(`\n## 树结构\n\n${tree.files} 个文件；无父节点的记录 ${tree.roots} 条，${tree.multiRootFiles} 个文件有多个根；分叉点（一个父节点有多个子节点）${tree.branchPoints} 个，分布在 ${tree.filesWithBranches} 个文件；带 logicalParentUuid 的记录 ${tree.logicalParent} 条。\n`);
out.push(`一条 API 回复（按 message.id）拆成多条 assistant 记录：${msgSplit.assistantRecords} 条 assistant 记录对应 ${msgSplit.distinctMessageIds} 个 message.id，单个 message.id 最多 ${msgSplit.maxRecordsPerMessage} 条。\n`);
out.push(`分叉点的子节点种类组合（前 12）：\n\n| 次数 | 子节点 |\n|---|---|`);
out.push(...[...branchKinds.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([k, n]) => `| ${n} | ${k.slice(0, 200)} |`));
out.push(`\n## 小枚举字段的取值\n`);
for (const [k, m] of enums) out.push(`- ${k}：` + [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12).map(([v, n]) => `${v}×${n}`).join('，'));
out.push(`\n## prompt_snapshot 附件出现的位置\n\n| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 系统提示 | 工具 |\n|---|---|---|---|---|---|---|`);
out.push(...snapshots);
out.push(`\n## instructions 附件出现的位置\n\n| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 文件类型 | 原因 |\n|---|---|---|---|---|---|---|`);
out.push(...instr);
out.push(`\n## 旁路文件\n\n| 种类 | 个数 | MB | 字段 |\n|---|---|---|---|`);
for (const [k, e] of sideFiles) out.push(`| ${k} | ${e.n} | ${mb(e.bytes)} | ${[...e.keys.entries()].map(([key, n]) => n === e.n ? key : `${key}(${n})`).join(', ')} |`);
console.log(out.join('\n'));
