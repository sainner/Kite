/**
 * skill 的来源与清单。四层由外到内：系统层随 kited 的运行目录提供；用户层是账号资源库里的，同步后写在工作机数据目录的 skills/ 下；
 * 机器层是这台工作机上的 ~/.agents/skills 与 ~/.claude/skills；项目层从仓库根目录到工作目录逐级找 .claude/skills 与 .agents/skills。
 * 清单只列名字和一句说明，正文由模型用 skill 工具加载；契约见 docs/harness-上下文组装.md。
 */
import { isUtf8 } from 'node:buffer';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { basename, join, parse, relative, resolve, sep } from 'node:path';
import { within } from '../../paths.ts';
import type { ContextBinding } from './types.ts';

/**
 * 随 kited 带的 skill，都在 kited/skills 下；打包复制到运行目录的同一位置，见 kited/scripts/package-macos.ts。不放仓库的 .claude/skills：
 * 那里是在 Kite 仓库里用 Claude Code 时的项目层，与它自带的 simplify、code-review 同名。kite-onboard 也是这个仓库自己的项目规范，
 * 文件留在 .claude/skills，这里是指过去的软链接。
 */
export const SYSTEM_SKILLS = ['kite-onboard', 'simplify', 'code-review'] as const;
/**
 * 开发时是仓库的 kited/skills，安装后是运行目录里的同名位置；kited 升级在原路径换内容，路径不变。
 * 取真实路径：给模型的路径和沙箱放行的路径都与文件工具规范化后的目标一致，macOS 上大小写不同的启动目录才对得上。
 */
const bundledSkills = resolve(import.meta.dir, '../../../skills');
export const systemSkillsDirectory = existsSync(bundledSkills) ? realpathSync(bundledSkills) : bundledSkills;

export type SkillLayer = 'system' | 'user' | 'machine' | 'project';
/** directory 是真实路径（见 collectSkills），SKILL.md 就在它下面。 */
export interface Skill { name: string; description: string; directory: string; layer: SkillLayer }
const layerTitles: Record<SkillLayer, string> = { system: '系统', user: '用户', machine: '机器', project: '项目' };

/** 清单里一句说明的上限，与 Claude Code 的列表一致；超出的截断加省略号。 */
const skillDescriptionLimit = 1536;
/** skill 工具一次给模型的正文上限（字节），再大的让模型分段 read。 */
const skillTextLimit = 2 * 1024 * 1024;

/** 项目层在每个文件夹里的两个位置：Claude Code 读前者，Codex 读后者；后处理的同名盖前面的。 */
const projectSkillRoots = ['.claude/skills', '.agents/skills'];

/**
 * 工作目录以外三层的位置，由宿主构造一份显式传下去：Kite 的用户层在数据目录、机器层在用户主目录；
 * 独立终端和测试没有这两层（systemSkillSources）。项目层随工作目录找，不在这里。
 */
export interface SkillSources { system: string; user?: string; machine?: string[] }
export const systemSkillSources: SkillSources = { system: systemSkillsDirectory };

const realPath = (path: string): string | undefined => { try { return realpathSync(path); } catch { return undefined; } };

/**
 * 沙箱要为 skill 放行只读的位置。系统、用户、机器三层是宿主给的位置，根目录整个放行；项目层随仓库走，内容不可信：
 * 只放行字面上在工作目录以外（工作目录本身已经可读）、真实路径仍在仓库根目录以内的根目录，仓库里提交一个指向 / 或主目录的
 * 软链接放不开整片目录（不在仓库里时没有仓库边界，以根目录所在的那一级为界）。各 skill 的文件夹没被这些位置和工作目录盖住时另加，
 * 软链接到别处的 skill 也读得到。folders 同 collectSkills，最后一个是工作目录；skills 是按同样的 folders 与来源合成的清单。
 */
export function skillReadPaths(sources: SkillSources, folders: string[], skills: Skill[]): string[] {
  const roots = [sources.system, sources.user, ...(sources.machine ?? [])].flatMap((root) => (root && realPath(root)) || []);
  const repository = folders[0]!;
  const unbounded = repository === parse(repository).root;
  for (const folder of folders.slice(0, -1)) {
    const bound = realPath(unbounded ? folder : repository);
    for (const root of projectSkillRoots) {
      const target = realPath(join(folder, root));
      if (target && bound && within(target, bound)) roots.push(target);
    }
  }
  const cwd = realPath(folders.at(-1)!);
  const covered = (directory: string) => (cwd !== undefined && within(directory, cwd)) || roots.some((root) => within(directory, root));
  return [...new Set([...roots, ...skills.map((skill) => skill.directory).filter((directory) => !covered(directory))])];
}

/** SKILL.md 开头用 --- 包起来的 YAML 头，与之后的正文；没有头或头不完整时头为空、正文是全文。开头的 BOM 不算。 */
function splitFrontmatter(content: string): { header: string; body: string } {
  const text = content.replace(/^﻿/, '');
  const lines = text.split(/\r?\n/);
  const end = lines[0]?.trim() === '---' ? lines.findIndex((line, index) => index > 0 && line.trim() === '---') : -1;
  return end < 0 ? { header: '', body: text.trim() } : { header: lines.slice(1, end).join('\n'), body: lines.slice(end + 1).join('\n').trim() };
}

/** Claude Code 重试前要加引号的值：带这些字符的不加引号时多半不是合法的 YAML，最常见的是值里的「: 」。 */
const yamlSpecial = /[{}[\]*&#!|>%@`]|: /;

/**
 * 照 Claude Code（2.1.280）读 SKILL.md 头的做法：Bun.YAML 严格解析，失败时把顶层 key: value 里没加引号、带特殊字符的值加上引号，
 * 行首的制表符换成空格，再解析一次（`description: Use when: X` 这样的写法就能读）；仍失败或不是映射时为空对象，skill 只列名字。
 * 只留字符串值，Agent Skills 标准里 name 与 description 都是字符串，别的类型 Claude Code 也丢掉。
 */
export function parseFrontmatter(content: string): Record<string, string> {
  const { header } = splitFrontmatter(content);
  const quoted = () => header.split('\n').map((line) => {
    const match = /^([a-zA-Z_-]+):\s+(.+)$/.exec(line);
    if (!match) return line;
    const key = match[1]!;
    const value = match[2]!;
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) return line;
    if (value.startsWith('[') && value.endsWith(']')) {
      try { if (Array.isArray(Bun.YAML.parse(value))) return line; } catch { /* 不是合法的流式列表，按普通值处理。 */ }
    }
    return yamlSpecial.test(value) ? `${key}: "${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"` : line;
  }).join('\n').replace(/^\t+/gm, (tabs) => '  '.repeat(tabs.length));
  let parsed: unknown;
  try { parsed = Bun.YAML.parse(header); } catch {
    try { parsed = Bun.YAML.parse(quoted()); } catch { return {}; }
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
  return Object.fromEntries(Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === 'string'));
}

/** 文件的字节按文本给出：须是合法的 UTF-8 且不含 NUL，不是文本时为 undefined。资源库打包 skill 文件时按它分文本与二进制。 */
export function textContent(bytes: Buffer): string | undefined {
  return isUtf8(bytes) && !bytes.includes(0) ? bytes.toString('utf8') : undefined;
}

/** 一个 skill 文件夹：名字取头里的 name，没有就用文件夹名；说明压成一行并截断。读不到 SKILL.md 的不算 skill。 */
function readSkill(directory: string, layer: SkillLayer): Skill | undefined {
  let content: string;
  try { content = readFileSync(join(directory, 'SKILL.md'), 'utf8'); } catch { return undefined; }
  const fields = parseFrontmatter(content);
  const description = (fields.description ?? '').replace(/\s+/g, ' ').trim();
  return { name: fields.name?.trim() || basename(directory), layer, directory,
    description: description.length > skillDescriptionLimit ? `${description.slice(0, skillDescriptionLimit - 1)}…` : description };
}

/** root 下每个带 SKILL.md 的子文件夹是一个 skill，软链接的文件夹也算；names 限定只看这几个。root 不存在时为空。 */
function skillsUnder(root: string | undefined, layer: SkillLayer, names?: readonly string[]): Skill[] {
  if (!root) return [];
  let entries: string[];
  try { entries = names ? [...names] : readdirSync(root).sort(); } catch { return []; }
  return entries.flatMap((name) => {
    const directory = join(root, name);
    try { if (!statSync(directory).isDirectory()) return []; } catch { return []; }
    const skill = readSkill(directory, layer);
    return skill ? [skill] : [];
  });
}

/**
 * 四层合成的清单。folders 是从仓库根目录到工作目录的各级文件夹，由外到内；同名里层盖外层，
 * 同一个文件夹经软链接重复到达只算一次（仓库里常把 .agents/skills/x 链到 .claude/skills/x）。
 * 文件夹取真实路径：给模型的路径、read 认的 skill 文件夹和沙箱放行的路径要对得上。
 */
export function collectSkills(folders: string[], sources: SkillSources): Skill[] {
  const byName = new Map<string, Skill>();
  const seen = new Set<string>();
  const add = (skill: Skill) => {
    const directory = realpathSync(skill.directory);
    if (seen.has(directory)) return;
    seen.add(directory);
    byName.set(skill.name, { ...skill, directory });
  };
  for (const skill of skillsUnder(sources.system, 'system', SYSTEM_SKILLS)) add(skill);
  for (const skill of skillsUnder(sources.user, 'user')) add(skill);
  for (const root of sources.machine ?? []) for (const skill of skillsUnder(root, 'machine')) add(skill);
  for (const folder of folders) for (const root of projectSkillRoots) for (const skill of skillsUnder(join(folder, root), 'project')) add(skill);
  return [...byName.values()];
}

/** 清单正文：每条一行，名字接一句说明；一个都没有时为空。 */
export function skillsBinding(skills: Skill[]): ContextBinding {
  return { text: skills.map((skill) => `- ${skill.name}${skill.description ? `：${skill.description}` : ''}`).join('\n') };
}

/**
 * skill 文件夹里的全部文件（相对路径，按名字排），不进隐藏文件，最多列这么多个。跟着软链接走，但真实位置越出文件夹的不列：
 * read 按文件夹的边界解析，读不到它们；同一个目录经软链接再次到达时也不再进去。
 */
export function skillFiles(directory: string, limit = 200): string[] {
  const files: string[] = [];
  const root = realPath(directory);
  if (!root) return files;
  const visited = new Set<string>();
  const walk = (folder: string) => {
    const real = realPath(folder);
    if (!real || visited.has(real)) return;
    visited.add(real);
    let entries: string[];
    try { entries = readdirSync(folder).sort(); } catch { return; }
    for (const name of entries) {
      if (name.startsWith('.') || files.length >= limit) continue;
      const path = join(folder, name);
      const target = realPath(path);
      if (!target || !within(target, root)) continue;
      let directoryEntry: boolean;
      try { directoryEntry = statSync(target).isDirectory(); } catch { continue; }
      if (directoryEntry) walk(path);
      else files.push(relative(directory, path).split(sep).join('/'));
    }
  };
  walk(directory);
  return files;
}

/**
 * skill 工具交给模型的内容：包装行里写名字、所在层和文件夹，正文前列出文件夹里的文件，正文里的相对路径按这个文件夹解析，
 * 文件用 read 按绝对路径读。正文里的 ${CLAUDE_SKILL_DIR} 换成文件夹路径，照 Claude Code 的写法写的 skill 也能用。
 */
export function loadSkill(skill: Skill): string {
  const content = readFileSync(join(skill.directory, 'SKILL.md'), 'utf8');
  if (Buffer.byteLength(content) > skillTextLimit) throw new Error(`${skill.name} 的 SKILL.md 超过 2 MiB，请用 read 或 shell 分段读`);
  const files = skillFiles(skill.directory).filter((file) => file !== 'SKILL.md');
  return [`<skill name="${skill.name}" layer="${layerTitles[skill.layer]}" folder="${skill.directory.replaceAll('"', '')}">`,
    `这是 skill「${skill.name}」（${layerTitles[skill.layer]}层）的正文，文件夹在 ${skill.directory}。`
      + (files.length ? `文件夹里另有：${files.join('、')}。` : '')
      + '正文里提到的路径相对这个文件夹；里面的文件用 read 按绝对路径读，脚本用 shell 跑。',
    // 替换值用函数给：路径里的 $&、$$ 这类写法不当替换模式。
    '', splitFrontmatter(content).body.replaceAll('${CLAUDE_SKILL_DIR}', () => skill.directory), '</skill>'].join('\n');
}
