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
    paragraph('references', '引用写法', '回复里提到文件或目录时写相对当前工作目录的完整路径，要定位时在后面加 :行号 或 :起始行-结束行；提到本机运行的网页时写完整网址，例如 http://127.0.0.1:3000/login。'),
    paragraph('project-rules', '项目约定', '进入子目录前读取适用的 AGENTS.md。项目记忆只使用 .kite/memory，不新建另一份。'),
    paragraph('verification', '交付', '不要擅自提交、推送或部署。'),
    paragraph('worktree-boundary', '工作树边界',
      '当前目录是 Kite 为这个工作区创建的工作树，同一工作区的其他线程可能同时在改文件。Kite 在工具批次和回合结束后保存快照，由用户决定集成或回退。'),
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

/** 来自文件的公共变量：从仓库根目录到工作目录逐级找到的同名文件。 */
export const documentVariables = {
  'project.rules': 'AGENTS.md',
  'project.memory': '.kite/memory/MEMORY.md',
} as const satisfies Partial<Record<PublicVariable, string>>;
export type DocumentVariable = keyof typeof documentVariables;

/** 一份文件的内容上限，读进上下文和从编辑器写回都按它。 */
export const documentLimit = 100_000;

export interface DocumentFile { path: string; content: string; sha256: string }

export const contentHash = (content: string) => createHash('sha256').update(content).digest('hex');

/** 逐级可以放这份文件的位置，由外到内。 */
export const documentPaths = (cwd: string, name: string) => folders(cwd).folders.map((directory) => join(directory, name));

/** 逐级找到的文件，由外到内。 */
export function documentFiles(cwd: string, name: string): DocumentFile[] {
  return documentPaths(cwd, name).filter((path) => existsSync(path)).map((path) => {
    const content = readFileSync(path, 'utf8');
    if (content.length > documentLimit) throw new Error(`项目指令文件过大：${path}`);
    return { path, content, sha256: contentHash(content) };
  });
}

function documents(cwd: string, name: string): ContextBinding {
  const files = documentFiles(cwd, name);
  return { text: files.map((file) => `文件 ${file.path}：\n${file.content}`).join('\n\n'), sources: files.map(({ path, sha256 }) => ({ path, sha256 })) };
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
    'project.rules': () => documents(realpathSync(cwd), documentVariables['project.rules']),
    'project.memory': () => documents(realpathSync(cwd), documentVariables['project.memory']),
  } satisfies Partial<Record<PublicVariable, () => ContextBinding>>;
}

/** 角色提示词的来源：每次请求取一份变量；没有监听器，不主动打断或唤醒会话。 */
export function projectContext(definition: ContextDefinition, values: ContextValues): ContextSource {
  if (definition.scene !== 'thread.create') throw new Error('项目基础上下文须使用 thread.create 场景');
  return bindContext(definition, values);
}
