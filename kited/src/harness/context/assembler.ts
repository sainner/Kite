/** 预览和实际请求共用的纯组装器。不执行模板表达式、不改会话历史；自己不读文件，变量取值交给调用方给的函数。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { contextScenes, notifiedVariables, sceneVariables, type ContextScene, type ContextVariable } from './scenes.ts';
import type {
  ContextAssembly, ContextBinding, ContextBlock, ContextDefinition, ContextSnapshot, ContextSource, ContextValues, ResolvedContextBlock,
} from './types.ts';

const name = z.string().min(1);
const digest = z.string().regex(/^[a-f0-9]{64}$/);
const part = z.discriminatedUnion('type', [
  z.object({ type: z.literal('text'), text: z.string() }).strict(),
  z.object({ type: z.literal('variable'), name }).strict(),
]);
const block: z.ZodType<ContextBlock> = z.lazy(() => z.discriminatedUnion('type', [
  z.object({ type: z.literal('paragraph'), id: name, title: name, parts: z.array(part) }).strict(),
  z.object({
    type: z.literal('condition'), id: name, title: name, variable: name,
    cases: z.array(z.object({ id: name, title: name, equals: z.string(), blocks: z.array(block) }).strict()),
    otherwise: z.object({ id: name, title: name, blocks: z.array(block) }).strict(),
  }).strict(),
]));

/** catalog 为 false 时只查结构：历史快照当时有效，变量目录之后的增删不能让旧记录无法还原。 */
function validateDefinition(definition: ContextSnapshot['definition'], ctx: z.RefinementCtx, catalog = true): void {
  const variables = new Set<string>(sceneVariables(definition.scene).map((variable) => variable.name));
  const ids = new Set<string>();
  const error = (message: string) => ctx.addIssue({ code: 'custom', message });
  if ('input' in contextScenes[definition.scene] !== (definition.input !== undefined)) {
    error(`${contextScenes[definition.scene].title}${'input' in contextScenes[definition.scene] ? '模板须同时包含指令与材料' : '模板仅使用正文'}`);
  }
  const reference = (variable: string) => {
    if (catalog && !variables.has(variable)) error(`当前定义不支持变量：${variable}`);
  };
  const identify = (id: string) => {
    if (ids.has(id)) error(`段落或分支 id 重复：${id}`);
    ids.add(id);
  };
  const visit = (blocks: ContextBlock[]) => {
    for (const item of blocks) {
      identify(item.id);
      if (item.type === 'paragraph') {
        for (const part of item.parts) if (part.type === 'variable') reference(part.name);
      } else {
        reference(item.variable);
        const matches = new Set<string>();
        for (const branch of item.cases) {
          if (matches.has(branch.equals)) error(`条件 ${item.id} 有重复匹配值`);
          matches.add(branch.equals);
        }
        for (const branch of [...item.cases, item.otherwise]) { identify(branch.id); visit(branch.blocks); }
      }
    }
  };
  visit(definition.blocks);
  if (definition.input) visit(definition.input);
}

const definitionShape = z.object({
  version: z.literal(2), id: name, title: name,
  scene: z.enum(Object.keys(contextScenes) as ContextScene[]),
  blocks: z.array(block),
  input: z.array(block).optional(),
}).strict();
export const contextDefinitionSchema: z.ZodType<ContextDefinition> = definitionShape.superRefine((definition, ctx) => validateDefinition(definition, ctx));
const recordedDefinitionSchema: z.ZodType<ContextDefinition> = definitionShape.superRefine((definition, ctx) => validateDefinition(definition, ctx, false));

const bindingsSchema = z.record(z.string(), z.object({
  text: z.string(), sources: z.array(z.object({ path: name, sha256: digest }).strict()).optional(),
}).strict());
type StoredSource = Pick<ContextSnapshot, 'definition' | 'bindings'>;
function validateBindings(source: StoredSource, ctx: z.RefinementCtx): void {
  const variables = new Set<string>(sceneVariables(source.definition.scene).map((variable) => variable.name));
  for (const key of Object.keys(source.bindings)) {
    if (!variables.has(key)) ctx.addIssue({ code: 'custom', message: `绑定了当前定义不支持的变量：${key}` });
  }
}
export const contextSourceSchema = z.object({ definition: contextDefinitionSchema, bindings: bindingsSchema }).strict().superRefine(validateBindings);

function snapshotId(source: StoredSource): string {
  // 绑定的对象键没有顺序含义；段落和分支的数组顺序属于定义，必须保留。
  const bindings = Object.fromEntries(Object.entries(source.bindings).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0));
  return createHash('sha256').update(JSON.stringify({ definition: source.definition, bindings })).digest('hex');
}

/** 记录里的快照只核对结构与摘要，变量以当时的目录为准。 */
export const contextSnapshotSchema: z.ZodType<ContextSnapshot> = z.object({
  id: digest, definition: recordedDefinitionSchema, bindings: bindingsSchema,
}).strict()
  .refine((snapshot) => snapshot.id === snapshotId(snapshot), { message: '上下文快照摘要不匹配' });

/** 场景专有变量的取值：文本已经在手里，要求给全该场景的专有变量。 */
export function sceneValues<S extends ContextScene>(texts: Record<ContextVariable<S>, string>): ContextValues {
  return Object.fromEntries(Object.entries<string>(texts).map(([variable, text]) => [variable, () => ({ text })]));
}

/** 按定义收集变量：段落里引用的都取，条件只沿选中的分支往下取。缺少取值时明确报错。 */
export function bindContext(definition: ContextDefinition, values: ContextValues): ContextSource {
  definition = contextDefinitionSchema.parse(definition);
  const bindings: Record<string, ContextBinding> = {};
  const binding = (variable: string) => {
    if (!Object.hasOwn(bindings, variable)) {
      if (!Object.hasOwn(values, variable)) throw new Error(`上下文变量未提供：${variable}`);
      bindings[variable] = values[variable]!();
    }
    return bindings[variable]!;
  };
  const collect = (blocks: ContextBlock[]) => {
    for (const block of blocks) {
      if (block.type === 'paragraph') {
        for (const part of block.parts) if (part.type === 'variable') binding(part.name);
      } else {
        const value = binding(block.variable).text;
        collect((block.cases.find((branch) => branch.equals === value) ?? block.otherwise).blocks);
      }
    }
  };
  collect(definition.blocks);
  if (definition.input) collect(definition.input);
  return { definition, bindings };
}

/** 实时组装按当前的变量目录校验，历史还原见 restoreContext。 */
export function assembleContext(source: ContextSource): ContextAssembly {
  const parsed = contextSourceSchema.parse(source);
  return renderContext({ id: snapshotId(parsed), ...parsed });
}

/** 历史还原只使用快照中的定义和变量，不重新发现材料，也不改写旧快照。 */
export function restoreContext(snapshot: ContextSnapshot): ContextAssembly {
  return renderContext(contextSnapshotSchema.parse(snapshot));
}

function renderContext(snapshot: ContextSnapshot): ContextAssembly {
  const binding = (variable: string) => {
    if (!Object.hasOwn(snapshot.bindings, variable)) throw new Error(`上下文变量未提供：${variable}`);
    return snapshot.bindings[variable]!;
  };
  const render = (blocks: ContextBlock[], paragraphs: string[], value = binding): ResolvedContextBlock[] => blocks.map((item) => {
    if (item.type === 'condition') {
      const text = value(item.variable).text;
      const branch = item.cases.find((candidate) => candidate.equals === text) ?? item.otherwise;
      return { type: 'condition', id: item.id, branchId: branch.id, blocks: render(branch.blocks, paragraphs, value) };
    }
    const parts = item.parts.map((part) => part.type === 'text' ? part : { ...part, ...value(part.name) });
    const text = parts.map((part) => part.text).join('');
    if (text.length > 0) paragraphs.push(text);
    return { type: 'paragraph', id: item.id, text, parts };
  });
  const paragraphs: string[] = [];
  const blocks = render(snapshot.definition.blocks, paragraphs);
  const input: string[] = [];
  const inputBlocks = snapshot.definition.input === undefined ? undefined : render(snapshot.definition.input, input);
  const instructions = paragraphs.join('\n\n');
  // 另由通知告知的变量当作空再排一遍；当作空时走到的分支里可能有没取值的变量，也当作空
  const notified = Object.keys(snapshot.bindings).some((variable) => notifiedVariables.has(variable));
  const stable: string[] = [];
  if (notified) render(snapshot.definition.blocks, stable, (variable) => notifiedVariables.has(variable) ? { text: '' } : snapshot.bindings[variable] ?? { text: '' });
  return {
    instructions, stable: notified ? stable.join('\n\n') : instructions, blocks,
    ...(inputBlocks === undefined ? {} : { input: input.join('\n\n'), inputBlocks }),
    snapshot,
  };
}

/** 兼容只提供一段指令的宿主；同样经过组装和记录，不另留一条未记录的请求路径。 */
export function literalContext(text: string): ContextSource {
  return {
    definition: {
      version: 2, id: 'literal', title: '宿主指令', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'instructions', title: '指令', parts: [{ type: 'text', text }] }],
    },
    bindings: {},
  };
}
