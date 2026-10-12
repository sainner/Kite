/**
 * 识别之后的确定性整理，不用 LLM：夹在英文之间念出来的「点」「斜杠」「杠」「下划线」换成符号，「点」后面单念的字母连起来；
 * 一串英文词对得上上下文里出现过的标识符时，按标识符的写法恢复（大小写、连写、点和斜杠）。依据见 docs/research/2026-10-12-语音识别选型.md。
 */
const spoken = '点|斜杠|邪杠|斜线|下划线|横杠|中杠|杠';
const separators: [string, string][] = [['点', '.'], ['斜杠|邪杠|斜线', '/'], ['下划线', '_'], ['横杠|中杠|杠', '-']];
/** 一串英文词，词之间可以隔着空白、符号或念出来的符号。 */
const run = new RegExp(`[A-Za-z0-9]+(?:(?:\\s|[./_-]|${spoken})+[A-Za-z0-9]+)*`, 'g');
const gap = new RegExp(`(?:\\s|[./_-]|${spoken})+`);

/** 上下文里像标识符的词（带大写、点、斜杠、横线或下划线），按只留字母数字、转小写后的样子索引。 */
export function identifiers(text: string): Map<string, string> {
  const index = new Map<string, string>();
  for (const word of text.match(/\.?[A-Za-z][\w./-]*\w/g) ?? []) {
    const key = word.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (key.length >= 4 && /[A-Z./_-]/.test(word.slice(1))) index.set(key, word);
  }
  return index;
}

export function restore(text: string, known: Map<string, string>): string {
  return text.replace(run, (span) => {
    const words = span.split(gap);
    const pieces: string[] = [];
    let changed = false;
    for (let start = 0; start < words.length;) {
      // 从最长的一串往短了找认识的标识符
      let end = words.length;
      for (; end > start; end--) {
        const identifier = known.get(words.slice(start, end).join('').toLowerCase());
        if (identifier) {
          pieces.push(identifier);
          changed = true;
          break;
        }
      }
      if (end > start) {
        start = end;
      } else {
        pieces.push(words[start]!);
        start++;
      }
    }
    return changed ? pieces.join(' ') : symbols(span);
  });
}

function symbols(span: string): string {
  let result = span;
  for (const [word, symbol] of separators) result = result.replace(new RegExp(`\\s*(?:${word})\\s*`, 'g'), symbol);
  return result.replace(/\.((?:[a-z]\s)+[a-z])\b/g, (_, letters: string) => `.${letters.replace(/\s/g, '')}`);
}
