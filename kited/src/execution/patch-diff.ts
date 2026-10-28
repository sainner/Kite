/** patch 工具对单个文件应用补丁：先按上游 V4A 整行匹配，对不上时按原文片段替换，接住只写行内一段的写法。 */
import { applyDiff } from '@openai/agents-core/utils';

/** 应用无文件头的 V4A diff，create 时生成新文件正文。失败时抛出的原因直接给模型看。 */
export function applyPatchDiff(original: string, diff: string, create: boolean): string {
  const lines = diff.replace(/\r\n/g, '\n').split('\n');
  if (lines.at(-1) === '') lines.pop();
  // applyDiff 接收单文件正文；拒绝包装头，避免上游把它当终止符而忽略后续内容。
  if (lines.some((line, i) => line.startsWith('***') && (line !== '*** End of File' || i !== lines.length - 1))) {
    throw new Error('diff 必须是无文件头的 V4A 补丁');
  }
  if (create) {
    const invalid = lines.find((line) => !line.startsWith('+'));
    if (invalid !== undefined) throw new Error(`新建文件的每行都要以 + 开头：${invalid}`);
    return applyDiff('', diff, 'create');
  }
  try { return applyDiff(original, diff); }
  catch { return splice(original, lines.at(-1) === '*** End of File' ? lines.slice(0, -1) : lines); }
}

/**
 * 整行对不上时的退路：每段的上下文行和删除行连起来是一段原文，要在当前内容里恰好出现一次，
 * 换成上下文行和新增行连起来的新文。逐段在前一段的结果上替换。
 */
function splice(original: string, lines: string[]): string {
  // 与上游一样，整篇都是 CRLF 时按 LF 匹配，写回时还原。
  const crlf = original.includes('\r\n') && !/(^|[^\r])\n/.test(original);
  let text = crlf ? original.replaceAll('\r\n', '\n') : original;
  const sections: string[][] = [[]];
  for (const line of lines) {
    if (line.startsWith('@@')) sections.push([]);
    else sections.at(-1)!.push(line);
  }
  // 连续的 @@ 是逐层的定位锚点，只有最后一个带正文。
  for (const section of sections.filter((section) => section.length)) {
    const before: string[] = [];
    const after: string[] = [];
    for (const line of section) {
      const mark = line[0] ?? ' ';
      if (mark !== ' ' && mark !== '-' && mark !== '+') throw new Error(`修改的每行要以空格、- 或 + 开头：${line}`);
      if (mark !== '+') before.push(line.slice(1));
      if (mark !== '-') after.push(line.slice(1));
    }
    const old = before.join('\n');
    if (!old) throw new Error(`有一段只有新增行，定不了插在哪里：\n${after.join('\n')}`);
    const at = text.indexOf(old);
    if (at === -1) throw new Error(`原文里找不到这段，请 read 后重新生成；上下文行和删除行要逐字照抄原文：\n${old}`);
    if (text.indexOf(old, at + 1) !== -1) throw new Error(`这段在原文里不止一处，多带几行上下文：\n${old}`);
    text = text.slice(0, at) + after.join('\n') + text.slice(at + old.length);
  }
  return crlf ? text.replaceAll('\n', '\r\n') : text;
}
