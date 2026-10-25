/**
 * 项目登记表、项目约束与项目的布局，随账号级数据在工作机之间同步。有远程的项目以远程为身份：同一远程总是同一个项目，ID 由先登记它的工作机生成。
 * 两台工作机没同步上时各自登记了同一远程，会出现两个项目；之后按归一化的远程合并，最早登记的（createdAt、ID 依次比较）保留，
 * 其余记为并入它，各机把本机的检出改挂过去。
 * 没有远程的项目以 ID 为身份，各工作机上的检出互为远程（workspace/peer-git.ts）；之后可以再设远程，ID 不变。见 docs/项目与远程仓库.md。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { HANDOVER_NEEDS, type HandoverNeed } from '../environment.ts';
import { httpsRemote, normalizeRemote, remoteName } from '../remote-url.ts';
import { revisionOf, type AccountData } from './store.ts';
import { parseProjectExecution, stricterExecution, type ProjectExecution } from '../execution/grants.ts';
import { serverNamesSchema } from '../mcp/names.ts';
import { pageSchema } from '../workspace/files.ts';
import { deviceSchema } from '../preview/devices.ts';

/** 集成方式：直接合入主线并推送，或推分支提交 PR，见 docs/项目与远程仓库.md「工作区与集成」。 */
export const INTEGRATIONS = ['merge', 'pullRequest'] as const;
export type Integration = (typeof INTEGRATIONS)[number];
/** 按仓库情况选出的集成方式与理由。 */
export interface IntegrationChoice { integration: Integration; integrationReason?: string }

/** remote 是归一化的远程地址，url 是 HTTPS 写法的访问地址；没有远程的项目两者都为 null。 */
export interface RegisteredProject extends IntegrationChoice {
  id: string;
  name: string;
  remote: string | null;
  url: string | null;
  createdAt: number;
  icon: string;
  color: string;
  /** 工作机睡眠、登出、重启或关机前，把这个项目里正在工作的工作区换到别的工作机。 */
  autoHandover?: boolean;
  /** 自动换机的目标须满足的环境。 */
  handoverNeeds?: HandoverNeed[];
}

/** 项目约束：工具规则与执行授权的基础和边界（docs/Agent与插件契约.md §3.2）；没设置过时工具是不限制的黑名单，执行授权没有基础许可也没有禁止。 */
export interface ProjectConstraints {
  tools: { mode: 'allow' | 'deny'; tools: string[] };
  execution?: ProjectExecution;
  /** 本项目禁用的外部 MCP 服务，按服务名；任何层都打不开。 */
  mcp?: { deny: string[] };
  revision: string;
}

type Stored = Omit<RegisteredProject, 'id'> | { mergedInto: string };

/**
 * 布局是项目的一张配方（docs/台面与停靠栏.md「布局」）：成员按种类记下找现成实例或新建要用的信息，arrangement 是成员的摆法树，
 * 每个成员下标在树里恰好出现一次。kited 只校验与保存，不解释摆法。
 */
export type LayoutMember = { kind: 'agent'; role: string } | { kind: 'files'; page?: z.infer<typeof pageSchema> } | { kind: 'terminal' }
  | { kind: 'preview'; target: string; device?: z.infer<typeof deviceSchema> } | { kind: 'plugin'; definition: string };
export type LayoutArrangement = { kind: 'member'; index: number }
  | { kind: 'split'; axis: 'horizontal' | 'vertical'; ratio: number; first: LayoutArrangement; second: LayoutArrangement };
export interface Layout { name: string; members: LayoutMember[]; arrangement: LayoutArrangement }
export interface ProjectLayout extends Layout { id: string; revision: string }

const identifier = z.string().trim().min(1).max(200);
/** 布局 ID 由客户端给，与其他客户端生成的 ID 一样是 UUID 这类单段字符。 */
export const layoutIdSchema = z.string().regex(/^[A-Za-z0-9._-]{1,80}$/);
const layoutMember = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('agent'), role: identifier }).strict(),
  z.object({ kind: z.literal('files'), page: pageSchema.optional() }).strict(),
  z.object({ kind: z.literal('terminal') }).strict(),
  z.object({ kind: z.literal('preview'), target: identifier, device: deviceSchema.optional() }).strict(),
  z.object({ kind: z.literal('plugin'), definition: identifier }).strict(),
]);
const layoutArrangement: z.ZodType<LayoutArrangement> = z.lazy(() => z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('member'), index: z.number().int().min(0) }).strict(),
  z.object({ kind: z.literal('split'), axis: z.enum(['horizontal', 'vertical']), ratio: z.number().gt(0).lt(1),
    first: layoutArrangement, second: layoutArrangement }).strict(),
]));
const MAX_LAYOUT_MEMBERS = 32;
/** 摆法树里出现的成员下标，按出现顺序；同一下标出现两次时记两次。 */
const arranged = (node: LayoutArrangement): number[] => node.kind === 'member' ? [node.index] : [...arranged(node.first), ...arranged(node.second)];
export const layoutSchema = z.object({
  name: z.string().trim().min(1).max(80).refine((name) => !/[\r\n]/.test(name), '名称只能是一行'),
  members: z.array(layoutMember).min(1).max(MAX_LAYOUT_MEMBERS),
  arrangement: layoutArrangement,
}).strict().refine((layout) => {
  const indexes = arranged(layout.arrangement);
  return indexes.length === layout.members.length && new Set(indexes).size === indexes.length && indexes.every((index) => index < layout.members.length);
}, '摆法里每个成员要恰好出现一次');
const layoutWrite = z.object({ expectedRevision: z.string().min(1).optional(), layout: layoutSchema }).strict();
/** 账号级数据里布局的条目 ID：项目在前，删除条目时也能从 ID 认出是哪个项目的。 */
const layoutKey = (projectId: string, layoutId: string) => `${projectId}:${layoutId}`;
export const layoutProject = (key: string): string => key.slice(0, key.indexOf(':'));

const appearance = z.object({
  icon: z.string().min(1).max(100).regex(/^[a-zA-Z0-9.]+$/).optional(),
  color: z.enum(['primary', 'accent', 'green', 'purple', 'orange', 'pink']).optional(),
}).strict().refine((value) => value.icon !== undefined || value.color !== undefined);
const settings = z.object({
  integration: z.enum(INTEGRATIONS).optional(),
  autoHandover: z.boolean().optional(),
  handoverNeeds: z.array(z.enum(HANDOVER_NEEDS)).transform((needs) => [...new Set(needs)]).optional(),
}).strict().refine((value) => value.integration !== undefined || value.autoHandover !== undefined || value.handoverNeeds !== undefined);
const constraintsWrite = z.object({
  tools: z.object({ mode: z.enum(['allow', 'deny']), tools: z.array(z.string().trim().min(1).max(64)).max(64) }).strict(),
  execution: z.unknown().optional(),
  mcp: z.object({ deny: serverNamesSchema }).strict().optional(),
  expectedRevision: z.string().min(1),
}).strict();
const defaultConstraints: Omit<ProjectConstraints, 'revision'> = { tools: { mode: 'deny', tools: [] } };
/** 集成方式出现之前登记的项目按直接合入。 */
const registered = (id: string, body: Omit<RegisteredProject, 'id' | 'integration'> & Partial<IntegrationChoice>): RegisteredProject =>
  ({ id, integration: 'merge', ...body });
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
    return this.data.list('project').flatMap(({ id, body }) => 'mergedInto' in body ? [] : [registered(id, body as Omit<RegisteredProject, 'id'>)])
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
    return body && !('mergedInto' in body) ? registered(id, body) : undefined;
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

  /** 删除项目：登记、约束与布局一起删，各工作机看到后移除本机的检出。之后再添加同一远程或文件夹是新项目。 */
  remove(id: string): void {
    const layouts = this.layouts(id);
    this.data.remove('project', id);
    this.data.remove('constraints', id);
    for (const layout of layouts) this.data.remove('layout', layoutKey(id, layout.id));
  }

  /** 项目的布局，按名字排。 */
  layouts(projectId: string): ProjectLayout[] {
    this.require(projectId);
    const prefix = layoutKey(projectId, '');
    return this.data.list('layout').filter((item) => item.id.startsWith(prefix))
      .map((item) => ({ id: item.id.slice(prefix.length), revision: item.revision, ...(item.body as unknown as Layout) }))
      .sort((a, b) => a.name.localeCompare(b.name, 'zh') || a.id.localeCompare(b.id));
  }

  /** 新建（不带 expectedRevision）或整体替换一个布局；版本不符、或新建的 ID 已有别的内容时 409。 */
  saveLayout(projectId: string, layoutId: string, raw: unknown): ProjectLayout {
    this.require(projectId);
    if (!layoutIdSchema.safeParse(layoutId).success) throw new KiteError('布局 ID 无效');
    const parsed = layoutWrite.safeParse(raw);
    if (!parsed.success) throw new KiteError(`布局无效：${parsed.error.issues[0]?.message ?? ''}`);
    const { expectedRevision, layout } = parsed.data;
    const item = this.data.put('layout', layoutKey(projectId, layoutId), layout as unknown as Record<string, unknown>, expectedRevision ?? null);
    return { id: layoutId, revision: item.revision, ...layout };
  }

  removeLayout(projectId: string, layoutId: string, expectedRevision: string): void {
    this.require(projectId);
    this.data.remove('layout', layoutKey(projectId, layoutId), expectedRevision);
  }

  byRemote(remote: string): RegisteredProject | undefined {
    return this.list().find((project) => project.remote === remote);
  }

  /** 按远程登记，同一远程总是得到同一个项目；已登记的原样返回，不改它的设置。choice 是新登记时的集成方式。 */
  register(raw: string, choice: IntegrationChoice = { integration: 'merge' }): RegisteredProject {
    const remote = normalizeRemote(raw);
    if (!remote) throw new KiteError('远程地址格式无法识别');
    const existing = this.byRemote(remote);
    if (existing) return existing;
    this.save({ id: crypto.randomUUID(), name: remoteName(raw), remote, url: httpsRemote(raw), createdAt: Date.now(), icon: 'folder', color: 'primary',
      ...choice });
    return this.byRemote(remote)!;
  }

  /** 登记没有远程的项目，只能直接合入。id 由调用方先定时，检出可以按它先建好。 */
  createLocal(name: string, id: string = crypto.randomUUID()): RegisteredProject {
    const project: RegisteredProject = { id, name, remote: null, url: null, createdAt: Date.now(), icon: 'folder', color: 'primary', integration: 'merge' };
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

  /** 没有远程的项目设了远程：改地址，项目 ID 不变，集成方式按 choice 重选。调用方已把内容推到这个远程。 */
  setRemote(id: string, raw: string, choice: IntegrationChoice): RegisteredProject {
    const remote = this.checkRemote(id, raw);
    const { integrationReason: _, ...project } = this.require(id);
    const next = { ...project, remote, url: httpsRemote(raw), ...choice };
    this.save(next);
    return next;
  }

  setAppearance(id: string, raw: unknown): RegisteredProject { return this.change(id, appearance, raw, '项目外观要写 icon 或 color'); }

  /** 手动设集成方式后不再带自动选择的理由；没有远程的项目只能直接合入。 */
  setSettings(id: string, raw: unknown): RegisteredProject {
    return this.change(id, settings, raw, `项目设置要写 integration（${INTEGRATIONS.join('、')}）、autoHandover 或 handoverNeeds（${HANDOVER_NEEDS.join('、')}）`,
      (next, data) => {
        if (data.integration === 'pullRequest' && !next.remote) throw new KiteError('没有远程的项目只能直接合入');
        if (data.integration !== undefined) delete next.integrationReason;
      });
  }

  /** 合并 raw 里的改动后保存；adjust 可以再校验或调整合并结果。 */
  private change<T extends object>(id: string, schema: z.ZodType<T>, raw: unknown, message: string,
    adjust?: (next: RegisteredProject, data: T) => void): RegisteredProject {
    const project = this.require(id);
    const parsed = schema.safeParse(raw);
    if (!parsed.success) throw new KiteError(message);
    const next: RegisteredProject = { ...project, ...parsed.data };
    adjust?.(next, parsed.data);
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
    const { expectedRevision, execution, mcp, ...rest } = parsed.data;
    const body = { ...rest, ...(execution === undefined ? {} : { execution: parseProjectExecution(execution) }), ...(mcp?.deny.length ? { mcp } : {}) };
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
          const keptRule = this.storedConstraints(kept!.id) ?? defaultConstraints;
          // 没设执行约束的一方按默认（没有基础许可）算，合起来同样取更严的，不把另一方的基础许可带过去。
          const execution = rule.execution || keptRule.execution
            ? stricterExecution(parseProjectExecution(keptRule.execution), parseProjectExecution(rule.execution)) : undefined;
          const deny = serverNamesSchema.parse([...keptRule.mcp?.deny ?? [], ...rule.mcp?.deny ?? []]);
          this.data.put('constraints', kept!.id, { tools: stricter(keptRule.tools, rule.tools), ...(execution ? { execution } : {}),
            ...(deny.length ? { mcp: { deny } } : {}) });
          this.data.remove('constraints', project.id);
        }
        // 并入的项目的布局挂到保留的项目下，同 ID 的留保留项目那份
        for (const layout of this.layouts(project.id)) {
          const { id, revision: _, ...body } = layout;
          if (!this.data.get('layout', layoutKey(kept!.id, id))) this.data.put('layout', layoutKey(kept!.id, id), body as unknown as Record<string, unknown>);
          this.data.remove('layout', layoutKey(project.id, id));
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
