/**
 * 识别之后的确定性整理，不用 LLM：把夹在英文之间念出来的「点」「斜杠」「杠」「下划线」还原成符号，
 * 再把一串英文词按对话里出现过的标识符恢复写法（大小写、连写、点和斜杠）。
 * 用法：bun restore.ts <样本目录> [结果 JSON，默认取最新的]：对已有结果离线整理，比较整理前后的得分。
 */
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { errorRate, exactHits, termHits } from './score.ts';

const separators: [RegExp, string][] = [[/点/g, '.'], [/(?:斜杠|邪杠|斜线)/g, '/'], [/下划线/g, '_'], [/(?:横杠|中杠|杠)/g, '-']];
/** 一个英文词，或者夹在两个英文词之间的分隔：空白、符号、念出来的符号。 */
const run = /[A-Za-z0-9]+(?:(?:\s|[./_-]|点|斜杠|邪杠|斜线|下划线|横杠|中杠|杠)+[A-Za-z0-9]+)*/g;

/** 对话里出现过的标识符，按只留字母数字、转小写后的样子索引。 */
export function identifiers(text: string) {
  const index = new Map<string, string>();
  for (const word of text.match(/\.?[A-Za-z][\w./-]*\w/g) ?? []) {
    const key = word.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (key.length >= 4 && /[A-Z./_-]|[a-z][A-Z]/.test(word.slice(1))) index.set(key, word);
  }
  return index;
}

export function restore(text: string, known: Map<string, string>) {
  return text.replace(run, (span) => {
    const words = span.split(/(?:\s|[./_-]|点|斜杠|邪杠|斜线|下划线|横杠|中杠|杠)+/);
    const pieces: string[] = [];
    for (let start = 0; start < words.length;) {
      // 从最长的一串往短了找对话里出现过的标识符
      let matched = 0;
      for (let end = words.length; end > start; end--) {
        const identifier = known.get(words.slice(start, end).join('').toLowerCase());
        if (identifier) {
          pieces.push(identifier);
          matched = end - start;
          break;
        }
      }
      if (matched) {
        start += matched;
        continue;
      }
      pieces.push(words[start]!);
      start++;
    }
    if (pieces.length === words.length && !pieces.some((piece, index) => piece !== words[index])) return generic(span);
    return pieces.join(' ');
  });
}

/** 没有对上标识符时只换念出来的符号；「点」后面单念的字母连起来，如「点 t s」写成 .ts。 */
function generic(span: string) {
  let result = span;
  for (const [pattern, symbol] of separators) result = result.replace(new RegExp(`\\s*${pattern.source}\\s*`, 'g'), symbol);
  return result.replace(/\.((?:[a-z]\s)+[a-z])\b/g, (_, letters: string) => `.${letters.replace(/\s/g, '')}`);
}

if (import.meta.main) {
  const [root, file] = process.argv.slice(2);
  if (!root) {
    console.error('用法：bun restore.ts <样本目录> [结果 JSON]');
    process.exit(1);
  }
  const results = file ?? join(root, (await readdir(root)).filter((name) => name.startsWith('results-')).sort().at(-1)!);
  const rows = await Bun.file(results).json() as { sample: string; provider: string; context: boolean; run: { final: string; error?: string } }[];
  const groups = new Map<string, { before: number[]; after: number[]; loose: [number, number]; exact: [number, number]; total: number }>();
  for (const row of rows.filter((row) => !row.run.error)) {
    const directory = join(root, row.sample);
    const reference = (await Bun.file(join(directory, 'reference.txt')).text()).trim();
    const terms = (await Bun.file(join(directory, 'terms.txt')).text()).split('\n').map((line) => line.trim()).filter(Boolean);
    const context = Bun.file(join(directory, 'context.txt'));
    const known = row.context && await context.exists() ? identifiers(await context.text()) : new Map<string, string>();
    const restored = restore(row.run.final, known);
    const key = `${row.provider}｜${row.context ? '带上下文' : '无上下文'}`;
    const group = groups.get(key) ?? { before: [], after: [], loose: [0, 0], exact: [0, 0], total: 0 };
    group.before.push(errorRate(row.run.final, reference));
    group.after.push(errorRate(restored, reference));
    group.loose[0] += termHits(row.run.final, terms).hit.length;
    group.loose[1] += termHits(restored, terms).hit.length;
    group.exact[0] += exactHits(row.run.final, terms).length;
    group.exact[1] += exactHits(restored, terms).length;
    group.total += terms.length;
    groups.set(key, group);
    if (restored !== row.run.final) console.log(`${row.sample}｜${key}\n  前：${row.run.final}\n  后：${restored}`);
  }
  const mean = (values: number[]) => `${(values.reduce((sum, value) => sum + value, 0) / values.length * 100).toFixed(1)}%`;
  console.log('\n整理前 → 整理后（关键词「大致」不分大小写和符号，「照原样」要大小写和符号都对）');
  for (const [key, group] of groups) {
    console.log(`${key}｜字错 ${mean(group.before)} → ${mean(group.after)}｜关键词大致 ${group.loose[0]} → ${group.loose[1]}/${group.total}`
      + `｜照原样 ${group.exact[0]} → ${group.exact[1]}/${group.total}`);
  }
}
