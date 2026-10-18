/**
 * tool search 探测：deferred tools 在 ChatGPT 订阅接口与 DeepSeek Responses 接口上能不能用。
 * 用法：bun probe.ts chatgpt|deepseek [模型] [用例...]，用例为 hosted、client、additional、size、persist，缺省全跑。
 * 会真实发请求：ChatGPT 用 ~/.kite 的订阅凭据；DeepSeek 用 DEEPSEEK_API_KEY，没有时照 kited 的做法取 Kite 账号凭据里的第一把
 * DeepSeek Key。凭据密钥只读：有 credentials.key 用文件，否则读钥匙串，找不到就报错，不新建。
 */
import { Database } from 'bun:sqlite';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { AccountData } from '../../kited/src/account-data/store.ts';
import { Credentials } from '../../kited/src/account-data/credentials.ts';
import { readSubscriptionCredentials } from '../../kited/src/harness/auth.ts';
import { deepseekKey } from '../../kited/src/harness/adapters.ts';

type Json = Record<string, any>;
const provider = process.argv[2] as 'chatgpt' | 'deepseek';
if (provider !== 'chatgpt' && provider !== 'deepseek') throw new Error('第一个参数是 chatgpt 或 deepseek');
const model = process.argv[3] ?? (provider === 'chatgpt' ? 'gpt-6-luna' : 'deepseek-flash');
const cases = process.argv.slice(4).length ? process.argv.slice(4) : ['hosted', 'client', 'additional', 'size', 'persist'];
const home = process.env.KITE_HOME ?? join(homedir(), '.kite');

async function sealingKey(machine: string): Promise<Buffer> {
  const file = join(home, 'credentials.key');
  const text = existsSync(file) ? readFileSync(file, 'utf8') : await (async () => {
    const child = Bun.spawn(['/usr/bin/security', 'find-generic-password', '-s', 'Kite 凭据', '-a', machine, '-w'], {
      env: { HOME: process.env.HOME ?? '', PATH: '/usr/bin:/bin' }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
    const [stdout, code] = await Promise.all([new Response(child.stdout).text(), child.exited]);
    if (code !== 0) throw new Error(`钥匙串里没有读到凭据密钥（${code}）`);
    return stdout;
  })();
  return Buffer.from(text.trim(), 'hex');
}

async function accountDeepseekKey(): Promise<string | undefined> {
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY;
  const db = new Database(join(home, 'kite.db'), { readonly: true });
  const machine = (db.query('select id from machine where slot = 1').get() as { id: string }).id;
  db.close();
  const data = new AccountData(join(home, 'account.db'), machine, () => sealingKey(machine));
  try {
    const credentials = new Credentials(data, { projectExists: () => true, canonicalProject: () => undefined });
    return await deepseekKey(() => credentials.apiKeys());
  } finally { data.close(); }
}

const transport = provider === 'chatgpt' ? await (async () => {
  const auth = await readSubscriptionCredentials();
  const session = crypto.randomUUID();
  return {
    url: 'https://chatgpt.com/backend-api/codex/responses',
    headers: { authorization: `Bearer ${auth.accessToken}`, 'ChatGPT-Account-Id': auth.accountId, originator: 'kite',
      'user-agent': 'kite-harness/0.1', session_id: session },
    extra: { parallel_tool_calls: true, store: false, include: ['reasoning.encrypted_content'],
      reasoning: { effort: 'low', summary: 'concise' }, prompt_cache_key: session },
  };
})() : await (async () => {
  const key = await accountDeepseekKey();
  if (!key) throw new Error('没有 DeepSeek 的 API Key');
  return { url: 'https://api.deepseek.com/responses', headers: { authorization: `Bearer ${key}`, 'user-agent': 'kite-harness/0.1' },
    extra: { reasoning: { effort: 'medium' } } };
})();

interface Reply { status: number; error?: string; events: string[]; output: Json[]; usage?: Json }

/** 发一次流式请求，收齐输出条目、用量与出现过的事件类型。 */
async function send(body: Json): Promise<Reply> {
  const response = await fetch(transport.url, {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(120_000),
    headers: { ...transport.headers, 'content-type': 'application/json', accept: 'text/event-stream' },
    body: JSON.stringify({ model, ...transport.extra, ...body, stream: true }),
  });
  if (!response.ok) return { status: response.status, error: (await response.text()).slice(0, 600), events: [], output: [] };
  const events = new Set<string>();
  const done: Json[] = [];
  let completed: Json | undefined;
  let failure: string | undefined;
  let buffer = '';
  const decoder = new TextDecoder();
  for await (const chunk of response.body!) {
    buffer += decoder.decode(chunk, { stream: true });
    let end: number;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      const data = block.split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
      if (!data || data === '[DONE]') continue;
      const event = JSON.parse(data) as Json;
      events.add(event.type);
      if (event.type === 'response.output_item.done') done.push(event.item);
      if (event.type === 'response.completed') completed = event.response;
      if (event.type === 'response.failed' || event.type === 'error') failure = JSON.stringify(event).slice(0, 600);
    }
  }
  const output = completed?.output?.length ? completed.output : done;
  return { status: response.status, ...(failure ? { error: failure } : {}), events: [...events], output, usage: completed?.usage };
}

const parameters = { type: 'object', properties: { project: { type: 'string', description: '项目名' } }, required: ['project'], additionalProperties: false };
const getCode = { type: 'function', name: 'get_code', description: '查询某个项目的暗号。', parameters };
const instructions = '你是测试助手。任务需要的工具不在当前列表里时，先用 tool_search 找。';
const ask = { role: 'user', content: '用工具查一下项目 kite 的暗号，只回答暗号本身。' };
const search = { type: 'tool_search', execution: 'client', description: '按目标查找继续任务需要的项目工具。',
  parameters: { type: 'object', properties: { goal: { type: 'string' } }, required: ['goal'], additionalProperties: false } };

/** 跑到模型给出正文为止：函数调用回暗号，客户端搜索回 get_code 的定义。 */
async function loop(name: string, tools: Json[] | undefined, input: Json[], expect = 'PEAR-42'): Promise<Json[]> {
  const trace: Json[] = [];
  for (let round = 0; round < 4; round++) {
    const reply = await send({ instructions, input, ...(tools ? { tools, tool_choice: 'auto' } : {}) });
    trace.push({ status: reply.status, error: reply.error, events: reply.events.filter((type) => /tool_search|function_call|output_item/.test(type)),
      items: reply.output.map((item) => item.type + (item.name ? `:${item.name}` : '') + (item.execution ? `(${item.execution})` : '')),
      inputTokens: reply.usage?.input_tokens });
    if (reply.error) break;
    input.push(...reply.output);
    const pending = reply.output.filter((item) => item.type === 'function_call' || (item.type === 'tool_search_call' && item.execution === 'client'));
    if (!pending.length) {
      const text = reply.output.filter((item) => item.type === 'message').flatMap((item) => item.content ?? []).map((part: Json) => part.text ?? '').join('');
      console.log(JSON.stringify({ case: name, provider, model, answered: text.includes(expect), text: text.slice(0, 200), trace }));
      return input;
    }
    for (const item of pending) {
      if (item.type === 'function_call') input.push({ type: 'function_call_output', call_id: item.call_id, output: item.name !== 'get_code' ? '没有这个工具' : JSON.parse(item.arguments).project === 'line' ? 'PLUM-7' : 'PEAR-42' });
      else input.push({ type: 'tool_search_output', execution: 'client', call_id: item.call_id, status: 'completed', tools: [{ ...getCode, defer_loading: true }] });
    }
  }
  console.log(JSON.stringify({ case: name, provider, model, answered: false, trace }));
  return input;
}

/** 一段很长的工具说明，用来看 defer_loading 后输入用量有没有降下来。 */
const filler = Array.from({ length: 60 }, (_, i) => `第 ${i + 1} 条规则：盘点仓库 ${i} 号货架时，先核对条码、批次与保质期，再记录数量差异并说明原因。`).join('');
const report = { type: 'function', name: 'inventory_report', description: `生成仓库盘点报告。${filler}`,
  parameters: { type: 'object', properties: Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`field_${i}`, { type: 'string', description: `第 ${i} 个统计字段的筛选条件` }])), additionalProperties: false } };

async function size() {
  const quiet = [{ role: 'user', content: '只回答 OK，不要调用任何工具。' }];
  const variants: Record<string, Json[]> = {
    small: [getCode],
    eager: [getCode, report],
    deferred: [{ type: 'tool_search' }, getCode, { ...report, defer_loading: true }],
    namespaced: [{ type: 'tool_search' }, getCode, { type: 'namespace', name: 'inventory', description: '仓库盘点与报告。', tools: [{ ...report, defer_loading: true }] }],
  };
  const result: Json = {};
  for (const [name, tools] of Object.entries(variants)) {
    const reply = await send({ instructions, input: structuredClone(quiet), tools, tool_choice: 'auto' });
    result[name] = reply.error ? { status: reply.status, error: reply.error } : { inputTokens: reply.usage?.input_tokens };
  }
  console.log(JSON.stringify({ case: 'size', provider, model, result }));
}

for (const name of cases) {
  if (name === 'hosted') await loop('hosted', [{ type: 'tool_search' },
    { type: 'namespace', name: 'project', description: '项目信息查询，例如暗号。', tools: [{ ...getCode, defer_loading: true }] }], [ask]);
  if (name === 'client') await loop('client', [search], [ask]);
  // 客户端搜索加载的工具，下一回合是否不用再搜就能调用。
  if (name === 'persist') {
    const input = await loop('persist-1', [search], [ask]);
    await loop('persist-2', [search], [...input, { role: 'user', content: '再查一下项目 line 的暗号，只回答暗号本身。' }], 'PLUM-7');
  }
  if (name === 'additional') await loop('additional', undefined, [
    { role: 'user', content: '先回答 OK。' }, { role: 'assistant', content: 'OK' },
    { type: 'additional_tools', role: 'developer', tools: [getCode] }, ask]);
  if (name === 'size') await size();
}
