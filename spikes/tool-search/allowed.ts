/**
 * ChatGPT 订阅接口上，tool_choice 的 allowed_tools 与客户端搜索加载的工具怎么配合。
 * 用法：bun allowed.ts [模型] [用例...]，用例为 listed、unlisted、search-only、fn-search、later-listed、later-unlisted，缺省全跑。
 * 会用 ~/.kite 的订阅凭据真实发请求。
 * - listed：搜索加载 get_code 之后，allowed_tools 列上 get_code（它不在顶层 tools 里），看接口收不收、模型能不能调。
 * - unlisted：加载之后 allowed_tools 不列 get_code，看模型还能不能调；能调就说明限制不了加载的工具，撤权只能靠调用时核验。
 * - search-only：第一次请求的 allowed_tools 只列 note，不列 tool_search，看模型还能不能搜。
 * - fn-search：把 tool_search 当成函数名列进 allowed_tools。
 * - later-listed、later-unlisted：搜索那次不限制（auto），加载之后才用 allowed_tools，分别列与不列 get_code。
 */
import { readSubscriptionCredentials } from '../../kited/src/harness/auth.ts';

type Json = Record<string, any>;
const model = process.argv[2] ?? 'gpt-6-luna';
const cases = process.argv.slice(3).length ? process.argv.slice(3) : ['listed', 'unlisted', 'search-only', 'fn-search', 'later-listed', 'later-unlisted'];
const auth = await readSubscriptionCredentials();
const session = crypto.randomUUID();

async function send(body: Json): Promise<{ status: number; error?: string; output: Json[] }> {
  const response = await fetch('https://chatgpt.com/backend-api/codex/responses', {
    method: 'POST', redirect: 'error', signal: AbortSignal.timeout(120_000),
    headers: { authorization: `Bearer ${auth.accessToken}`, 'ChatGPT-Account-Id': auth.accountId, originator: 'kite', 'user-agent': 'kite-harness/0.1',
      session_id: session, 'content-type': 'application/json', accept: 'text/event-stream' },
    body: JSON.stringify({ model, parallel_tool_calls: true, store: false, include: ['reasoning.encrypted_content'],
      reasoning: { effort: 'low', summary: 'concise' }, prompt_cache_key: session, stream: true, ...body }),
  });
  if (!response.ok) return { status: response.status, error: (await response.text()).slice(0, 600), output: [] };
  let completed: Json | undefined;
  const done: Json[] = [];
  let buffer = '';
  const decoder = new TextDecoder();
  for await (const chunk of response.body!) {
    buffer += decoder.decode(chunk, { stream: true });
    let end: number;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const data = buffer.slice(0, end).split('\n').filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim()).join('\n');
      buffer = buffer.slice(end + 2);
      if (!data || data === '[DONE]') continue;
      const event = JSON.parse(data) as Json;
      if (event.type === 'response.output_item.done') done.push(event.item);
      if (event.type === 'response.completed') completed = event.response;
      if (event.type === 'response.failed' || event.type === 'error') return { status: 200, error: JSON.stringify(event).slice(0, 600), output: done };
    }
  }
  return { status: response.status, output: completed?.output?.length ? completed.output : done };
}

const note = { type: 'function', name: 'note', description: '记一条笔记。', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'], additionalProperties: false } };
const getCode = { type: 'function', name: 'get_code', description: '查询某个项目的暗号。', defer_loading: true,
  parameters: { type: 'object', properties: { project: { type: 'string' } }, required: ['project'], additionalProperties: false } };
const search = { type: 'tool_search', execution: 'client', description: '按目标查找继续任务需要的项目工具。',
  parameters: { type: 'object', properties: { goal: { type: 'string' } }, required: ['goal'], additionalProperties: false } };
const tools = [search, note];
const instructions = '你是测试助手。任务需要的工具不在当前列表里时，先用 tool_search 找。';
const ask = { role: 'user', content: '用工具查一下项目 kite 的暗号，只回答暗号本身。' };
const allowed = (...names: Json[]) => ({ type: 'allowed_tools', mode: 'auto', tools: names });
const kinds = (output: Json[]) => output.map((item) => item.type + (item.name ? `:${item.name}` : '') + (item.execution ? `(${item.execution})` : ''));

/** 第一次请求用 first 的 tool_choice，加载 get_code 之后的请求用 later 的；跑到给出正文为止。 */
async function run(name: string, first: Json | string, later: Json | string) {
  const input: Json[] = [ask];
  const trace: Json[] = [];
  for (let round = 0; round < 4; round++) {
    const loaded = input.some((item) => item.type === 'tool_search_output');
    const reply = await send({ instructions, input, tools, tool_choice: loaded ? later : first });
    trace.push({ status: reply.status, error: reply.error, items: kinds(reply.output) });
    if (reply.error) break;
    input.push(...reply.output);
    const pending = reply.output.filter((item) => item.type === 'function_call' || (item.type === 'tool_search_call' && item.execution === 'client'));
    if (!pending.length) {
      const text = reply.output.filter((item) => item.type === 'message').flatMap((item) => item.content ?? []).map((part: Json) => part.text ?? '').join('');
      console.log(JSON.stringify({ case: name, model, answered: text.includes('PEAR-42'), text: text.slice(0, 160), trace }));
      return;
    }
    for (const item of pending) {
      if (item.type === 'function_call') input.push({ type: 'function_call_output', call_id: item.call_id, output: item.name === 'get_code' ? 'PEAR-42' : 'ok' });
      else input.push({ type: 'tool_search_output', execution: 'client', call_id: item.call_id, status: 'completed', tools: [getCode] });
    }
  }
  console.log(JSON.stringify({ case: name, model, answered: false, trace }));
}

for (const name of cases) {
  const searchChoice = { type: 'tool_search' };
  if (name === 'listed') await run(name, allowed(searchChoice, { type: 'function', name: 'note' }),
    allowed(searchChoice, { type: 'function', name: 'note' }, { type: 'function', name: 'get_code' }));
  if (name === 'unlisted') await run(name, allowed(searchChoice, { type: 'function', name: 'note' }),
    allowed(searchChoice, { type: 'function', name: 'note' }));
  if (name === 'search-only') await run(name, allowed({ type: 'function', name: 'note' }), 'auto');
  if (name === 'fn-search') await run(name, allowed({ type: 'function', name: 'note' }, { type: 'function', name: 'tool_search' }), 'auto');
  if (name === 'later-listed') await run(name, 'auto', allowed({ type: 'function', name: 'note' }, { type: 'function', name: 'get_code' }));
  if (name === 'later-unlisted') await run(name, 'auto', allowed({ type: 'function', name: 'note' }));
}
