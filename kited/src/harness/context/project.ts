/** 终端宿主的默认定义与材料发现。定义不含回调，可直接作为未来编辑器的数据。 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { dirname, join, parse, resolve } from 'node:path';
import { bindContext } from './assembler.ts';
import type { PublicVariable } from './scenes.ts';
import type { ContextBinding, ContextBlock, ContextDefinition, ContextSource, ContextValues } from './types.ts';

const paragraph = (id: string, title: string, text: string): ContextBlock => ({
  type: 'paragraph', id, title, parts: [{ type: 'text', text }],
});

/** 有内容才放进正文的一段材料。 */
const material = (variable: string, id: string, title: string): ContextBlock => ({
  type: 'condition', id, title, variable,
  cases: [{ id: `${id}-absent`, title: `没有${title}`, equals: '', blocks: [] }],
  otherwise: { id: `${id}-present`, title: `有${title}`, blocks: [
    { type: 'paragraph', id: `${id}-content`, title, parts: [{ type: 'variable', name: variable }] },
  ] },
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
    paragraph('capabilities', '当前能力', '以本次请求实际开放的工具为准。只有提供 agent 工具的宿主才支持创建和管理其他 agent；同一工作区的其他线程可能同时在改文件。没有 MCP 工具，不声称已经调用未开放的能力。'),
    {
      type: 'condition', id: 'worktree', title: '工作区类型', variable: 'workspace.kind',
      cases: [{ id: 'worktree-isolated', title: '独立工作树', equals: 'worktree', blocks: [paragraph('worktree-boundary', '工作树边界',
        '当前目录是 Kite 为这个工作区创建的独立工作树，请在这里完成工作，不要切回主文件夹修改。Kite 在工具批次和回合结束后保存快照，由用户决定采纳或回退。不要自行删除工作树或分支。')] }],
      otherwise: { id: 'worktree-root', title: '项目文件夹', blocks: [] },
    },
    material('project.rules', 'rules', '项目规则'),
    material('project.memory', 'memory', '记忆索引'),
  ],
};

/** 工作目录所在仓库的根：往上找到 .git 为止；不在仓库里时沿父目录一直到文件系统根。 */
function folders(cwd: string): { folders: string[]; git?: string } {
  const found: string[] = [];
  let folder = cwd;
  while (true) {
    found.unshift(folder);
    if (existsSync(join(folder, '.git'))) return { folders: found, git: join(folder, '.git') };
    if (folder === parse(folder).root) return { folders: found };
    folder = dirname(folder);
  }
}

function documents(cwd: string, name: string): ContextBinding {
  const texts: string[] = [];
  const sources: NonNullable<ContextBinding['sources']> = [];
  for (const directory of folders(cwd).folders) {
    const path = join(directory, name);
    if (!existsSync(path)) continue;
    const content = readFileSync(path, 'utf8');
    if (content.length > 100_000) throw new Error(`项目指令文件过大：${path}`);
    texts.push(`文件 ${path}：\n${content}`);
    sources.push({ path, sha256: createHash('sha256').update(content).digest('hex') });
  }
  return { text: texts.join('\n\n'), sources };
}

/** 读 HEAD 文件而不起 git 子进程：每次请求组装都可能取值，同步读文件不阻塞事件循环。工作树的 .git 是指向自己 gitdir 的文件。 */
function branch(cwd: string): ContextBinding {
  const { git } = folders(cwd);
  if (!git) return { text: '' };
  const gitDir = statSync(git).isFile() ? resolve(dirname(git), readFileSync(git, 'utf8').replace(/^gitdir:\s*/, '').trim()) : git;
  const head = readFileSync(join(gitDir, 'HEAD'), 'utf8').trim();
  return { text: head.startsWith('ref: refs/heads/') ? head.slice('ref: refs/heads/'.length) : '' };
}

export const today = (): ContextBinding => ({ text: new Date().toISOString().slice(0, 10) });

/** 工作目录本身取得到的变量：路径、分支，以及项目规则与记忆索引。 */
export function directoryVariables(cwd: string) {
  return {
    'environment.cwd': () => ({ text: realpathSync(cwd) }),
    'workspace.branch': () => branch(realpathSync(cwd)),
    'project.rules': () => documents(realpathSync(cwd), 'AGENTS.md'),
    'project.memory': () => documents(realpathSync(cwd), '.kite/memory/MEMORY.md'),
  } satisfies Partial<Record<PublicVariable, () => ContextBinding>>;
}

/** 角色提示词的来源：每次请求取一份变量；没有监听器，不主动打断或唤醒会话。 */
export function projectContext(definition: ContextDefinition, values: ContextValues): ContextSource {
  if (definition.scene !== 'thread.create') throw new Error('项目基础上下文须使用 thread.create 场景');
  return bindContext(definition, values);
}
