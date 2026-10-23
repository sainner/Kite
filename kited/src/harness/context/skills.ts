/**
 * skill 的来源与清单。四层由外到内：系统层随 kited 的运行目录提供；用户层是账号资源库里的，同步后写在工作机数据目录的 skills/ 下；
 * 机器层是这台工作机上的 ~/.agents/skills 与 ~/.claude/skills；项目层从仓库根目录到工作目录逐级找 .claude/skills 与 .agents/skills。
 * 清单只列名字和一句说明，正文由模型用 skill 工具加载；契约见 docs/harness-上下文组装.md。
 */
import { isUtf8 } from 'node:buffer';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { basename, join, relative, resolve, sep } from 'node:path';
import type { ContextBinding } from './types.ts';

/** 随 kited 带的 skill，都在仓库的 .claude/skills 下；打包复制到运行目录的同一位置，见 kited/scripts/package-macos.ts。 */
export const SYSTEM_SKILLS = ['kite-onboard'] as const;
/**
 * 开发时是仓库的 .claude/skills，安装后是运行目录里的同名位置；kited 升级在原路径换内容，路径不变。
 * 取真实路径：给模型的路径和沙箱放行的路径都与文件工具规范化后的目标一致，macOS 上大小写不同的启动目录才对得上。
 */
const bundledSkills = resolve(import.meta.dir, '../../../../.claude/skills');
export const systemSkillsDirectory = existsSync(bundledSkills) ? realpathSync(bundledSkills) : bundledSkills;

export type SkillLayer = 'system' | 'user' | 'machine' | 'project';
export interface Skill { name: string; description: string; /** SKILL.md 的路径。 */ path: string; /** 真实路径，见 collectSkills。 */ directory: string; layer: SkillLayer }
const layerTitles: Record<SkillLayer, string> = { system: '系统', user: '用户', machine: '机器', project: '项目' };

/** 清单里一句说明的上限，与 Claude Code 的列表一致；超出的截断加省略号。 */
const skillDescriptionLimit = 1536;
/** skill 工具一次给模型的正文上限（字节），再大的让模型分段 read。 */
const skillTextLimit = 2 * 1024 * 1024;

/** 项目层在每个文件夹里的两个位置：Claude Code 读前者，Codex 读后者；后处理的同名盖前面的。 */
const projectSkillRoots = ['.claude/skills', '.agents/skills'];

/** 系统层之外几层的位置。用户层与机器层由 Kite 启动时设一次（setSkillSources）；独立终端和测试不设，只有系统层与项目层。 */
export interface SkillSources { system: string; user?: string; machine?: string[] }
let sources: SkillSources = { system: systemSkillsDirectory };
export function setSkillSources(value: Partial<SkillSources>): void { sources = { ...sources, ...value }; }
/**
 * 代理要能读的 skill 位置，沙箱放行只读用：四层的根目录里实际存在的（项目层在仓库根目录时可能在工作目录以外），
 * 再加上现有 skill 的文件夹，软链接到这些根目录以外的也读得到。folders 同 collectSkills。
 */
export function skillSourceDirectories(folders: string[]): string[] {
  const roots = [sources.system, sources.user, ...(sources.machine ?? []), ...folders.flatMap((folder) => projectSkillRoots.map((root) => join(folder, root)))];
  return [...roots.filter((directory): directory is string => !!directory && existsSync(directory)).map((directory) => realpathSync(directory)),
    ...collectSkills(folders).map((skill) => skill.directory)];
}

/** SKILL.md 开头用 --- 包起来的 YAML 头的各行，与之后的正文；没有头或头不完整时头为空、正文是全文。 */
function splitFrontmatter(content: string): { header: string[]; body: string } {
  const lines = content.split(/\r?\n/);
  const end = lines[0]?.trim() === '---' ? lines.findIndex((line, index) => index > 0 && line.trim() === '---') : -1;
  return end < 0 ? { header: [], body: content.trim() } : { header: lines.slice(1, end), body: lines.slice(end + 1).join('\n').trim() };
}

/**
 * YAML 头只认顶层的 key: value：单行值去掉成对的引号；> 或 | 开头的块取后面缩进的行，用空格接起来。
 * 不是完整的 YAML，Agent Skills 标准里 name 与 description 都是字符串，够用；没有头或头不完整时返回空对象，skill 只列名字。
 */
export function parseFrontmatter(content: string): Record<string, string> {
  const { header } = splitFrontmatter(content);
  const fields: Record<string, string> = {};
  for (let index = 0; index < header.length; index++) {
    const match = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(header[index]!);
    if (!match) continue;
    const key = match[1]!;
    let value = match[2]!.trim();
    if (/^[>|]-?$/.test(value)) {
      const block: string[] = [];
      while (index + 1 < header.length && (/^\s+\S/.test(header[index + 1]!) || header[index + 1]!.trim() === '')) block.push(header[++index]!.trim());
      value = block.filter(Boolean).join(' ');
    } else if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.slice(1, -1);
    }
    fields[key] = value;
  }
  return fields;
}

/** 文件的字节按文本给出：须是合法的 UTF-8 且不含 NUL，不是文本时为 undefined。资源库打包 skill 文件时按它分文本与二进制。 */
export function textContent(bytes: Buffer): string | undefined {
  return isUtf8(bytes) && !bytes.includes(0) ? bytes.toString('utf8') : undefined;
}

/** 一个 skill 文件夹：名字取头里的 name，没有就用文件夹名；说明压成一行并截断。读不到 SKILL.md 的不算 skill。 */
function readSkill(directory: string, layer: SkillLayer): Skill | undefined {
  const path = join(directory, 'SKILL.md');
  let content: string;
  try { content = readFileSync(path, 'utf8'); } catch { return undefined; }
  const fields = parseFrontmatter(content);
  const description = (fields.description ?? '').replace(/\s+/g, ' ').trim();
  return { name: fields.name?.trim() || basename(directory), layer, path, directory,
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
export function collectSkills(folders: string[], override: Partial<SkillSources> = {}): Skill[] {
  const from = { ...sources, ...override };
  const byName = new Map<string, Skill>();
  const seen = new Set<string>();
  const add = (skill: Skill) => {
    const directory = realpathSync(skill.directory);
    if (seen.has(directory)) return;
    seen.add(directory);
    byName.set(skill.name, { ...skill, directory, path: join(directory, 'SKILL.md') });
  };
  for (const skill of skillsUnder(from.system, 'system', SYSTEM_SKILLS)) add(skill);
  for (const skill of skillsUnder(from.user, 'user')) add(skill);
  for (const root of from.machine ?? []) for (const skill of skillsUnder(root, 'machine')) add(skill);
  for (const folder of folders) for (const root of projectSkillRoots) for (const skill of skillsUnder(join(folder, root), 'project')) add(skill);
  return [...byName.values()];
}

/** 清单正文：每条一行，名字接一句说明；一个都没有时为空。 */
export function skillsBinding(skills: Skill[]): ContextBinding {
  return { text: skills.map((skill) => `- ${skill.name}${skill.description ? `：${skill.description}` : ''}`).join('\n') };
}

/** skill 文件夹里的全部文件（相对路径，按名字排），不进隐藏文件；跟着软链接走，最多列这么多个。 */
export function skillFiles(directory: string, limit = 200): string[] {
  const files: string[] = [];
  const walk = (folder: string) => {
    let entries: string[];
    try { entries = readdirSync(folder).sort(); } catch { return; }
    for (const name of entries) {
      if (name.startsWith('.') || files.length >= limit) continue;
      const path = join(folder, name);
      let directoryEntry: boolean;
      try { directoryEntry = statSync(path).isDirectory(); } catch { continue; }
      if (directoryEntry) walk(path);
      else files.push(relative(directory, path).split(sep).join('/'));
    }
  };
  walk(directory);
  return files;
}

/** 正文的包装：开头一行写名字、层与文件夹，压缩重附时按它认出是哪个 skill（见 compaction.ts）。 */
const OPEN = '<skill name="';
const CLOSE = '</skill>';
export const isSkillText = (text: string) => text.startsWith(OPEN);
/** 一段文字里的各个 skill 块，按出现顺序给出名字与整块原文。 */
export function skillBlocks(text: string): Array<{ name: string; text: string }> {
  const blocks: Array<{ name: string; text: string }> = [];
  const pattern = /<skill name="([^"\n]+)"[^>\n]*>[\s\S]*?<\/skill>/g;
  for (const match of text.matchAll(pattern)) blocks.push({ name: match[1]!, text: match[0] });
  return blocks;
}

/**
 * skill 工具交给模型的内容：包装行里写名字、所在层和文件夹，正文前列出文件夹里的文件，正文里的相对路径按这个文件夹解析，
 * 文件用 read 按绝对路径读。正文里的 ${CLAUDE_SKILL_DIR} 换成文件夹路径，照 Claude Code 的写法写的 skill 也能用。
 */
export function loadSkill(skill: Skill): string {
  const content = readFileSync(skill.path, 'utf8');
  if (Buffer.byteLength(content) > skillTextLimit) throw new Error(`${skill.name} 的 SKILL.md 超过 2 MiB，请用 read 或 shell 分段读`);
  const files = skillFiles(skill.directory).filter((file) => file !== 'SKILL.md');
  return [`${OPEN}${skill.name}" layer="${layerTitles[skill.layer]}" folder="${skill.directory.replaceAll('"', '')}">`,
    `这是 skill「${skill.name}」（${layerTitles[skill.layer]}层）的正文，文件夹在 ${skill.directory}。`
      + (files.length ? `文件夹里另有：${files.join('、')}。` : '')
      + '正文里提到的路径相对这个文件夹；里面的文件用 read 按绝对路径读，脚本用 shell 跑。',
    '', splitFrontmatter(content).body.replaceAll('${CLAUDE_SKILL_DIR}', skill.directory), CLOSE].join('\n');
}
