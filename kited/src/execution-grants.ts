/** 实例持久授权只描述用户可调整的范围；系统工具链和宿主保护由执行器补齐。 */
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { BlockList, isIP } from 'node:net';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import type { PluginInstance } from './model.ts';
import { pluginDefinitions } from './plugins.ts';
import { within } from './paths.ts';
import { canonicalPath, type ExecutionPolicy } from './sandbox.ts';

const path = z.string().refine((value) => isAbsolute(value) && !/[*?\[\]{}\0\n\r]/.test(value), '须使用无通配符的绝对路径');
const loopback = new BlockList();
loopback.addSubnet('127.0.0.0', 8, 'ipv4');
loopback.addSubnet('0.0.0.0', 8, 'ipv4');
loopback.addAddress('::1', 'ipv6');
loopback.addAddress('::', 'ipv6');
function permitsLoopback(domain: string): boolean {
  const host = domain.startsWith('[') ? domain.slice(1, domain.indexOf(']')) : domain.split(':')[0]!;
  if (host === 'localhost' || host.endsWith('.localhost')) return true;
  // URL 规范化数字形式的 IPv4（例如 2130706433），防止通过另一种拼写绕过回环检查。
  let normalized = host;
  try { normalized = new URL(`http://${domain}`).hostname.replace(/^\[|\]$/g, ''); } catch { /* 通配域名仍交给上游校验。 */ }
  const family = isIP(normalized);
  return family !== 0 && loopback.check(normalized, family === 4 ? 'ipv4' : 'ipv6');
}
export const executionGrantsSchema = z.object({
  workspace: z.enum(['read', 'write']),
  read: z.array(path), write: z.array(path),
  network: z.array(z.string().min(1))
    .refine((domains) => !domains.some((domain) => permitsLoopback(domain.toLowerCase())), '本机 HTTP 尚未鉴权，执行授权暂不开放回环地址'),
}).strict();
export type ExecutionGrants = z.infer<typeof executionGrantsSchema>;

export function parseExecutionGrants(value: unknown): ExecutionGrants {
  const parsed = executionGrantsSchema.safeParse(value);
  if (!parsed.success) throw new KiteError(`执行授权无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
  return parsed.data;
}

/** 授权时绑定真实位置；以后重定向符号链接不能把原许可变成新目录的许可。 */
export async function normalizeExecutionGrants(value: unknown): Promise<ExecutionGrants> {
  const grants = parseExecutionGrants(value);
  // 仅管理入口新增网络许可时加载上游校验，历史解析和每次工具调用不加载整个沙箱运行时。
  if (grants.network.length) {
    const { NetworkConfigSchema } = await import('@anthropic-ai/sandbox-runtime');
    if (!NetworkConfigSchema.safeParse({ allowedDomains: grants.network, deniedDomains: [] }).success) {
      throw new KiteError('网络许可须使用有效域名或 IP，可带端口；不支持 URL 或全网通配符');
    }
  }
  const unique = (values: string[]) => [...new Set(values)].sort();
  try {
    return parseExecutionGrants({ ...grants,
      read: unique(grants.read.map((path) => realpathSync(path))), write: unique(grants.write.map((path) => realpathSync(path))),
      network: unique(grants.network.map((domain) => domain.toLowerCase())),
    });
  } catch (error) {
    if (error instanceof KiteError) throw error;
    throw new KiteError('授权目录或文件必须存在且可解析');
  }
}

export function instanceExecutionGrants(instance: PluginInstance): ExecutionGrants {
  return parseExecutionGrants(instance.config.execution ?? pluginDefinitions().find((definition) => definition.id === instance.definitionId)?.execution
    ?? { workspace: 'read', read: [], write: [], network: [] });
}
export const executionRevision = (grants: ExecutionGrants): string => createHash('sha256').update(JSON.stringify(grants)).digest('hex');

export function applyExecutionGrants(base: ExecutionPolicy, cwd: string, grants: ExecutionGrants): ExecutionPolicy {
  const root = realpathSync(cwd);
  for (const path of [...grants.read, ...grants.write]) {
    try { if (realpathSync(path) === path) continue; } catch { /* 失效许可拒绝执行，不跟随新的目标。 */ }
    throw new KiteError(`授权路径已消失或改变位置，请重新授权：${path}`, 409);
  }
  const read = [...new Set([...base.read, ...grants.read, ...grants.write])];
  const write = [...new Set([...(grants.workspace === 'write' ? [root] : []), ...grants.write])];
  // 拒绝与宿主保护范围重叠的额外许可；基础工作树中已有的受保护路径仍由 deny 规则覆盖。
  for (const [paths, denied] of [[grants.read, base.denyRead], [grants.write, [...(base.denyRead ?? []), ...(base.denyWrite ?? [])]]] as const) {
    if (paths.some((path) => denied?.some((blocked) => within(path, canonicalPath(blocked)) || within(canonicalPath(blocked), path)))) {
      throw new KiteError('额外目录许可不能覆盖宿主数据或 Git 元数据');
    }
  }
  return { ...base, read, write, network: [...grants.network] };
}
