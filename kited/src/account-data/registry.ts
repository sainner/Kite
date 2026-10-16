/**
 * 项目登记表与项目约束，随账号级数据在工作机之间同步。有远程的项目以远程为身份：同一远程总是同一个项目，ID 由先登记它的工作机生成。
 * 两台工作机没同步上时各自登记了同一远程，会出现两个项目；之后按归一化的远程合并，最早登记的（createdAt、ID 依次比较）保留，
 * 其余记为并入它，各机把本机的检出改挂过去。
 * 没有远程的项目以 ID 为身份，各工作机上的检出互为远程（workspace/peer-git.ts）；之后可以再设远程，ID 不变。见 docs/项目与远程仓库.md。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { httpsRemote, normalizeRemote, remoteName } from '../remote-url.ts';
import { revisionOf, type AccountData } from './store.ts';

/** remote 是归一化的远程地址，url 是 HTTPS 写法的访问地址；没有远程的项目两者都为 null。 */
export interface RegisteredProject {
  id: string;
  name: string;
  remote: string | null;
  url: string | null;
  createdAt: number;
  icon: string;
  color: string;
  /** 工作机睡眠前，把这个项目里正在工作的工作区换到别的工作机。 */
  autoHandover?: boolean;
}

/** 项目约束，首期只有工具规则；没设置过时是不限制的黑名单。 */
export interface ProjectConstraints {
  tools: { mode: 'allow' | 'deny'; tools: string[] };
  revision: string;
}

type Stored = Omit<RegisteredProject, 'id'> | { mergedInto: string };

const appearance = z.object({
  icon: z.string().min(1).max(100).regex(/^[a-zA-Z0-9.]+$/).optional(),
  color: z.enum(['primary', 'accent', 'green', 'purple', 'orange', 'pink']).optional(),
}).strict().refine((value) => value.icon !== undefined || value.color !== undefined);
const settings = z.object({ autoHandover: z.boolean() }).strict();
const constraintsWrite = z.object({
  tools: z.object({ mode: z.enum(['allow', 'deny']), tools: z.array(z.string().trim().min(1).max(64)).max(64) }).strict(),
  expectedRevision: z.string().min(1),
}).strict();
const defaultConstraints = { tools: { mode: 'deny' as const, tools: [] as string[] } };
type ToolRule = ProjectConstraints['tools'];

/** 两份工具规则里更严的组合：都是黑名单取并集，都是白名单取交集，一白一黑时白名单去掉黑名单里的。 */
function stricter(a: ToolRule, b: ToolRule): ToolRule {
  if (a.mode === 'deny' && b.mode === 'deny') return { mode: 'deny', tools: [...new Set([...a.tools, ...b.tools])].sort() };
  const [allow, other] = a.mode === 'allow' ? [a, b] : [b, a];
  return { mode: 'allow', tools: allow.tools.filter((tool) => other.mode === 'allow' ? other.tools.includes(tool) : !other.tools.includes(tool)) };
}

export class ProjectRegistry {
  constructor(private data: AccountData) {}

  list(): RegisteredProject[] {
    return this.data.list('project').flatMap(({ id, body }) => 'mergedInto' in body ? [] : [{ id, ...(body as Omit<RegisteredProject, 'id'>) }])
      .sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
  }

  /** 登记表里的项目，没有时 404。 */
  require(id: string): RegisteredProject {
    const project = this.get(id);
    if (!project) throw new KiteError('项目登记表里没有这个项目', 404);
    return project;
  }

  get(id: string): RegisteredProject | undefined {
    const body = this.data.get('project', id)?.body as Stored | undefined;
    return body && !('mergedInto' in body) ? { id, ...body } : undefined;
  }

  /** 项目并入了别的项目时给出最终保留的那个；本来就在登记表里的给它自己。 */
  canonical(id: string): string | undefined {
    const end = this.chainEnd(id);
    return end?.registered ? end.id : undefined;
  }

  /** 项目（或它最终并入的项目）从登记表删掉了。 */
  deleted(id: string): boolean {
    const end = this.chainEnd(id);
    return !!end && !end.registered && this.data.removed('project', end.id);
  }

  /** 沿并入链走到头：停在登记着的项目，或者链断在一条没有内容的条目上；链太长时放弃。 */
  private chainEnd(id: string): { id: string; registered: boolean } | undefined {
    for (let current = id, hops = 0; hops < 16; hops++) {
      const body = this.data.get('project', current)?.body as Stored | undefined;
      if (!body || !('mergedInto' in body)) return { id: current, registered: !!body };
      current = body.mergedInto;
    }
    return undefined;
  }

  /** 删除项目：登记与约束一起删，各工作机看到后移除本机的检出。之后再添加同一远程或文件夹是新项目。 */
  remove(id: string): void {
    this.require(id);
    this.data.remove('project', id);
    this.data.remove('constraints', id);
  }

  byRemote(remote: string): RegisteredProject | undefined {
    return this.list().find((project) => project.remote === remote);
  }

  /** 按远程登记，同一远程总是得到同一个项目。 */
  register(raw: string): RegisteredProject {
    const remote = normalizeRemote(raw);
    if (!remote) throw new KiteError('远程地址格式无法识别');
    const existing = this.byRemote(remote);
    if (existing) return existing;
    this.save({ id: crypto.randomUUID(), name: remoteName(raw), remote, url: httpsRemote(raw), createdAt: Date.now(), icon: 'folder', color: 'primary' });
    return this.byRemote(remote)!;
  }

  /** 登记没有远程的项目。 */
  createLocal(name: string): RegisteredProject {
    const project: RegisteredProject = { id: crypto.randomUUID(), name, remote: null, url: null, createdAt: Date.now(), icon: 'folder', color: 'primary' };
    this.save(project);
    return project;
  }

  /** 没有远程的项目能不能设这个远程，能的话给出归一化的地址。推送之前先查，免得把内容推到别的项目的远程。 */
  checkRemote(id: string, raw: string): string {
    if (this.require(id).remote) throw new KiteError('这个项目已经有远程', 409);
    const remote = normalizeRemote(raw);
    if (!remote) throw new KiteError('远程地址格式无法识别');
    if (this.byRemote(remote)) throw new KiteError('这个远程已属于另一个项目', 409);
    return remote;
  }

  /** 没有远程的项目设了远程：改地址，项目 ID 不变。调用方已把内容推到这个远程。 */
  setRemote(id: string, raw: string): RegisteredProject {
    const remote = this.checkRemote(id, raw);
    const next = { ...this.require(id), remote, url: httpsRemote(raw) };
    this.save(next);
    return next;
  }

  setAppearance(id: string, raw: unknown): RegisteredProject { return this.change(id, appearance, raw, '项目外观要写 icon 或 color'); }

  setSettings(id: string, raw: unknown): RegisteredProject { return this.change(id, settings, raw, '项目设置要写 autoHandover'); }

  private change<T extends object>(id: string, schema: z.ZodType<T>, raw: unknown, message: string): RegisteredProject {
    const project = this.require(id);
    const parsed = schema.safeParse(raw);
    if (!parsed.success) throw new KiteError(message);
    const next = { ...project, ...parsed.data };
    this.save(next);
    return next;
  }

  constraints(id: string): ProjectConstraints {
    this.require(id);
    const body = this.storedConstraints(id) ?? defaultConstraints;
    return { ...body, revision: revisionOf(body) };
  }

  private storedConstraints(id: string): Omit<ProjectConstraints, 'revision'> | undefined {
    return this.data.get('constraints', id)?.body as Omit<ProjectConstraints, 'revision'> | undefined;
  }

  saveConstraints(id: string, raw: unknown): ProjectConstraints {
    const parsed = constraintsWrite.safeParse(raw);
    if (!parsed.success) throw new KiteError('项目约束要写 tools 与 expectedRevision；工具最多 64 个');
    const { expectedRevision, ...body } = parsed.data;
    if (this.constraints(id).revision !== expectedRevision) throw new KiteError('项目约束已被其他设备修改，请刷新后重试', 409);
    this.data.put('constraints', id, body);
    return this.constraints(id);
  }

  /**
   * 同一远程有几个项目时把后登记的记为并入最早的；几台工作机各自做也写出同样的内容。
   * 并入的项目设过约束的，保留的项目改用两份里更严的组合，检出改挂过去后工具限制不会放宽；项目凭据按 canonical 归到保留的项目。
   */
  reconcile(): void {
    const groups = new Map<string, RegisteredProject[]>();
    for (const project of this.list()) if (project.remote) groups.set(project.remote, [...groups.get(project.remote) ?? [], project]);
    for (const [, [kept, ...merged]] of groups) {
      for (const project of merged) {
        const rule = this.storedConstraints(project.id);
        if (rule) {
          this.data.put('constraints', kept!.id, { tools: stricter((this.storedConstraints(kept!.id) ?? defaultConstraints).tools, rule.tools) });
          this.data.remove('constraints', project.id);
        }
        this.data.put('project', project.id, { mergedInto: kept!.id });
      }
    }
  }

  private save({ id, ...body }: RegisteredProject): void {
    this.data.put('project', id, body);
    this.reconcile();
  }
}
