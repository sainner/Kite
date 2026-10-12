/** 打分：字错率、关键词命中，以及从对话里取上下文。 */
import type { Context } from './providers.ts';

/** 对话按空行分轮；英文标识、文件名、命令另摘一份词表。 */
export function contextOf(conversation: string): Context {
  const turns = conversation.split(/\n\s*\n/).map((turn) => turn.trim()).filter(Boolean);
  const words = [...new Set(conversation.match(/[A-Za-z][\w./-]*[\w]/g) ?? [])].filter((word) => word.length >= 3).slice(-100);
  return { turns, words };
}

/** 去掉空白和标点、英文不分大小写后，按字算编辑距离。 */
export function normalize(value: string) {
  return Array.from(value.toLowerCase().replace(/[\s\p{P}\p{S}]/gu, ''));
}

export function errorRate(hypothesis: string, reference: string) {
  const a = normalize(hypothesis), b = normalize(reference);
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j]! + 1, current[j - 1]! + 1, previous[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return b.length ? previous[b.length]! / b.length : 0;
}

export function termHits(hypothesis: string, terms: string[]) {
  const said = normalize(hypothesis).join('');
  const hit = terms.filter((term) => said.includes(normalize(term).join('')));
  return { hit, missed: terms.filter((term) => !hit.includes(term)) };
}

/** 照原样（大小写、点、斜杠、横线都对）出现在定稿里的关键词。 */
export function exactHits(hypothesis: string, terms: string[]) {
  return terms.filter((term) => hypothesis.includes(term));
}
