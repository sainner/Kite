/**
 * skill 的来源与清单。四层由外到内：系统层随 kited 的运行目录提供；用户层是账号资源库里的，同步后写在工作机数据目录的 skills/ 下；
 * 机器层是这台工作机上的 ~/.agents/skills 与 ~/.claude/skills；项目层从仓库根目录到工作目录逐级找 .claude/skills 与 .agents/skills。
 * 清单只列名字和一句说明，正文由模型用 skill 工具加载；契约见 docs/harness-上下文组装.md。
 */
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { safePath, within } from '../../paths.ts';
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
export interface Skill { name: string; description: string; /** SKILL.md 的路径。 */ path: string; directory: string; layer: SkillLayer }
export const layerTitles: Record<SkillLayer, string> = { system: '系统', user: '用户', machine: '机器', project: '项目' };

/** 清单里一句说明的上限，与 Claude Code 的列表一致；超出的截断加省略号。 */
export const skillDescriptionLimit = 1536;
/** skill 工具一次给模型的正文或文件上限（字节），再大的让模型分段 read。 */
const skillTextLimit = 2 * 1024 * 1024;

/** 项目层在每个文件夹里的两个位置：Claude Code 读前者，Codex 读后者；后处理的同名盖前面的。 */
const projectSkillRoots = ['.claude/skills', '.agents/skills'];

/** 系统层之外几层的位置。用户层与机器层由 Kite 启动时设一次（setSkillSources）；独立终端和测试不设，只有系统层与项目层。 */
export interface SkillSources { system: string; user?: string; machine?: string[] }
let sources: SkillSources = { system: systemSkillsDirectory };
export function setSkillSources(value: Partial<SkillSources>): void { sources = { ...sources, ...value }; }
/** 工作目录以外、代理要能读的 skill 目录：系统层、用户层和机器层里实际存在的，沙箱放行只读用。 */
export function skillSourceDirectories(): string[] {
  return [sources.system, sources.user, ...(sources.machine ?? [])].filter((directory): directory is string => !!directory && existsSync(directory))
    .map((directory) => realpathSync(directory));
}

/**
 * SKILL.md 开头用 --- 包起来的 YAML 头，只认顶层的 key: value：单行值去掉成对的引号；> 或 | 开头的块取后面缩进的行，用空格接起来。
 * 不是完整的 YAML，Agent Skills 标准里 name 与 description 都是字符串，够用；没有头或头不完整时返回空对象，skill 只列名字。
 */
export function parseFrontmatter(content: string): Record<string, string> {
  const lines = content.split(/\r?\n/);
  if (lines[0]?.trim() !== '---') return {};
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === '---');
  if (end < 0) return {};
  const fields: Record<string, string> = {};
  for (let index = 1; index < end; index++) {
    const match = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(lines[index]!);
    if (!match) continue;
    const key = match[1]!;
    let value = match[2]!.trim();
    if (/^[>|]-?$/.test(value)) {
      const block: string[] = [];
      while (index + 1 < end && (/^\s+\S/.test(lines[index + 1]!) || lines[index + 1]!.trim() === '')) block.push(lines[++index]!.trim());
      value = block.filter(Boolean).join(' ');
    } else if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.slice(1, -1);
    }
    fields[key] = value;
  }
  return fields;
}

/** SKILL.md 去掉 YAML 头之后的正文。 */
export function skillBody(content: string): string {
  const lines = content.split(/\r?\n/);
  if (lines[0]?.trim() !== '---') return content.trim();
  const end = lines.findIndex((line, index) => index > 0 && line.trim() === '---');
  return (end < 0 ? content : lines.slice(end + 1).join('\n')).trim();
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
 */
export function collectSkills(folders: string[], override: Partial<SkillSources> = {}): Skill[] {
  const from = { ...sources, ...override };
  const byName = new Map<string, Skill>();
  const seen = new Set<string>();
  const add = (skill: Skill) => {
    const real = realpathSync(dirname(skill.path));
    if (seen.has(real)) return;
    seen.add(real);
    byName.set(skill.name, skill);
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
 * skill 工具交给模型的内容：包装行里写名字、所在层和文件夹，正文前列出文件夹里的文件，正文里的相对路径按这个文件夹解析。
 * hash 是整段的摘要，同一个 skill 再加载、内容没变时只回一句「已加载过」。
 */
export function loadSkill(skill: Skill): { text: string; hash: string } {
  const content = readFileSync(skill.path, 'utf8');
  if (Buffer.byteLength(content) > skillTextLimit) throw new Error(`${skill.name} 的 SKILL.md 超过 2 MiB，请用 read 或 shell 分段读`);
  const files = skillFiles(skill.directory).filter((file) => file !== 'SKILL.md');
  const text = [`${OPEN}${skill.name}" layer="${layerTitles[skill.layer]}" folder="${skill.directory.replaceAll('"', '')}">`,
    `这是 skill「${skill.name}」（${layerTitles[skill.layer]}层）的正文，文件夹在 ${skill.directory}。`
      + (files.length ? `文件夹里另有：${files.join('、')}。正文里提到的文件按相对这个文件夹的路径找；要看其中一个，用 skill 工具加 file 参数，脚本用 shell 跑。` : '正文里提到的路径相对这个文件夹。'),
    '', skillBody(content), CLOSE].join('\n');
  return { text, hash: createHash('sha256').update(text).digest('hex') };
}

/** skill 文件夹里的一个文件（相对路径）：只给文本，不能越出文件夹，软链接按真实位置算。 */
export function readSkillFile(skill: Skill, file: string): string {
  if (!safePath(file)) {
    throw new Error('file 须是 skill 文件夹里的相对路径，不含 . 或 ..');
  }
  const root = realpathSync(skill.directory);
  const target = resolve(root, file);
  let real: string;
  try { real = realpathSync(target); } catch { throw new Error(`skill「${skill.name}」里没有 ${file}；有的是：${skillFiles(skill.directory).join('、') || '只有 SKILL.md'}`); }
  if (!within(real, root)) throw new Error(`${file} 指向 skill 文件夹之外`);
  const stat = statSync(real);
  if (!stat.isFile()) throw new Error(`${file} 不是文件`);
  if (stat.size > skillTextLimit) throw new Error(`${file} 超过 2 MiB，请用 shell 分段读`);
  const bytes = readFileSync(real);
  const content = bytes.toString('utf8');
  if (bytes.includes(0) || !Buffer.from(content).equals(bytes)) throw new Error(`${file} 不是文本文件，用 shell 处理；文件路径：${real}`);
  return content;
}
