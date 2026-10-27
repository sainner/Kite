/**
 * 本线程看到或改过的文件内容版本，给 patch 提示「上次看到之后别处改过」；只提示、不拦补丁，见 docs/harness-主循环.md 的 patch。
 * read、patch 直接登记；shell 改的按命令前后对比，看的按输出里有没有这个文件的原文认，命令里只提到文件名不算。
 * 记录只说明看到过哪一版，不代表内容仍在模型上下文里。
 */
import { randomUUID } from 'node:crypto';
import { readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { z } from 'zod';
import { within } from '../paths.ts';
import { statVersion, textContent, textVersion } from '../workspace/files.ts';

const savedSchema = z.record(z.string(), z.string());

/** 命令里和输出里像路径的片段：不含空白、引号和 shell 记号，是不是文件由 workspaceFile 核对。 */
const PATH_TOKEN = /[^\s'"`:;,()<>|&=*?$[\]{}\\]+/g;
/** 搜索结果行：路径:行号:原文，上下文行用 - 隔开。 */
const LOCATED = /^(.+?)[:-]\d+[:-](.*)$/;
/** 原文前的行号（只搜一个文件的 rg -n、nl、cat -n）或 diff 的增删记号。 */
const MARK = /^\s*\d+[:\t-]|^[+-]/;
/** 不带路径时，一行原文去掉缩进后至少这么长才算数，免得 }、import 这类到处都有的行认错文件。 */
const DISTINCT = 16;
/** 一条命令最多核对这么多字的内容，免得一条列文件的命令读遍整个数据目录。 */
const SEEN_BUDGET = 8 * 1024 * 1024;
/** 最多记这么多个文件，超出时丢最久没登记的：每条 shell 命令前后都要把记着的文件看一遍。 */
const LIMIT = 2000;

/** 命令前后对比用的文件状态；不在了或看不了为空串。 */
function stamp(path: string): string {
  try { return statVersion(statSync(path, { bigint: true })); } catch { return ''; }
}

/** 能当文本登记的内容，规则同 read；否则为空。 */
function text(path: string): string | undefined {
  try {
    const stat = statSync(path);
    return stat.isFile() ? textContent(stat.size, () => readFileSync(path, 'utf8')) : undefined;
  } catch { return undefined; }
}

/** 片段指向的工作目录内普通文件的真实路径。 */
function workspaceFile(root: string, token: string): string | undefined {
  if (!/[/.]/.test(token)) return undefined;
  try {
    const target = resolve(root, token);
    if (!statSync(target, { throwIfNoEntry: false })?.isFile()) return undefined;
    const real = realpathSync(target);
    return within(real, root) ? real : undefined;
  } catch { return undefined; } // 名字过长、中间段不是目录之类的片段不是文件。
}

export class KnownFiles {
  private readonly versions = new Map<string, string>();
  private saving = false;

  /** 键是真实路径。file 给出时记录存进这个文件，kited 重启后接着用；读不出来就从空开始，下次存时整份覆盖。 */
  constructor(private readonly root: string, private readonly file?: string) {
    if (!file) return;
    try { for (const [path, version] of Object.entries(savedSchema.parse(JSON.parse(readFileSync(file, 'utf8'))))) this.versions.set(path, version); }
    catch { /* 见上。 */ }
  }

  get(path: string): string | undefined { return this.versions.get(path); }

  set(path: string, version: string): void {
    // 重新放到最后，超出上限时先丢最久没登记的。
    const changed = this.versions.get(path) !== version;
    this.versions.delete(path);
    this.versions.set(path, version);
    if (this.versions.size > LIMIT) this.versions.delete(this.versions.keys().next().value!);
    if (changed) this.save();
  }

  delete(path: string): void {
    if (this.versions.delete(path)) this.save();
  }

  /** shell 命令开始前记下已登记文件的状态，命令结束后交给 settle。 */
  watch(): Map<string, string> {
    return new Map([...this.versions.keys()].map((path) => [path, stamp(path)]));
  }

  /**
   * 命令期间变了的已登记文件算这条命令改的，按现在的内容登记；命令开始前就变了的不动，patch 照常提示。
   * 同一时间别处改的也会算进这条命令，只是少一次提示。转到后台的命令在交给终端时结算，之后再改的按别处改的算。
   */
  settle(before: Map<string, string>): void {
    for (const [path, previous] of before) {
      if (stamp(path) === previous) continue;
      const content = text(path);
      if (content === undefined) this.delete(path);
      else this.set(path, textVersion(content));
    }
  }

  /**
   * 输出里有原文的工作目录内文件按现在的内容登记：带这个文件路径的搜索结果行对得上一行，
   * 或不带路径时对得上至少两行有分量的原文（文件本身只有一行有分量的要对上它）。候选是命令里和输出里提到的文件。
   */
  seen(command: string, output: string): void {
    const files = new Map<string, string | undefined>();
    const file = (token: string) => {
      if (!files.has(token)) files.set(token, workspaceFile(this.root, token));
      return files.get(token);
    };
    const located = new Map<string, Set<string>>();
    const lines = new Set<string>();
    for (const line of output.split('\n')) {
      const match = LOCATED.exec(line);
      const path = match ? file(match[1]!) : undefined;
      if (path) located.set(path, (located.get(path) ?? new Set()).add(match![2]!.trim()));
      else for (const form of [line.trim(), line.replace(MARK, '').trim()]) if (form.length >= DISTINCT) lines.add(form);
    }
    for (const token of `${command}\n${output}`.match(PATH_TOKEN) ?? []) file(token);

    // 带路径的搜索结果在逐行时先放进了 files，先核对；再按提到的先后。
    let budget = SEEN_BUDGET;
    for (const path of new Set(files.values())) {
      const searched = path && located.get(path);
      if (!path || (!searched && !lines.size)) continue;
      const content = text(path);
      if (content === undefined) continue;
      if ((budget -= content.length) < 0) break;
      let hits = 0, distinct = 0, shown = false;
      for (const line of new Set(content.split('\n').map((line) => line.trim()))) {
        if (line && searched && searched.has(line)) { shown = true; break; }
        if (line.length >= DISTINCT) { distinct++; if (lines.has(line)) hits++; }
      }
      if (shown || hits >= 2 || (hits === 1 && distinct === 1)) this.set(path, textVersion(content));
    }
  }

  /** 同一轮里的多次登记合成一次写盘。记录只用来提示，存不下或关机前没来得及写不影响工具本身，下次写全量。 */
  private save(): void {
    if (!this.file || this.saving) return;
    this.saving = true;
    setImmediate(() => {
      this.saving = false;
      const temp = `${this.file}.${randomUUID()}.tmp`;
      try {
        writeFileSync(temp, JSON.stringify(Object.fromEntries(this.versions)), { mode: 0o600 });
        renameSync(temp, this.file!);
      } catch { rmSync(temp, { force: true }); }
    });
  }
}
