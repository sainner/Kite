/** 原生记录的调试查看：harness 的 journal 与 Claude 的会话文件逐条原样给出，按时间合在一起；只读，不经显示投影。 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface RawEntry {
  source: 'harness' | 'claude';
  /** 在各自文件里是第几条，从 0 起。 */
  index: number;
  /** 毫秒时间；没有时间的条目沿用同一文件里前一条的，开头就没有的为 null。 */
  at: number | null;
  /** 一行的摘要：类型，加上最能区分它的一两个字段。 */
  label: string;
  /** 缩进好的原文；图片的 base64 换成占位。 */
  text: string;
}

export interface RawPage {
  /** 两个文件现有的条数，下次从这里接着读。 */
  journal: number;
  claude: number;
  /** 给的起点超出现有条数（记录被整份换掉，如流转导入、还原），这一页从头给。 */
  reset: boolean;
  entries: RawEntry[];
}

const object = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
const string = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined;

/** 只读完整的行，写到一半的尾巴不算；解析不了的行照原文给出。 */
function lines(path: string | undefined): unknown[] {
  if (!path || !existsSync(path)) return [];
  const text = readFileSync(path, 'utf8');
  return text.slice(0, text.lastIndexOf('\n') + 1).split('\n').filter(Boolean).map((line) => {
    try { return JSON.parse(line) as unknown; } catch { return line; }
  });
}

/** 图片的 base64 动辄几百 KB，换成占位；其余原样。 */
function elide(value: unknown, key?: string): unknown {
  if (typeof value === 'string') {
    return key === 'data' && value.length > 1024 && /^[A-Za-z0-9+/=\r\n]+$/.test(value)
      ? `[base64 已省略，约 ${Math.round(value.length * 3 / 4 / 1024)}KB]` : value;
  }
  if (Array.isArray(value)) return value.map((item) => elide(item));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, elide(item, name)]));
  return value;
}

function harnessLabel(row: Record<string, unknown>): string {
  const detail = (): unknown[] => {
    switch (row.type) {
      case 'model.item': {
        const raw = object(object(row.item).raw);
        return [raw.type, raw.name];
      }
      case 'input.received': return [object(row.input).source];
      case 'tool.finished': return [object(row.result).status];
      case 'turn.finished': return [object(row.outcome).kind];
      default: return [];
    }
  };
  const parts = detail().filter((part) => typeof part === 'string');
  return [string(row.type) ?? '?', parts.join(' ')].filter(Boolean).join(' · ');
}

function claudeLabel(entry: Record<string, unknown>): string {
  const content = object(entry.message).content;
  const blocks = Array.isArray(content)
    ? content.map((block) => [object(block).type, object(block).name].filter((part) => typeof part === 'string').join(' ')) : [];
  return [[string(entry.type) ?? '?', string(entry.subtype)].filter(Boolean).join(' '), blocks.join(', ')].filter(Boolean).join(' · ');
}

/** 每条的时间，没有的沿用前一条。 */
function times(rows: unknown[], at: (row: Record<string, unknown>) => number | undefined): (number | null)[] {
  let last: number | null = null;
  return rows.map((row) => {
    const value = at(object(row));
    if (value !== undefined && Number.isFinite(value)) last = value;
    return last;
  });
}

/** from 是上次读到的两份的条数；两份各按文件顺序，按时间交错合并。 */
export function readRaw(sessionDirectory: string, claudePath: string | undefined, from: { journal: number; claude: number }): RawPage {
  const journal = lines(join(sessionDirectory, 'journal.jsonl'));
  const claude = lines(claudePath);
  const reset = from.journal > journal.length || from.claude > claude.length;
  let i = reset ? 0 : from.journal, j = reset ? 0 : from.claude;
  const journalAt = times(journal, (row) => typeof row.at === 'number' ? row.at : undefined);
  const claudeAt = times(claude, (entry) => typeof entry.timestamp === 'string' ? Date.parse(entry.timestamp) : undefined);
  const entry = (source: RawEntry['source'], row: unknown, index: number, at: number | null): RawEntry => ({
    source, index, at,
    label: typeof row === 'string' ? '无法解析的行' : source === 'harness' ? harnessLabel(object(row)) : claudeLabel(object(row)),
    text: typeof row === 'string' ? row : JSON.stringify(elide(row), null, 2),
  });
  const entries: RawEntry[] = [];
  while (i < journal.length || j < claude.length) {
    if (j >= claude.length || (i < journal.length && (journalAt[i] ?? -Infinity) <= (claudeAt[j] ?? -Infinity))) {
      entries.push(entry('harness', journal[i], i, journalAt[i] ?? null));
      i++;
    } else {
      entries.push(entry('claude', claude[j], j, claudeAt[j] ?? null));
      j++;
    }
  }
  return { journal: journal.length, claude: claude.length, reset, entries };
}
