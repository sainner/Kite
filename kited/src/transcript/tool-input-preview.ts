import { JSONParser, type ParsedElementInfo } from '@streamparser/json';
import type { JsonObject } from '../harness/types.ts';

/** 只解析工具行需要的字段；参数原文与执行校验仍由调用方保留。 */
export class ToolInputPreview {
  private parser?: JSONParser;
  private input: JsonObject = {};

  constructor(name: string) {
    const paths = name === 'read' ? ['$.path', '$.offset', '$.limit']
      : name === 'shell' ? ['$.description', '$.command']
      : name === 'patch' ? ['$.operations.*.type', '$.operations.*.path'] : [];
    if (!paths.length) return;
    this.parser = new JSONParser({ paths, keepStack: false, emitPartialTokens: true, emitPartialValues: true });
    this.parser.onValue = (value) => this.accept(value);
  }

  append(text: string): JsonObject {
    const previous = this.input;
    try { this.parser?.write(text); }
    catch {
      // 损坏的参数停止预览，保留上一版摘要；全文校正会建立新的解析器。
      this.parser = undefined;
      this.input = previous;
    }
    return this.input;
  }

  private accept({ value, key, stack, partial }: ParsedElementInfo): void {
    if (typeof key !== 'string') return;
    // 字符串可提前显示；数字必须等分隔符确认，不能把半个指数当作最终数值。
    if (typeof value === 'string') {
      if (!value.isWellFormed()) return;
    } else if (partial || typeof value !== 'number' || !Number.isFinite(value)) return;
    if (stack.length === 1) {
      if (this.input[key] !== value) this.input = { ...this.input, [key]: value };
    } else if (stack.length === 3 && typeof stack[2]?.key === 'number') {
      const index = stack[2].key;
      const previous = this.input.operations as JsonObject[] | undefined;
      if (previous?.[index]?.[key] === value) return;
      const operations = [...(previous ?? [])];
      while (operations.length <= index) operations.push({});
      operations[index] = { ...operations[index], [key]: value };
      this.input = { operations };
    }
  }
}
