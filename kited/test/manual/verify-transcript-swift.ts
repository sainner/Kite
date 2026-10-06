/**
 * 手动合同验证：真实显示投影的 JSON 经 App 解码后，思考独立于工具组，迟到结果仍回填原调用。
 * 运行：bun kited/test/manual/verify-transcript-swift.ts
 * Swift 编译不计入 small 测试耗时预算。
 */
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TranscriptFeed } from '../../src/transcript/feed.ts';
import { TranscriptProjection } from '../../src/transcript/projection.ts';
import type { DisplayDelta, DisplayRecord } from '../../src/transcript/protocol.ts';
import { assembleContext, literalContext } from '../../src/harness/context/assembler.ts';
import { FileJournal } from '../../src/harness/journal.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import { requestSnapshot } from '../../src/harness/request-config.ts';
import type { JournalEvent, JournalRecord, ModelItem, ToolResult } from '../../src/harness/types.ts';
import type { ThreadContext } from '../../src/model.ts';
import { command } from './command.ts';

// patch 的磁盘副作用与 journal 的 schema 解析交接后，投影和 Swift 仍须保留可回看的 diff 引用。
async function persistedPatchResult(): Promise<ToolResult> {
  const root = mkdtempSync(join(tmpdir(), 'transcript-diff-contract-'));
  let journal: FileJournal | undefined;
  try {
    mkdirSync(join(root, '目录'));
    const patch = localTools({ cwd: root, logDir: join(root, 'logs'), diffDir: join(root, 'diffs'),
      env: { ...(process.env as Record<string, string>) } }).find((tool) => tool.name === 'patch');
    if (!patch) throw new Error('缺少 patch 工具');
    const args = { operations: [{ type: 'create_file', path: '目录/带 空格.ts', diff: '+export const value = 1;\n+' }] };
    patch.validate(args);
    const result = await patch.execute(args, { cwd: root, signal: new AbortController().signal });
    if (result.status !== 'success' || !result.diff) throw new Error('实际 patch 未返回持久 diff');
    const path = join(root, 'journal.jsonl');
    journal = new FileJournal(path);
    journal.append({ type: 'tool.finished', turnId: 'fixture-turn', requestId: 'fixture-request',
      callId: 'top-before', result });
    journal.close();
    journal = new FileJournal(path);
    const saved = journal.records[0];
    if (saved?.type !== 'tool.finished' || saved.result.diff?.id !== result.diff.id
      || JSON.stringify(saved.result.diff.paths) !== JSON.stringify(['目录/带 空格.ts'])) {
      throw new Error('真实 journal 写盘重开丢失 patch 的 diff 引用');
    }
    return saved.result;
  } finally {
    journal?.close();
    rmSync(root, { recursive: true, force: true });
  }
}

// 只按声明名抽取 App 类型，合同编译真实的转换代码，不维护一份模仿实现。
function declaration(source: string, signature: string): string {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + 1) >= 0) throw new Error(`Swift 声明不唯一：${signature}`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`Swift 声明未闭合：${signature}`);
}

const thread = { id: 'fixture-thread', status: 'open', runtime: 'harness', workspace: { status: 'open' } } as ThreadContext;
const feed = new TranscriptFeed();
const projection = new TranscriptProjection(thread, feed);
const deltas: DisplayDelta[] = [];
feed.subscribe(undefined, (event) => { if (event.type === 'thread.record.delta') deltas.push(event.delta); });
projection.finishReplay();
let seq = 0;
function journal(event: JournalEvent) {
  projection.journal({ ...event, version: 1, seq: ++seq, at: 1_000 + seq } as JournalRecord);
}
function tool(id: string): ModelItem {
  return {
    id, raw: { type: 'function_call', name: 'shell', arguments: '{}', call_id: id },
    call: { id, name: 'shell', arguments: { command: `printf ${id}` } },
  };
}
function thought(id: string, text: string): ModelItem {
  return { id, raw: { type: 'reasoning', summary: [{ text }] } };
}
const turnId = 'fixture-turn';
const requestId = 'fixture-request';
const patchResult = await persistedPatchResult();
const context = assembleContext(literalContext('显示投影合同')).snapshot;
const configuration = requestSnapshot({}, []);
journal({ type: 'context.prepared', snapshot: context });
journal({ type: 'request.configured', snapshot: configuration });
journal({ type: 'request.started', turnId, requestId, inputIds: [], contextId: context.id, configurationId: configuration.id });
for (const item of [
  tool('top-before'), thought('top-thought', '顶层思考'), tool('top-after'),
  tool('child-before'), thought('child-thought', '子调用思考'), tool('child-after'),
]) journal({ type: 'model.item', turnId, requestId, item });
for (const callId of ['top-before', 'child-before', 'top-after', 'child-after']) {
  journal({ type: 'tool.finished', turnId, requestId, callId,
    result: { ...(callId === 'top-before' ? patchResult : {}), status: 'success', output: `完成 ${callId}` } });
}
journal({ type: 'request.completed', turnId, requestId, responseId: 'fixture-response', needsFollowUp: false,
  usage: { input_tokens: 321 } });
const measured = projection.snapshot();
const patchRecord = measured.records.find((record) => record.block.type === 'tool_result' && record.block.call === 'top-before');
if (patchRecord?.block.type !== 'tool_result' || patchRecord.block.diff?.id !== patchResult.diff!.id
  || JSON.stringify(patchRecord.block.diff.paths) !== JSON.stringify(['目录/带 空格.ts'])) {
  throw new Error('journal 的持久 diff 引用未抵达显示投影');
}
if (measured.state.context?.inputTokens !== 321 || measured.state.context.windowTokens !== undefined
  || measured.state.context.requestId !== requestId) throw new Error('有效用量未进入显示投影');

// harness 的原生记录是平铺的；只给投影产出的子调用记录加 parent，复用其余真实协议字段。
const topAfter = measured.records.find((record) => record.block.type === 'tool_use' && record.block.id === 'top-after');
if (!topAfter) throw new Error('投影缺少顶层工具');
const records: DisplayRecord[] = measured.records.map((record) => {
  const block = record.block;
  const child = block.type === 'tool_use' && block.id.startsWith('child-')
    || block.type === 'tool_result' && block.call.startsWith('child-')
    || block.type === 'thinking' && block.text === '子调用思考';
  return child ? { ...record, parent: 'top-after' } : record;
});

journal({ type: 'request.started', turnId, requestId: 'unmeasured-request', inputIds: [],
  contextId: context.id, configurationId: configuration.id });
const stillMeasured = projection.snapshot();
if (JSON.stringify(stillMeasured.state.context) !== JSON.stringify(measured.state.context)) {
  throw new Error('下一请求开始时丢失上次测量');
}
journal({ type: 'request.completed', turnId, requestId: 'unmeasured-request', responseId: 'unmeasured-response',
  needsFollowUp: false, usage: { input_tokens: -1 } });
const invalid = projection.snapshot();
if (invalid.state.context !== undefined) throw new Error('无效用量未清除旧值');

// 实际投影生成开始和分段增量；Swift 解码后逐条应用，并用完整记录校正同一个 id。
const streamingRequest = 'fixture-stream-request';
journal({ type: 'request.started', turnId, requestId: streamingRequest, inputIds: [],
  contextId: context.id, configurationId: configuration.id });
function stream(event: { type: 'item.started'; itemId: string; kind: 'text' | 'thinking' | 'tool_use'; callId?: string; name?: string }
  | { type: 'delta'; itemId: string; field: 'text' | 'thinking' | 'arguments'; text: string; part?: number; replace?: boolean }) {
  projection.accept({ type: 'harness', threadId: thread.id, at: 2_000 + deltas.length,
    event: { ...event, turnId, requestId: streamingRequest } });
}
stream({ type: 'item.started', itemId: 'stream-thought', kind: 'thinking' });
const thoughtStart = projection.snapshot().records.find((record) => record.id === `${streamingRequest}:stream-thought`);
if (!thoughtStart || thoughtStart.generation !== 'streaming') throw new Error('投影未建立思考草稿');
stream({ type: 'delta', itemId: 'stream-thought', field: 'thinking', part: 0, text: '顶层' });
stream({ type: 'delta', itemId: 'stream-thought', field: 'thinking', part: 1, text: '思' });
stream({ type: 'delta', itemId: 'stream-thought', field: 'thinking', part: 1, text: '思考', replace: true });
const thoughtDraft = projection.snapshot().records.find((record) => record.id === thoughtStart.id);
if (thoughtDraft?.block.type !== 'thinking' || thoughtDraft.block.text !== '顶层\n\n思考') {
  throw new Error('投影分段校正未得到完整思考');
}
journal({ type: 'model.item', turnId, requestId: streamingRequest, item: thought('stream-thought', '顶层思考') });
const thoughtComplete = projection.snapshot().records.find((record) => record.id === thoughtStart.id);
if (!thoughtComplete || thoughtComplete.generation !== 'complete') throw new Error('思考未用同 id 完成');

stream({ type: 'item.started', itemId: 'stream-tool', kind: 'tool_use', callId: 'stream-call', name: 'shell' });
const toolStart = projection.snapshot().records.find((record) => record.id === 'call:stream-call');
if (!toolStart || toolStart.block.type !== 'tool_use' || toolStart.block.stage !== 'generating') {
  throw new Error('投影未建立工具参数草稿');
}
stream({ type: 'delta', itemId: 'stream-tool', field: 'arguments', text: '{"command":"printf 中' });
stream({ type: 'delta', itemId: 'stream-tool', field: 'arguments', text: '文"}' });
const streamTool = tool('stream-tool');
streamTool.call = { id: 'stream-call', name: 'shell', arguments: { command: 'printf 中文' } };
journal({ type: 'model.item', turnId, requestId: streamingRequest, item: streamTool });
const toolQueued = projection.snapshot().records.find((record) => record.id === 'call:stream-call');
journal({ type: 'tool.started', turnId, requestId: streamingRequest, callId: 'stream-call' });
const toolRunning = projection.snapshot().records.find((record) => record.id === 'call:stream-call');
projection.accept({ type: 'harness', threadId: thread.id, at: 2_100,
  event: { type: 'tool.output', turnId, requestId: streamingRequest, callId: 'stream-call', text: '中文输出前段', limit: 6 } });
projection.accept({ type: 'harness', threadId: thread.id, at: 2_101,
  event: { type: 'tool.output', turnId, requestId: streamingRequest, callId: 'stream-call', text: '后段', limit: 6 } });
const toolDraft = projection.snapshot().records.find((record) => record.id === 'call:stream-call');
if (!toolDraft || toolDraft.block.type !== 'tool_use' || toolDraft.block.output !== '输出前段后段'
  || toolDraft.block.outputTruncated !== true) throw new Error('投影输出尾部或截断状态不正确');
journal({ type: 'tool.finished', turnId, requestId: streamingRequest, callId: 'stream-call',
  result: { status: 'success', output: '中文执行完成' } });
const toolComplete = projection.snapshot().records.find((record) => record.id === 'call:stream-call');
const toolResultComplete = projection.snapshot().records.find((record) => record.block.type === 'tool_result'
  && record.block.call === 'stream-call');
if (!toolComplete || toolComplete.block.type !== 'tool_use' || toolComplete.block.stage !== 'finished') {
  throw new Error('工具未用同 id 完成');
}
if (!toolQueued || !toolRunning || !toolResultComplete) throw new Error('工具阶段或结果记录缺失');

// 上游 JSON 流解析器跨块保留 token 状态；投影只发送已收到的摘要字段，原始参数仍逐字累计。
function draftInput(callId: string): Record<string, unknown> {
  const record = projection.snapshot().records.find((entry) => entry.id === `call:${callId}`);
  if (record?.block.type !== 'tool_use') throw new Error(`缺少工具草稿：${callId}`);
  return record.block.input as Record<string, unknown>;
}
function draftArguments(callId: string): string {
  const record = projection.snapshot().records.find((entry) => entry.id === `call:${callId}`);
  if (record?.block.type !== 'tool_use') throw new Error(`缺少工具参数：${callId}`);
  return record.block.arguments ?? '';
}
function startTool(itemId: string, callId: string, name: string) {
  stream({ type: 'item.started', itemId, kind: 'tool_use', callId, name });
}
function appendArguments(itemId: string, text: string, replace = false) {
  stream({ type: 'delta', itemId, field: 'arguments', text, replace });
}

startTool('stream-read', 'read-call', 'read');
const readRaw = JSON.stringify({ path: '目录/带"引号/😀.txt', offset: 12, limit: 100 })
  .replace('😀', '\\uD83D\\uDE00').replace('"limit":100', '"limit":1e2');
const firstEscape = readRaw.indexOf('\\"');
const highSurrogate = readRaw.indexOf('\\uD83D');
const pathEnd = readRaw.indexOf('","offset"') + 2;
const limitStart = readRaw.indexOf('"limit"');
const exponent = readRaw.indexOf('1e2');
if ([firstEscape, highSurrogate, pathEnd, limitStart, exponent].some((index) => index < 0)) {
  throw new Error('读取参数夹具未包含预期的 JSON 边界');
}
const readCuts = [firstEscape + 1, highSurrogate + 6, pathEnd, limitStart, exponent + 2, readRaw.length];
let readPosition = 0;
for (const [index, end] of readCuts.entries()) {
  appendArguments('stream-read', readRaw.slice(readPosition, end));
  readPosition = end;
  const input = draftInput('read-call');
  if (index === 1 && /\\ud83d/i.test(JSON.stringify(input))) throw new Error('半个 Unicode 代理进入显示摘要');
  if (index === 2 && input.path !== '目录/带"引号/😀.txt') throw new Error('跨块转义引号、中文或 emoji 路径丢失');
  if (index === 3 && (input.offset !== 12 || 'limit' in input)) throw new Error('完整数字未出现或提前猜测 limit');
  if (index === 4 && 'limit' in input) throw new Error('未完成的指数被提前当作有效数字');
}
if (JSON.stringify(draftInput('read-call')) !== JSON.stringify({ path: '目录/带"引号/😀.txt', offset: 12, limit: 100 })
  || draftArguments('read-call') !== readRaw) throw new Error('读取参数完整摘要或原文不一致');

startTool('stream-patch', 'patch-call', 'patch');
const largeDiff = 'x'.repeat(16_384);
const patchRaw = JSON.stringify({ operations: [
  { diff: largeDiff, path: '甲.txt', type: 'edit_file' },
  { type: 'create_file', diff: '+新文件', path: '乙.txt' },
] });
const firstPath = patchRaw.indexOf(',"path":"甲.txt"');
const secondOperation = patchRaw.indexOf('{"type":"create_file"');
if (firstPath < 0 || secondOperation < 0) throw new Error('patch 参数夹具边界错误');
appendArguments('stream-patch', patchRaw.slice(0, firstPath));
if (JSON.stringify(draftInput('patch-call')).includes(largeDiff)) throw new Error('长 diff 进入工具摘要');
appendArguments('stream-patch', patchRaw.slice(firstPath, secondOperation));
const firstOperation = (draftInput('patch-call').operations as Array<Record<string, unknown>> | undefined)?.[0];
if (firstOperation?.path !== '甲.txt' || firstOperation.type !== 'edit_file') {
  throw new Error('第一项 patch 路径或操作类型未在后到字段完整时出现');
}
appendArguments('stream-patch', patchRaw.slice(secondOperation));
if (JSON.stringify(draftInput('patch-call')) !== JSON.stringify({ operations: [
  { path: '甲.txt', type: 'edit_file' }, { type: 'create_file', path: '乙.txt' },
] }) || draftArguments('patch-call') !== patchRaw) throw new Error('patch 数组索引串位或原始 diff 丢失');

startTool('stream-replace', 'replace-call', 'read');
appendArguments('stream-replace', '{"path":"旧文件');
appendArguments('stream-replace', '{"path":"新文件.txt","offset":', true);
appendArguments('stream-replace', '7}');
if (draftArguments('replace-call') !== '{"path":"新文件.txt","offset":7}'
  || JSON.stringify(draftInput('replace-call')) !== JSON.stringify({ path: '新文件.txt', offset: 7 })) {
  throw new Error('全文 replace 后解析器未从新参数继续增量解析');
}

startTool('stream-broken', 'broken-call', 'shell');
appendArguments('stream-broken', '{"command":"损坏"]');
startTool('stream-isolated', 'isolated-call', 'read');
appendArguments('stream-isolated', '{"path":"独立.txt"}');
if (draftInput('isolated-call').path !== '独立.txt') throw new Error('另一调用被损坏参数污染');
const correctedTool: ModelItem = {
  id: 'stream-broken', raw: { type: 'function_call', name: 'shell', arguments: '{"command":"校正"}', call_id: 'broken-call' },
  call: { id: 'broken-call', name: 'shell', arguments: { command: '校正' } },
};
journal({ type: 'model.item', turnId, requestId: streamingRequest, item: correctedTool });
const correctedRecord = projection.snapshot().records.find((entry) => entry.id === 'call:broken-call');
if (correctedRecord?.block.type !== 'tool_use' || correctedRecord.generation !== 'complete'
  || JSON.stringify(correctedRecord.block.input) !== JSON.stringify({ command: '校正' })) {
  throw new Error('损坏草稿未被完整模型条目按原调用校正');
}

const root = mkdtempSync(join(tmpdir(), 'transcript-swift-contract-'));
try {
  const app = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const clientSource = readFileSync(join(app, 'Application', 'KitedClient.swift'), 'utf8');
  const extracted = join(root, 'RemoteTranscriptTypes.swift');
  writeFileSync(extracted, `import Foundation\n\n${[
    'struct RemoteState:', 'struct ContextUsage:', 'struct RemoteRecord:', 'struct RemoteDelta:',
    'struct KitedError:', 'extension RemoteRecord', 'extension JSON: Codable',
  ].map((signature) => declaration(clientSource, signature)).join('\n\n')}\n`);
  const recordsPath = join(root, 'records.json');
  const statesPath = join(root, 'states.json');
  writeFileSync(recordsPath, JSON.stringify(records));
  writeFileSync(statesPath, JSON.stringify([measured.state, stillMeasured.state, invalid.state]));
  const streamPath = join(root, 'stream.json');
  writeFileSync(streamPath, JSON.stringify({
    thoughtStart, thoughtDeltas: deltas.filter((delta) => delta.id === thoughtStart.id), thoughtComplete,
    toolStart, argumentDeltas: deltas.filter((delta) => delta.id === toolStart.id && delta.field === 'arguments'),
    toolQueued, toolRunning, outputDeltas: deltas.filter((delta) => delta.id === toolStart.id && delta.field === 'output'),
    toolDraft, toolComplete, toolResultComplete,
  }));
  const fixture = join(root, 'TranscriptContract.swift');
  writeFileSync(fixture, String.raw`
import Foundation

private func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

private struct StreamFixture: Decodable {
    let thoughtStart: RemoteRecord
    let thoughtDeltas: [RemoteDelta]
    let thoughtComplete: RemoteRecord
    let toolStart: RemoteRecord
    let argumentDeltas: [RemoteDelta]
    let toolQueued: RemoteRecord
    let toolRunning: RemoteRecord
    let outputDeltas: [RemoteDelta]
    let toolDraft: RemoteRecord
    let toolComplete: RemoteRecord
    let toolResultComplete: RemoteRecord
}

@main
struct TranscriptContract {
    static func main() throws {
        let records = try JSONDecoder().decode([RemoteRecord].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let states = try JSONDecoder().decode([RemoteState].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        require(states.count == 3, "状态夹具数量错误")
        require(states[0].context?.requestId == "fixture-request"
            && states[0].context?.inputTokens == 321
            && states[0].context?.windowTokens == nil
            && states[0].context?.measuredAt == 1014,
            "有效上下文未正确解码")
        require(states[1].context?.requestId == states[0].context?.requestId,
            "运行中不应把上次测量改属新请求")
        require(states[2].context == nil, "无效用量未解码为空")

        let stream = try JSONDecoder().decode(StreamFixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        var thought = stream.thoughtStart
        require(thought.generation == "streaming" && thought.block.type == "thinking",
            "思考草稿的生成状态未解码")
        for delta in stream.thoughtDeltas { try thought.apply(delta) }
        require(thought.block.text == "顶层\n\n思考", "分段结束校正重复或丢失思考文字")
        var live = Transcript(root: "/fixture")
        guard let thoughtRecord = thought.record else { fatalError("流式思考未转换为记录") }
        live.records = [thoughtRecord]
        require(live.items.first?.generation == "streaming", "正在生成的思考未保留生成状态")
        guard let completedThought = stream.thoughtComplete.record else { fatalError("完整思考未转换为记录") }
        live.replaceRecord(at: 0, with: completedThought)
        require(live.items.first?.generation == "complete", "思考完成后未收起生成状态")
        guard case .thinking(let thoughtText) = live.items[0].kind else { fatalError("思考记录丢失") }
        require(thoughtText == "顶层思考", "完整思考校正后出现重字")

        var generatedTool = stream.toolStart
        require(generatedTool.block.stage == "generating", "工具参数草稿阶段未解码")
        require(stream.argumentDeltas.contains { $0.input?["command"]?.string == "printf 中文" },
            "已完成参数未通过显示增量抵达 Swift")
        for delta in stream.argumentDeltas { try generatedTool.apply(delta) }
        require(generatedTool.block.arguments == "{\"command\":\"printf 中文\"}", "工具参数增量未按原文合并")
        require(generatedTool.block.input?["command"]?.string == "printf 中文",
            "Swift 未使用服务端解析的参数草稿")
        var runningTool = stream.toolRunning
        require(stream.toolQueued.block.stage == "queued" && runningTool.block.stage == "running",
            "工具等待和执行阶段未分别解码")
        for delta in stream.outputDeltas { try runningTool.apply(delta) }
        require(runningTool.block.output == stream.toolDraft.block.output
            && runningTool.block.output == "输出前段后段"
            && runningTool.block.outputTruncated == true,
            "工具输出增量与受限快照不一致")
        guard let startedTool = stream.toolStart.record,
              let queuedTool = stream.toolQueued.record,
              let runningRecord = runningTool.record,
              let completedTool = stream.toolComplete.record else { fatalError("工具记录转换失败") }
        live.records.append(startedTool)
        live.replaceRecord(at: 1, with: generatedTool.record!)
        live.replaceRecord(at: 1, with: queuedTool)
        guard case .work(let queuedWork) = live.items[1].kind else { fatalError("等待工具未归入工具组") }
        require(queuedWork.calls.count == 1 && queuedWork.calls[0].state == .queued,
            "原工具记录校正为 queued 后显示状态未更新")
        live.replaceRecord(at: 1, with: runningRecord)
        guard case .work(let runningWork) = live.items[1].kind else { fatalError("运行工具未归入工具组") }
        require(runningWork.calls[0].state == .running && runningWork.calls[0].use.output == "输出前段后段",
            "原工具记录校正为 running 后状态或输出未更新")
        live.replaceRecord(at: 1, with: completedTool)
        guard case .toolUse(let finalTool) = live.records[1].block else { fatalError("完成工具记录类型错误") }
        require(finalTool.id == "stream-call" && finalTool.stage == "finished", "工具完成时身份或阶段变化")
        guard let finalToolResult = stream.toolResultComplete.record else { fatalError("工具结果转换失败") }
        live.records.append(finalToolResult)
        guard case .work(let finishedWork) = live.items[1].kind else { fatalError("完成工具未归入工具组") }
        require(finishedWork.calls.count == 1 && finishedWork.calls[0].state == .done
            && finishedWork.calls[0].result?.text == "中文执行完成",
            "原工具记录校正为 finished 后未完成或重复了调用")

        var correctedText = Transcript(root: "/fixture", records: [Record(block: .text("文字草稿"), generation: "streaming")])
        correctedText.replaceRecord(at: 0, with: Record(block: .text("最终文字"), generation: "complete"))
        guard correctedText.items.count == 1, case .text(let finalText) = correctedText.items[0].kind else {
            fatalError("最终文字校正改变了记录数量或种类")
        }
        require(finalText == "最终文字" && correctedText.items[0].generation == "complete",
            "最终文字没有替换草稿或清除生成状态")
        correctedText.records.append(completedTool)
        correctedText.replaceRecord(at: 0, with: Record(block: .thinking("改种类的思考")))
        guard case .thinking(let changedKind) = correctedText.items[0].kind else {
            fatalError("种类变化未重建显示分组")
        }
        require(changedKind == "改种类的思考", "种类变化保留了旧正文")
        correctedText.replaceRecord(at: 0, with: Record(parent: "stream-call", block: .thinking("改父级的思考")))
        guard correctedText.items.count == 1, case .work(let reparentedWork) = correctedText.items[0].kind,
              reparentedWork.calls[0].children.count == 1,
              case .thinking(let reparentedText) = reparentedWork.calls[0].children[0].kind else {
            fatalError("parent 变化未把记录移入正确工具的子调用")
        }
        require(reparentedText == "改父级的思考", "parent 变化丢失或重复了记录")

        var transcript = Transcript(root: "/fixture")
        for remote in records {
            guard let record = remote.record else { fatalError("投影记录未解码：\(remote.id)") }
            transcript.records.append(record)
            if remote.block.type == "tool_result" && remote.block.call == "top-before" {
                verify(transcript, before: "top-before", thought: "顶层思考", after: "top-after")
            }
            if remote.block.type == "tool_result" && remote.block.call == "child-before" {
                verifyChild(transcript)
            }
        }
        verify(transcript, before: "top-before", thought: "顶层思考", after: "top-after")
        verifyChild(transcript)
        guard let resultIndex = records.firstIndex(where: { $0.block.type == "tool_result" && $0.block.call == "top-before" }),
              case .toolResult(let savedResult) = transcript.records[resultIndex].block else {
            fatalError("缺少可校正的工具结果记录")
        }
        let correctedResult = ToolResult(call: savedResult.call, content: [.text("完成 top-before，结果已校正")],
            isError: savedResult.isError, interrupted: savedResult.interrupted,
            unknown: savedResult.unknown, diff: savedResult.diff)
        transcript.replaceRecord(at: resultIndex,
            with: Record(parent: transcript.records[resultIndex].parent, block: .toolResult(correctedResult)))
        require(transcript.records.count == records.count, "同种结果校正新增了记录")
        verify(transcript, before: "top-before", thought: "顶层思考", after: "top-after")
        verifyChild(transcript)
        guard case .work(let firstWork) = transcript.items[0].kind else { fatalError("缺少首个工具组") }
        require(firstWork.calls[0].result?.text == "完成 top-before，结果已校正",
            "同种结果校正没有归并回原工具调用")
        require(firstWork.calls[0].result?.diff?.id == CommandLine.arguments[4]
            && firstWork.calls[0].result?.diff?.paths == ["目录/带 空格.ts"],
            "journal 和显示投影中的 diff 引用未抵达 Swift 工具结果")
        print("投影记录经 Swift 解码后保持独立思考、工具分组与迟到结果")
    }

    private static func verify(_ transcript: Transcript, before: String, thought: String, after: String) {
        let items = transcript.items
        guard items.count >= 3,
              case .work(let first) = items[0].kind,
              case .thinking(let text) = items[1].kind,
              case .work(let second) = items[2].kind else {
            fatalError("思考未分开前后工具组")
        }
        require(text == thought && first.calls.count == 1 && second.calls.count == 1,
            "工具组或思考内容不正确")
        require(first.calls[0].use.id == before && second.calls[0].use.id == after,
            "工具组顺序错误")
        require(first.calls[0].result?.text.contains("完成 \(before)") == true,
            "思考后到达的结果未回填到思考前的工具")
    }

    private static func verifyChild(_ transcript: Transcript) {
        guard transcript.items.count >= 3,
              case .work(let top) = transcript.items[2].kind,
              top.calls.count == 1 else { fatalError("缺少顶层工具") }
        let children = top.calls[0].children
        guard children.count >= 3,
              case .work(let first) = children[0].kind,
              case .thinking(let text) = children[1].kind,
              case .work(let second) = children[2].kind else {
            let shape = children.map { item -> String in
                switch item.kind {
                case .work(let work): return "work:\(work.calls.map { $0.use.id })"
                case .thinking(let text): return "thinking:\(text)"
                default: return "other"
                }
            }
            fatalError("子调用思考未分开工具组：\(shape)")
        }
        require(text == "子调用思考" && first.calls.count == 1 && second.calls.count == 1,
            "子调用内容或分组错误")
        require(first.calls[0].use.id == "child-before"
            && second.calls[0].use.id == "child-after"
            && first.calls[0].result?.text.contains("完成 child-before") == true,
            "子调用迟到结果未回填原调用")
    }
}
  `.replace(/\\u([0-9A-Fa-f]{4})/g, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16))));
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const executable = join(root, 'transcript-contract');
  await command([
    compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`, '-parse-as-library',
    join(app, 'Conversation', 'Transcript.swift'), extracted, fixture, '-o', executable,
  ], root);
  console.log(await command([executable, recordsPath, statesPath, streamPath, patchResult.diff!.id], root));
} finally {
  rmSync(root, { recursive: true, force: true });
}
