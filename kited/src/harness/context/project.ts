/** 终端宿主的默认定义与材料发现。定义不含回调，可直接作为未来编辑器的数据。 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { dirname, join, parse } from 'node:path';
import { contextDefinitionSchema } from './assembler.ts';
import type { ContextVariable } from './scenes.ts';
import type { ContextBinding, ContextBlock, ContextDefinition, ContextSource } from './types.ts';

const paragraph = (id: string, title: string, text: string): ContextBlock => ({
  type: 'paragraph', id, title, parts: [{ type: 'text', text }],
});

export const defaultContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.work', title: '工作', scene: 'thread.create',
  blocks: [
    paragraph('identity', '基础行为', '你是 Kite 的本地编程助手。使用简体中文交流，按用户要求完成工作并验证结果。'),
    { type: 'paragraph', id: 'environment', title: '运行环境', parts: [
      { type: 'text', text: '当前工作目录：' }, { type: 'variable', name: 'environment.cwd' },
      { type: 'text', text: '。日期：' }, { type: 'variable', name: 'environment.date' }, { type: 'text', text: '。' },
    ] },
    paragraph('file-tools', '文件工具', '使用 read 读取真实文件，用 patch 创建、修改和删除文件；不要编造执行结果。搜索用 shell 中的 rg。'),
    paragraph('file-changes', '文件变化', '建议编辑前先读文件；未读或文件变化仅提示，不是编辑门槛。patch 提示存在其他变化时，依赖周边内容的后续修改应先重读。'),
    paragraph('project-rules', '项目约定', '进入子目录前读取适用的 AGENTS.md。项目记忆只使用 .kite/memory，不新建另一份。'),
    paragraph('commands', '命令执行', 'shell 命令直接在当前目录执行，不要启动后台任务或脱离进程组的守护进程。'),
    paragraph('verification', '验证和交付', '修改文件后做与任务相关的检查。不要擅自提交、推送或部署。'),
    paragraph('capabilities', '当前能力', '以本次请求实际开放的工具为准。只有提供 agent 工具的宿主才支持创建和管理其他 agent；共享工作区的执行互斥仍然适用。没有 MCP 工具，不声称已经调用未开放的能力。'),
    {
      type: 'condition', id: 'documents', title: '项目材料', variable: 'project.documents',
      cases: [{ id: 'documents-absent', title: '没有项目材料', equals: '', blocks: [] }],
      otherwise: { id: 'documents-present', title: '有项目材料', blocks: [
        { type: 'paragraph', id: 'documents-content', title: '规则与记忆索引', parts: [{ type: 'variable', name: 'project.documents' }] },
      ] },
    },
  ],
};

function documents(cwd: string): ContextBinding {
  const folders: string[] = [];
  let folder = cwd;
  while (true) {
    folders.unshift(folder);
    if (existsSync(join(folder, '.git')) || folder === parse(folder).root) break;
    folder = dirname(folder);
  }
  const texts: string[] = [];
  const sources: NonNullable<ContextBinding['sources']> = [];
  for (const directory of folders) {
    for (const name of ['AGENTS.md', '.kite/memory/MEMORY.md']) {
      const path = join(directory, name);
      if (!existsSync(path)) continue;
      const content = readFileSync(path, 'utf8');
      if (content.length > 100_000) throw new Error(`项目指令文件过大：${path}`);
      texts.push(`文件 ${path}：\n${content}`);
      sources.push({ path, sha256: createHash('sha256').update(content).digest('hex') });
    }
  }
  return { text: texts.join('\n\n'), sources };
}

/** 每次请求获取一份材料；没有监听器，不主动打断或唤醒会话。 */
export function projectContext(cwd: string, definition: ContextDefinition = defaultContextDefinition): ContextSource {
  definition = contextDefinitionSchema.parse(definition);
  if (definition.scene !== 'thread.create') throw new Error('项目基础上下文须使用 thread.create 场景');
  const sources = {
    'environment.cwd': () => ({ text: realpathSync(cwd) }),
    'environment.date': () => ({ text: new Date().toISOString().slice(0, 10) }),
    'project.documents': () => documents(realpathSync(cwd)),
  } satisfies Record<ContextVariable<'thread.create'>, () => ContextBinding>;
  const bindings: Record<string, ContextBinding> = {};
  const binding = (name: string) => bindings[name] ??= sources[name as keyof typeof sources]();
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
  return { definition, bindings };
}
