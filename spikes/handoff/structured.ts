import { fakeApi, isolated, drive, sessionFile } from './native.ts';
import { mkdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const out = resolve(process.argv[2]); const cwd = join(out, 'work'); mkdirSync(cwd, { recursive: true });
const api = fakeApi(); const { options, cfg } = isolated(join(out, 'structured'), api.port, cwd);
const sessionId = crypto.randomUUID();
await drive({ ...options, sessionId, model: 'claude-sonnet-4-5', title: 'x' }, [{ id: crypto.randomUUID(), text: '结构化' }]);
api.stop();
console.log(JSON.stringify(api.log.filter((l) => l.main)[1].body.messages.at(-1)));
for (const line of readFileSync(sessionFile(cfg, sessionId), 'utf8').split('\n').filter(Boolean)) { const r = JSON.parse(line); if (r.toolUseResult) console.log(JSON.stringify({ content: r.message.content, toolUseResult: r.toolUseResult })); }
