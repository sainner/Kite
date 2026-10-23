/**
 * 资源库里的 skill（用户层）：一个多文件包，随账号级数据在工作机之间同步，每台工作机把它写进数据目录的 skills/<名字>/，代理从那里加载
 * （见 harness/context/skills.ts）。随 kited 带的系统层 skill 是用户层的默认：账号里只存改过的那份，同名盖过系统层；改回与默认一样或
 * 恢复默认时删掉那一条。写入先进账号级数据，再对本机的文件夹（见 library-sync.ts）。列表只给名字和版本，整包按名字取。
 */
import { randomUUID } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { revisionOf, type AccountData, type Item } from './account-data/store.ts';
import { KiteError } from './errors.ts';
import { SYSTEM_SKILLS, parseFrontmatter, skillFiles, systemSkillsDirectory, textContent } from './harness/context/skills.ts';
import { safePath } from './paths.ts';

/** Agent Skills 标准的名字：小写字母、数字和连字符，最长 64。 */
const skillNameSchema = z.string().min(1).max(64).regex(/^[a-z0-9]+(-[a-z0-9]+)*$/, 'skill 的名字只能用小写字母、数字和连字符');
const relativePath = z.string().min(1).max(255)
  .refine(safePath, '文件路径须是文件夹里的相对路径，不含 . 或 ..');
const PACKAGE_BYTES = 4 * 1024 * 1024;
const skillFileSchema = z.object({
  path: relativePath,
  content: z.string(),
  /** 省略时仍是 UTF-8 文本，保持已同步的文本包可读；二进制用规范 base64。 */
  encoding: z.literal('base64').optional(),
}).strict().refine((file) => file.encoding !== 'base64' || Buffer.from(file.content, 'base64').toString('base64') === file.content, '文件的 base64 内容无效');
const fileBytes = (file: z.infer<typeof skillFileSchema>) => Buffer.from(file.content, file.encoding ?? 'utf8');
const skillPackageSchema = z.object({
  version: z.literal(1),
  name: skillNameSchema,
  /** 必须有文本格式的根 SKILL.md；其余文件可用 base64 保留原始字节。 */
  files: z.array(skillFileSchema).min(1).max(200),
}).strict()
  .refine((value) => value.files.some((file) => file.path === 'SKILL.md'), '缺少 SKILL.md')
  .refine((value) => value.files.every((file) => file.path !== 'SKILL.md' || (file.encoding === undefined && !file.content.includes('\0'))), 'SKILL.md 必须是 UTF-8 文本')
  .refine((value) => new Set(value.files.map((file) => file.path)).size === value.files.length, '文件路径重复')
  .refine((value) => value.files.reduce((total, file) => total + fileBytes(file).length, 0) <= PACKAGE_BYTES, 'skill 超过 4 MiB')
  .refine((value) => {
    const skill = value.files.find((file) => file.path === 'SKILL.md');
    const name = skill && parseFrontmatter(skill.content).name?.trim();
    return !name || name === value.name;
  }, 'SKILL.md 头里的 name 须与 skill 的名字一致');
export type SkillPackage = z.infer<typeof skillPackageSchema>;
/** 列表里的一项与保存的结果。defaultRevision 只有系统层的 skill 有，是默认内容的版本；与 revision 不同就是改过，可以恢复默认。 */
export interface SkillSummary { name: string; revision: string; defaultRevision?: string }
/** 按名字取的整包。 */
export interface SkillSnapshot { skill: SkillPackage; revision: string; defaultRevision?: string }
/**
 * 写进数据目录的每个 skill 文件夹里记着它的版本，点开头，skill 工具列文件时跳过（见 skillFiles）。前缀是落盘格式的版本：
 * 落盘的写法变了（文件编码、可执行位这类）就加 1，升级后的第一次对账把旧格式写的全部重写一遍。
 */
const REVISION_FILE = '.kite-revision';
const LAYOUT = 1;

/** 账号条目不合本机契约时当作没有：按名读取与核对版本用它判断，列表里没有是因为对账时写不进数据目录。 */
function accountSkill(item: Item | undefined): SkillPackage | undefined {
  if (!item) return undefined;
  const parsed = skillPackageSchema.safeParse(item.body);
  return parsed.success && parsed.data.name === item.id ? parsed.data : undefined;
}

/** 把磁盘上的一个 skill 文件夹读成包；二进制原字节编码，文本仍用原有格式。 */
function readSkillPackage(name: string, directory: string): SkillPackage {
  const files = skillFiles(directory).map((path) => {
    const bytes = readFileSync(join(directory, path));
    const content = textContent(bytes);
    return content !== undefined ? { path, content } : { path, content: bytes.toString('base64'), encoding: 'base64' as const };
  });
  return skillPackageSchema.parse({ version: 1, name, files });
}

export class Skills {
  /** 系统层的默认内容与它的版本，从运行目录读一次。 */
  private readonly builtins: Map<string, { skill: SkillPackage; revision: string }>;
  /** 已写进数据目录的版本，按名字；进程启动时为空，第一次对账按文件夹里的版本标记认出已经写好的。 */
  private materialized = new Map<string, string>();

  constructor(private directory: string, private data: AccountData, system: string = systemSkillsDirectory) {
    this.builtins = new Map(SYSTEM_SKILLS.flatMap((name) => {
      if (!existsSync(join(system, name))) return [];
      const skill = readSkillPackage(name, join(system, name));
      return [[name, { skill, revision: revisionOf(skill) }] as const];
    }));
  }

  /**
   * 系统层加本机已写进数据目录的，按名字排，只带名字与版本：版本就是对账时账号条目的版本，不为列表读整包。
   * 账号里不合本机契约的写不进数据目录，也就不列。
   */
  list(): SkillSummary[] {
    return [...new Set([...this.builtins.keys(), ...this.materialized.keys()])].sort().map((name) => this.summary(name));
  }

  /** 按名字取整包：账号里自建或改过的那份，没有就是系统层的默认。 */
  get(name: string): SkillSnapshot {
    const item = this.data.get('skill', name);
    const stored = accountSkill(item);
    const builtin = this.builtins.get(name);
    const current = stored ? { skill: stored, revision: item!.revision } : builtin;
    if (!current) throw new KiteError('skill 不存在，请刷新列表', 404);
    return { ...current, ...(builtin ? { defaultRevision: builtin.revision } : {}) };
  }

  /** 账号里这一项的版本；系统层没改过的在账号里没有，是 null。 */
  accountRevision(name: string): string | null { return this.data.get('skill', name)?.revision ?? null; }

  /** 系统层的默认内容，恢复默认时按它保存。 */
  builtin(name: string): SkillPackage {
    const builtin = this.builtins.get(name);
    if (!builtin) throw new KiteError('自建的 skill 没有默认内容');
    return builtin.skill;
  }

  /** 和默认内容一样的系统层 skill 不算改过，账号里不留副本。 */
  isDefault(skill: SkillPackage): boolean {
    const builtin = this.builtins.get(skill.name);
    return !!builtin && builtin.revision === revisionOf(skill);
  }

  /** 新建前的校验，结果先写进账号级数据再写本机：系统层的只能修改，同名已有不同内容时冲突，相同内容重复保存是幂等的。 */
  validateNew(value: unknown): SkillPackage {
    const skill = this.parse(value);
    if (this.builtins.has(skill.name)) throw new KiteError('随 kited 带的 skill 不能新建，请直接修改', 409);
    const item = this.data.get('skill', skill.name);
    if (accountSkill(item) && item!.revision !== revisionOf(skill)) throw new KiteError('同名的 skill 已存在，请换个名字', 409);
    return skill;
  }

  /** 修改前的校验，结果先写进账号级数据再写本机。 */
  validate(name: string, expectedRevision: string, value: unknown): SkillPackage {
    const skill = this.parse(value);
    if (name !== skill.name) throw new KiteError('skill 的名字与请求目标不一致');
    this.check(name, expectedRevision);
    return skill;
  }

  /** 新建或修改的 skill 已经过校验，账号里已写入或删掉：等于默认的本机也不留，其余写进数据目录。返回列表里的那一项。 */
  save(skill: SkillPackage): SkillSummary {
    if (this.isDefault(skill)) this.remove(skill.name);
    else this.materialize(skill);
    return this.summary(skill.name);
  }

  /** 删除前的校验：系统层的不能删，只能恢复默认。 */
  validateDelete(name: string, expectedRevision: string): void {
    if (this.builtins.has(name)) throw new KiteError('随 kited 带的 skill 不能删除，可以恢复默认');
    this.check(name, expectedRevision);
  }

  /** 从数据目录去掉这个 skill 的文件夹。 */
  remove(name: string): void {
    rmSync(join(this.directory, name), { recursive: true, force: true });
    this.materialized.delete(name);
  }

  /**
   * 账号里的一项写进数据目录：对账只带名字和版本，版本没变的不读整包也不重写。进程刚起来时还没记下的，看文件夹里的版本标记，
   * 对得上就是上次写好的，不重写也不算变化；文件夹里的内容被手改过不会因此修复，删掉文件夹（或标记）后下次启动重写。
   * 内容不合本机契约的抛错，由对账方跳过。返回是否有变化。
   */
  cache(name: string, revision: string): boolean {
    if (this.materialized.get(name) === revision) return false;
    if (!this.materialized.has(name) && this.marker(name) === `${LAYOUT}:${revision}`) {
      this.materialized.set(name, revision);
      return false;
    }
    const skill = this.parse(this.data.get('skill', name)?.body);
    if (skill.name !== name) throw new KiteError('skill 的名字与账号里的条目不一致');
    this.materialize(skill, revision);
    return true;
  }

  /** 账号里已经没有的从数据目录去掉，系统层的退回默认；返回是否有变化。 */
  keep(names: ReadonlySet<string>): boolean {
    let entries: string[];
    try { entries = readdirSync(this.directory); } catch { return false; }
    const gone = entries.filter((name) => !name.startsWith('.') && !names.has(name));
    for (const name of gone) this.remove(name);
    return gone.length > 0;
  }

  parse(value: unknown): SkillPackage {
    const parsed = skillPackageSchema.safeParse(value);
    if (!parsed.success) throw new KiteError(`skill 无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    return parsed.data;
  }

  /** 修改和删除前核对版本：账号里改过的按那一份，没改过的系统层按默认内容。 */
  private check(name: string, revision: string): void {
    const item = this.data.get('skill', name);
    const current = accountSkill(item) ? item!.revision : this.builtins.get(name)?.revision;
    if (!current) throw new KiteError('skill 不存在，请刷新列表', 404);
    if (revision !== current) throw new KiteError('skill 已更新，请刷新后重试', 409);
  }

  /** 列表里的一项：写进数据目录的按那一版，否则是系统层的默认。 */
  private summary(name: string): SkillSummary {
    const builtin = this.builtins.get(name);
    return { name, revision: this.materialized.get(name) ?? builtin!.revision, ...(builtin ? { defaultRevision: builtin.revision } : {}) };
  }

  /** 文件夹里的版本标记；没有文件夹或标记时为 undefined。 */
  private marker(name: string): string | undefined {
    try { return readFileSync(join(this.directory, name, REVISION_FILE), 'utf8'); } catch { return undefined; }
  }

  /** 整个文件夹先写进临时目录再换上，代理不会读到写了一半的 skill。 */
  private materialize(skill: SkillPackage, revision = revisionOf(skill)): void {
    mkdirSync(this.directory, { recursive: true });
    const temporary = join(this.directory, `.tmp-${skill.name}-${randomUUID()}`);
    try {
      mkdirSync(temporary);
      for (const file of skill.files) {
        const target = join(temporary, file.path);
        mkdirSync(dirname(target), { recursive: true });
        const bytes = fileBytes(file);
        writeFileSync(target, bytes);
        if (bytes[0] === 0x23 && bytes[1] === 0x21) chmodSync(target, 0o755);
      }
      writeFileSync(join(temporary, REVISION_FILE), `${LAYOUT}:${revision}`);
      const target = join(this.directory, skill.name);
      rmSync(target, { recursive: true, force: true });
      renameSync(temporary, target);
    } finally { rmSync(temporary, { recursive: true, force: true }); }
    this.materialized.set(skill.name, revision);
  }
}
