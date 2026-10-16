/**
 * 执行授权按项目、角色、实例三层合成（docs/Agent与插件契约.md §3.2）：项目给基础许可与硬边界，角色与实例在项目之上增减，
 * 角色的增减在新建代理时拷进实例。实际生效 =（项目允许 + 实例增减）− 项目禁止，每次请求和工具调用前按项目此刻的约束算。
 * 系统工具链和宿主保护由执行器补齐。
 */
import { createHash } from 'node:crypto';
import { existsSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { PluginInstance } from '../model.ts';
import { within } from '../paths.ts';
import { localEndpoint } from './local-address.ts';
import { canonicalPath, type ExecutionPolicy } from './sandbox.ts';

const LOCAL_REJECTED = '本机控制接口尚未鉴权，执行授权不开放回环、链路本地与本机地址';
const clean = (value: string) => !/[*?\[\]{}\0\n\r]/.test(value);
/** 实际生效的授权里只有本机的绝对路径。 */
const path = z.string().refine((value) => isAbsolute(value) && clean(value), '须使用无通配符的绝对路径');
/** 三层里写的路径：绝对路径，或 ~/ 开头、由各工作机按自己的主目录解析。 */
const layerPath = z.string().refine((value) => (isAbsolute(value) || value.startsWith('~/')) && clean(value), '须使用 ~/ 开头或无通配符的绝对路径');
// 读取已保存的授权时只判固定网段：本机网卡的地址会变，不能让存下的授权因此失效；写入时另查本机此刻的地址。
const host = z.string().min(1).refine((domain) => !localEndpoint(domain, false), LOCAL_REJECTED);
/** 沙箱外命令的模式：`docker compose *` 以 ` *` 结尾表示带任意参数，否则须一字不差。 */
const pattern = z.string().trim().min(1).max(1000).refine((value) => !/[\0\n\r]/.test(value), '沙箱外命令须写在一行里');

const scopeSchema = z.object({
  read: z.array(layerPath).default([]), write: z.array(layerPath).default([]),
  network: z.array(host).default([]), unsandboxed: z.array(pattern).default([]),
}).strict();
export type ExecutionScope = z.infer<typeof scopeSchema>;
const emptyScope = (): ExecutionScope => ({ read: [], write: [], network: [], unsandboxed: [] });
const scopeKeys = ['read', 'write', 'network', 'unsandboxed'] as const;

/** 角色与实例：在项目基础上的增减。workspace 省略时可写。 */
export const executionChangesSchema = z.object({
  workspace: z.enum(['read', 'write']).optional(),
  add: scopeSchema.default(emptyScope), remove: scopeSchema.default(emptyScope),
}).strict();
export type ExecutionChanges = z.infer<typeof executionChangesSchema>;

/**
 * 审批模式：越出执行授权的请求怎么处理（docs/工具审批与提问.md）。allowlist 直接拒绝，ask 停下来问人，allow_all 自动允许。
 * 管命令连接授权之外的主机，和申请在沙箱外运行的命令。按严到宽排。
 */
export const approvalModes = ['allowlist', 'ask', 'allow_all'] as const;
export type ApprovalMode = (typeof approvalModes)[number];

/** 项目：基础许可与硬边界。workspace 为 read 时本项目一律只读；approval 是审批模式的上限。 */
export const projectExecutionSchema = z.object({
  workspace: z.enum(['read', 'write']).default('write'),
  allow: scopeSchema.default(emptyScope), deny: scopeSchema.default(emptyScope),
  approval: z.enum(approvalModes).default('allow_all'),
}).strict();
export type ProjectExecution = z.infer<typeof projectExecutionSchema>;
export const defaultProjectExecution = (): ProjectExecution => projectExecutionSchema.parse({});

/** 实际生效的执行授权：沙箱策略、通知与上下文变量都用它。 */
export const executionGrantsSchema = z.object({
  workspace: z.enum(['read', 'write']),
  read: z.array(path), write: z.array(path), network: z.array(host),
  unsandboxed: z.array(pattern).default([]),
}).strict();
export type ExecutionGrants = z.infer<typeof executionGrantsSchema>;

/** 合成结果：生效的许可，项目的禁止（交给沙箱与沙箱外命令的判断），以及来自 ~/ 的路径（与宿主保护重叠时略过而不报错）。 */
export interface EffectiveExecution {
  grants: ExecutionGrants;
  denied: { read: string[]; write: string[]; network: string[]; unsandboxed: string[] };
  lenient: Set<string>;
}

const issues = (error: z.ZodError) => error.issues.map((issue) => issue.message).join('；');

/** 旧格式是整份授权（workspace、read、write、network），读成在空项目上的添加。 */
export function parseExecutionChanges(value: unknown): ExecutionChanges {
  let raw = value ?? {};
  if (typeof raw === 'object' && raw !== null && !('add' in raw) && ('read' in raw || 'network' in raw)) {
    const { workspace, read, write, network } = raw as Record<string, unknown>;
    raw = { ...(workspace === undefined ? {} : { workspace }), add: { read, write, network } };
  }
  const parsed = executionChangesSchema.safeParse(raw);
  if (!parsed.success) throw new KiteError(`执行授权无效：${issues(parsed.error)}`);
  return parsed.data;
}

export const instanceExecutionChanges = (instance: Pick<PluginInstance, 'config'>): ExecutionChanges => parseExecutionChanges(instance.config.execution);
export const instanceApprovalMode = (instance: Pick<PluginInstance, 'config'>): ApprovalMode =>
  z.enum(approvalModes).default('allowlist').parse(instance.config.approval);
/** 实例的选择与项目上限取较严的。 */
export const effectiveApprovalMode = (mode: ApprovalMode, project: ProjectExecution | undefined): ApprovalMode =>
  approvalModes[Math.min(approvalModes.indexOf(mode), approvalModes.indexOf(project?.approval ?? 'allow_all'))]!;

/**
 * 写进实例的增减：网络不收本机地址并按上游规则校验；绝对路径须存在，绑定真实位置，以后重定向符号链接不能把原许可变成新目录的许可；
 * ~/ 开头的保留原样，按各工作机解析。
 */
export async function normalizeExecutionChanges(value: unknown): Promise<ExecutionChanges> {
  const changes = parseExecutionChanges(value);
  const domains = [...changes.add.network, ...changes.remove.network];
  if (domains.some((domain) => localEndpoint(domain))) throw new KiteError(`执行授权无效：${LOCAL_REJECTED}`);
  // 仅管理入口新增网络许可时加载上游校验，历史解析和每次工具调用不加载整个沙箱运行时。
  if (domains.length) {
    const { NetworkConfigSchema } = await import('@anthropic-ai/sandbox-runtime');
    if (!NetworkConfigSchema.safeParse({ allowedDomains: domains, deniedDomains: [] }).success) {
      throw new KiteError('网络许可须使用有效域名或 IP，可带端口；不支持 URL 或全网通配符');
    }
  }
  const unique = (values: string[]) => [...new Set(values)].sort();
  const real = (value: string) => value.startsWith('~/') ? value : realpathSync(value);
  const scope = (from: ExecutionScope): ExecutionScope => ({ read: unique(from.read.map(real)), write: unique(from.write.map(real)),
    network: unique(from.network.map((domain) => domain.toLowerCase())), unsandboxed: unique(from.unsandboxed.map((item) => item.trim())) });
  try {
    return executionChangesSchema.parse({ ...(changes.workspace ? { workspace: changes.workspace } : {}), add: scope(changes.add), remove: scope(changes.remove) });
  } catch (error) {
    if (error instanceof KiteError) throw error;
    throw new KiteError('授权目录或文件必须存在且可解析');
  }
}

/** 项目约束里的执行授权：只做格式与本机地址校验，路径按各工作机解析，不要求在这台机器上存在。 */
export function parseProjectExecution(value: unknown): ProjectExecution {
  const parsed = projectExecutionSchema.safeParse(value ?? {});
  if (!parsed.success) throw new KiteError(`项目的执行授权无效：${issues(parsed.error)}`);
  return parsed.data;
}

/** 两份项目执行授权里更严的组合：允许取交集，禁止取并集，只读与较低的审批上限优先。 */
export function stricterExecution(a: ProjectExecution, b: ProjectExecution): ProjectExecution {
  const both = (key: (typeof scopeKeys)[number]) => a.allow[key].filter((value) => b.allow[key].includes(value));
  const either = (key: (typeof scopeKeys)[number]) => [...new Set([...a.deny[key], ...b.deny[key]])].sort();
  return { workspace: a.workspace === 'read' || b.workspace === 'read' ? 'read' : 'write',
    allow: { read: both('read'), write: both('write'), network: both('network'), unsandboxed: both('unsandboxed') },
    deny: { read: either('read'), write: either('write'), network: either('network'), unsandboxed: either('unsandboxed') },
    approval: effectiveApprovalMode(a.approval, b) };
}

const hostMatches = (rule: string, domain: string) => {
  const name = (value: string) => value.toLowerCase().replace(/:\d+$/, '');
  const [r, d] = [name(rule), name(domain)];
  return r === d || (r.startsWith('*.') && (d.endsWith(r.slice(1)) || d === r.slice(2)));
};

/** 三层合成实际生效的执行授权；project 为空时按没有约束的项目算。 */
export function effectiveExecution(changes: ExecutionChanges, project: ProjectExecution | undefined, home = homedir()): EffectiveExecution {
  const base = project ?? defaultProjectExecution();
  const lenient = new Set<string>();
  // ~/ 开头的按本机主目录解析成真实位置，本机没有就略过；绝对路径保持原样，失效由执行器拒绝。
  const local = (value: string): string | undefined => {
    if (!value.startsWith('~/')) return value;
    const target = join(home, value.slice(2));
    if (!existsSync(target)) return undefined;
    const real = realpathSync(target);
    lenient.add(real);
    return real;
  };
  const expand = (value: string) => value.startsWith('~/') ? join(home, value.slice(2)) : value;
  // 禁止的路径按真实位置交给沙箱，本机不存在的也照样禁（以后建出来也打不开）。
  const denied = { read: base.deny.read.map((value) => canonicalPath(expand(value))), write: base.deny.write.map((value) => canonicalPath(expand(value))),
    network: [...base.deny.network], unsandboxed: [...base.deny.unsandboxed] };
  const blockedPath = (value: string, keys: ('read' | 'write')[]) =>
    keys.some((key) => denied[key].some((root) => within(value, canonicalPath(root))));
  const pick = (key: (typeof scopeKeys)[number]) => {
    const removed = new Set(changes.remove[key].map(expand));
    return [...new Set([...base.allow[key], ...changes.add[key]])].filter((value) => !removed.has(expand(value)));
  };
  const paths = (key: 'read' | 'write', keys: ('read' | 'write')[]) => [...new Set(pick(key).flatMap((value) => local(value) ?? []))]
    .filter((value) => !blockedPath(value, keys)).sort();
  const grants = executionGrantsSchema.parse({
    workspace: base.workspace === 'read' ? 'read' : changes.workspace ?? 'write',
    read: paths('read', ['read']),
    write: paths('write', ['read', 'write']),
    network: pick('network').filter((domain) => !denied.network.some((rule) => hostMatches(rule, domain))).sort(),
    unsandboxed: pick('unsandboxed').sort(),
  });
  return { grants, denied, lenient };
}

export const executionRevision = (value: unknown): string => createHash('sha256').update(JSON.stringify(value)).digest('hex');

/** 沙箱策略：基础策略加上生效的许可，项目禁止的路径与主机交给沙箱。 */
export function applyExecutionGrants(base: ExecutionPolicy, cwd: string, { grants, denied, lenient }: EffectiveExecution): ExecutionPolicy {
  const root = realpathSync(cwd);
  for (const path of [...grants.read, ...grants.write]) {
    try { if (realpathSync(path) === path) continue; } catch { /* 失效许可拒绝执行，不跟随新的目标。 */ }
    throw new KiteError(`授权路径已消失或改变位置，请重新授权：${path}`, 409);
  }
  // 与宿主保护范围重叠的额外许可：实例里写的拒绝执行，项目和角色里 ~/ 开头的略过（各工作机的主目录布局不同）。
  const overlapping = (path: string, blocked: string[] | undefined) =>
    blocked?.some((root) => within(path, canonicalPath(root)) || within(canonicalPath(root), path));
  const keep = (paths: string[], blocked: string[] | undefined) => paths.filter((path) => {
    if (!overlapping(path, blocked)) return true;
    if (lenient.has(path)) return false;
    throw new KiteError('额外目录许可不能覆盖宿主数据或 Git 元数据');
  });
  const read = keep(grants.read, base.denyRead);
  const write = keep(grants.write, [...(base.denyRead ?? []), ...(base.denyWrite ?? [])]);
  return { ...base,
    read: [...new Set([...base.read, ...read, ...write])],
    write: [...new Set([...(grants.workspace === 'write' ? [root] : []), ...write])],
    network: [...grants.network],
    denyRead: [...base.denyRead ?? [], ...denied.read],
    denyWrite: [...base.denyWrite ?? [], ...denied.read, ...denied.write],
    deniedNetwork: [...denied.network],
  };
}

/** 一段命令和一条模式：` *` 结尾的匹配这个前缀本身或带任意参数，否则须相同。 */
const segmentMatches = (segment: string, rule: string) => rule.endsWith(' *')
  ? segment === rule.slice(0, -2) || segment.startsWith(rule.slice(0, -1)) : segment === rule;

/**
 * 一条 shell 调用能不能在沙箱外运行：allowed 是在生效的沙箱外命令里，denied 是有一段命中项目禁止，unlisted 是都不在。
 * 整条原样登记过的直接算；否则含命令替换、反引号、重定向或换行的一律不算，用 &&、||、;、| 连起来的每一段都要匹配。
 */
export function unsandboxedVerdict(command: string, allowed: string[], denied: string[]): 'allowed' | 'denied' | 'unlisted' {
  const call = command.trim();
  const segments = call.split(/&&|\|\||;|\|/).map((segment) => segment.trim()).filter(Boolean);
  if (segments.some((segment) => denied.some((rule) => segmentMatches(segment, rule)))) return 'denied';
  if (allowed.includes(call)) return 'allowed';
  if (/\$\(|`|[<>]|[\n\r]/.test(call) || !segments.length) return 'unlisted';
  return segments.every((segment) => allowed.some((rule) => segmentMatches(segment, rule))) ? 'allowed' : 'unlisted';
}
