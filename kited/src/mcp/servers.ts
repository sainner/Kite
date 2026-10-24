/**
 * 这台工作机装的外部 MCP 服务：清单存在 <home>/mcp/servers.json，就是这台机器的全集；谁能用由项目约束、角色、实例授权，
 * 见 docs/产品架构.md「两层协议与上下文」。每个服务一条连接，所有代理共用：按 2026-07-28 版协议连，连不上就由 SDK 退回旧版握手。
 * 服务是用户装在这台机器上的普通程序，不进 Kite 的沙箱。环境变量与请求头的值里可以写 {account.名字} 引用账号共享的密钥，
 * 令牌存在凭据层，清单里只有引用，连接时才取出明文交给服务。
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { Client, StreamableHTTPClientTransport, UnauthorizedError, type CallToolResult, type Tool as McpTool } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { commandEnvironment } from '../execution/sandbox.ts';
import type { Tool } from '../harness/types.ts';
import { userHome } from '../paths.ts';
import { serverNameSchema } from './names.ts';
import { kiteTools } from './tools.ts';

/** 值里的密钥引用；服务属于工作机、不属于某个项目，只认账号共享的。 */
const references = /\{account\.[a-zA-Z][a-zA-Z0-9_-]{0,63}\}/g;
const strings = z.record(z.string().min(1), z.string().refine((value) => !/\{project\.[^}]*\}/.test(value),
  'MCP 服务不属于某个项目，只能引用账号共享的密钥 {account.名字}'));
const description = z.string().trim().max(500).optional();
const serverConfigSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('stdio'), command: z.string().trim().min(1), args: z.array(z.string()).optional(), env: strings.optional(),
    cwd: z.string().min(1).optional(), description }).strict(),
  z.object({ type: z.literal('http'), url: z.url({ protocol: /^https?$/ }), headers: strings.optional(), description }).strict(),
]);
type ServerConfig = z.infer<typeof serverConfigSchema>;

/** 通行的 mcpServers 写法里本机程序可以不写 type；SSE 传输在新规范里已弃用，不接。 */
function normalize(raw: unknown): unknown {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return raw;
  const value = raw as Record<string, unknown>;
  if (value.type === 'sse') throw new KiteError('SSE 传输已弃用，请改用服务的 Streamable HTTP 地址');
  if (value.type === 'streamable-http') return { ...value, type: 'http' };
  if (value.type === undefined) return { ...value, type: 'command' in value ? 'stdio' : 'http' };
  return value;
}
function parseServerConfig(raw: unknown): ServerConfig {
  const parsed = serverConfigSchema.safeParse(normalize(raw));
  if (!parsed.success) throw new KiteError(`MCP 服务配置无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
  return parsed.data;
}
export function parseServerName(raw: unknown): string {
  const parsed = serverNameSchema.safeParse(raw);
  if (!parsed.success) throw new KiteError(parsed.error.issues[0]!.message);
  return parsed.data;
}
/** 清单文件与粘贴的配置同形：{mcpServers: {名字: 配置}}。 */
function parseServers(raw: unknown): Record<string, ServerConfig> {
  const parsed = z.object({ mcpServers: z.record(z.string(), z.unknown()) }).safeParse(raw);
  if (!parsed.success) throw new KiteError('要写含 mcpServers 的配置');
  return Object.fromEntries(Object.entries(parsed.data.mcpServers).map(([key, value]) => [parseServerName(key), parseServerConfig(value)]));
}

export type ServerPhase = 'idle' | 'connecting' | 'connected' | 'failed' | 'unauthorized';
export interface ServerEntry {
  name: string;
  config: ServerConfig;
  status: { phase: ServerPhase; message?: string; tools?: number; protocol?: string; server?: { name: string; version: string } };
}

/** 状态由字段推出：opening 是正在连，client 是连着，failure 是上次没连上。 */
interface Connection {
  client?: Client;
  opening?: Promise<void>;
  /** 最近一次取到的目录包成的 Kite 工具；断开后保留，模型的工具声明不随通断变化，调用时再连。 */
  tools: Tool[];
  failure?: { message: string; unauthorized: boolean; at: number };
}

/** 连接失败后，按需连接至少隔这么久再试；要登录的不自动重试，改配置或手动重连才再连。 */
const RETRY_AFTER = 30_000;
/** 首次连接可能要下载包（npx、uvx），给足时间。 */
const CONNECT_TIMEOUT = 60_000;
/** 外部工具可能跑很久（构建、浏览器操作）：有进度就续期，停止由 signal 负责。 */
const CALL_TIMEOUT = 30 * 60_000;

export class McpServers {
  private connections = new Map<string, Connection>();
  private configs: Record<string, ServerConfig> = {};
  private sorted: string[] = [];
  /** 清单读不了（手改坏了）时的原因：这时一个服务都不给，也不写，免得盖掉用户的文件。 */
  invalid?: string;
  private closed = false;

  /**
   * changed：catalog 为真是清单变了（名字、说明），否则只是连接状态或工具目录变了；App 与代理据此刷新。
   * secrets：按引用取账号共享密钥的明文，没给时写了引用的服务连不上。
   */
  constructor(private home: string, private changed: (catalog: boolean) => void = () => {},
    private secrets?: (references: string[]) => Promise<Array<{ reference: string; value: string }>>) {
    try { this.adopt(existsSync(this.file) ? parseServers(JSON.parse(readFileSync(this.file, 'utf8'))) : {}); }
    catch (error) { this.invalid = `${this.file} 读不了：${(error as Error).message}。修好或删掉后重启 kited`; }
  }

  private get file() { return join(this.home, 'mcp', 'servers.json'); }
  private adopt(configs: Record<string, ServerConfig>): void {
    this.configs = configs;
    this.sorted = Object.keys(configs).sort();
  }
  /** 写入清单，断开改到的服务（下次用到时按新配置连）。环境变量与请求头里常有令牌：只给本人读写，目录也在宿主保护路径里。 */
  private async replace(configs: Record<string, ServerConfig>, touched: string[]): Promise<void> {
    if (this.invalid) throw new KiteError(this.invalid, 409);
    mkdirSync(join(this.home, 'mcp'), { recursive: true, mode: 0o700 });
    const temporary = `${this.file}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify({ mcpServers: configs }, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, this.file);
    this.adopt(configs);
    await Promise.all(touched.map((server) => this.disconnect(server)));
    this.changed(true);
  }

  names(): string[] { return this.sorted; }
  description(server: string): string | undefined { return this.configs[server]?.description; }
  /** 生效的服务：实例打开的里面，这台工作机装了、项目约束没禁的；顺序按服务名。服务之间没有依赖，不走内置工具的筛选。 */
  effective(enabled: readonly string[], deny: readonly string[] = []): string[] {
    return this.sorted.filter((server) => enabled.includes(server) && !deny.includes(server));
  }

  list(): ServerEntry[] {
    return this.sorted.map((server) => this.entry(server));
  }
  private entry(server: string): ServerEntry {
    const connection = this.connections.get(server);
    const client = connection?.client;
    const failure = connection?.failure;
    const phase: ServerPhase = connection?.opening ? 'connecting' : client ? 'connected' : failure ? (failure.unauthorized ? 'unauthorized' : 'failed') : 'idle';
    const info = client?.getServerVersion();
    return { name: server, config: this.configs[server]!, status: { phase, message: failure?.message,
      tools: client ? connection!.tools.length : undefined, protocol: client?.getNegotiatedProtocolVersion(),
      server: info && { name: info.name, version: info.version } } };
  }

  async save(server: string, raw: unknown): Promise<ServerEntry> {
    const key = parseServerName(server);
    await this.replace({ ...this.configs, [key]: parseServerConfig(raw) }, [key]);
    return this.entry(key);
  }
  /** 粘贴的 mcpServers：逐个新增或替换，有一个不对就都不改。 */
  async import(raw: unknown): Promise<ServerEntry[]> {
    const added = parseServers(raw);
    if (!Object.keys(added).length) throw new KiteError('mcpServers 里没有服务');
    await this.replace({ ...this.configs, ...added }, Object.keys(added));
    return Object.keys(added).map((key) => this.entry(key));
  }
  async remove(server: string): Promise<void> {
    if (!this.configs[server]) throw new KiteError('没有这个 MCP 服务', 404);
    const { [server]: _removed, ...rest } = this.configs;
    await this.replace(rest, [server]);
  }
  /** 手动重连：断开后马上连，不等失败后的间隔。 */
  async reconnect(server: string): Promise<ServerEntry> {
    if (!this.configs[server]) throw new KiteError('没有这个 MCP 服务', 404);
    await this.disconnect(server);
    await this.connect(server).catch(() => {});
    return this.entry(server);
  }

  /** 现在该不该去连：没在连、没连着，上次失败已过间隔且不是要登录。 */
  private due(server: string): boolean {
    const connection = this.connections.get(server);
    if (!connection) return true;
    const { opening, client, failure } = connection;
    return !opening && !client && !(failure && (failure.unauthorized || Date.now() - failure.at < RETRY_AFTER));
  }

  /**
   * 这些服务最近一次取到的目录包成的工具；该连的在后台去连。还没连上过的这次没有工具，连上后下次请求就有。
   * 模型请求的准备是同步的，所以这里只读已取到的目录。
   */
  tools(servers: readonly string[]): Tool[] {
    return servers.flatMap((server) => {
      if (!this.configs[server]) return [];
      if (this.due(server)) void this.connect(server).catch(() => {});
      return this.connections.get(server)?.tools ?? [];
    });
  }
  /** 等这些服务连上（或失败），最多等 timeout；会话启动时调用，首个请求就能带上工具。 */
  async ensure(servers: readonly string[], timeout = 5000): Promise<void> {
    const pending = servers.flatMap((server) => {
      if (!this.configs[server]) return [];
      const opening = this.connections.get(server)?.opening ?? (this.due(server) ? this.connect(server) : undefined);
      return opening ? [opening.catch(() => {})] : [];
    });
    if (!pending.length) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([Promise.all(pending), new Promise((resolve) => { timer = setTimeout(resolve, timeout); })]);
    clearTimeout(timer);
  }

  /** 断开了就先连上再调用；连不上时报错，调用没发出去。 */
  async call(server: string, tool: McpTool, args: Record<string, unknown>, signal: AbortSignal): Promise<CallToolResult> {
    if (!this.configs[server]) throw new KiteError(`这台工作机没有 MCP 服务 ${server}`, 404);
    const current = this.connections.get(server);
    if (!current?.client && (current?.opening || this.due(server))) await this.connect(server).catch(() => {});
    const connection = this.connections.get(server);
    if (!connection?.client) throw new KiteError(`MCP 服务 ${server} 没有连上：${connection?.failure?.message ?? '正在连接'}`, 409);
    return await connection.client.callTool({ name: tool.name, arguments: args },
      { signal, timeout: CALL_TIMEOUT, resetTimeoutOnProgress: true, onprogress: () => {}, toolDefinition: tool }) as CallToolResult;
  }

  private connect(server: string): Promise<void> {
    if (this.closed) return Promise.reject(new KiteError('工作机正在退出', 409));
    const connection = this.connections.get(server) ?? { tools: [] };
    this.connections.set(server, connection);
    if (connection.opening) return connection.opening;
    if (connection.client) return Promise.resolve();
    const config = this.configs[server]!;
    const current = () => this.connections.get(server) === connection;
    let diagnostics = '';
    connection.failure = undefined;
    connection.opening = (async () => {
      let opened: Client | undefined;
      try {
        const values = await this.resolve({ ...config.type === 'stdio' ? config.env : config.headers });
        const client = opened = new Client({ name: 'Kite', version: '1' }, {
          capabilities: {}, versionNegotiation: { mode: 'auto' },
          listChanged: { tools: { onChanged: (error, tools) => {
            if (error || !tools || !current()) return;
            connection.tools = kiteTools(this, server, tools);
            this.changed(false);
          } } },
        });
        const transport = config.type === 'stdio'
          // 显式给环境：开发工具的基础设置加上服务自己的变量；工作目录默认用户主目录，不落在 kited 的运行目录里。
          ? new StdioClientTransport({ command: config.command, args: config.args ?? [], cwd: config.cwd ?? userHome(), stderr: 'pipe',
            env: { ...commandEnvironment(process.env) as Record<string, string>, ...values } })
          : new StreamableHTTPClientTransport(new URL(config.url), { requestInit: { headers: values } });
        if (transport instanceof StdioClientTransport) transport.stderr?.on('data', (part: Buffer) => { diagnostics = (diagnostics + part.toString()).slice(-2000); });
        client.onclose = () => {
          if (!current() || connection.client !== client) return;
          connection.client = undefined;
          connection.failure = { message: '连接断开', unauthorized: false, at: Date.now() };
          this.changed(false);
        };
        await client.connect(transport, { timeout: CONNECT_TIMEOUT });
        const { tools } = await client.listTools(undefined, { timeout: CONNECT_TIMEOUT });
        if (!current()) { await client.close(); return; }
        connection.client = client;
        connection.tools = kiteTools(this, server, tools);
      } catch (error) {
        await opened?.close().catch(() => {});
        if (!current()) return;
        const unauthorized = error instanceof UnauthorizedError;
        connection.failure = { unauthorized, at: Date.now(),
          message: unauthorized ? '服务要求登录：在请求头里引用存着令牌的密钥，例如 Authorization: Bearer {account.名字}' : `${(error as Error).message}${diagnostics ? `\n${diagnostics.trim()}` : ''}` };
        throw error;
      } finally {
        connection.opening = undefined;
        this.changed(false);
      }
    })();
    this.changed(false);
    return connection.opening;
  }

  /** 把值里的 {account.名字} 换成密钥的明文；找不到的密钥让这次连接失败。 */
  private async resolve(values: Record<string, string>): Promise<Record<string, string>> {
    const found = [...new Set(Object.values(values).flatMap((value) => value.match(references) ?? []))];
    if (!found.length) return values;
    if (!this.secrets) throw new KiteError('这里取不到账号共享的密钥', 409);
    const secrets = new Map((await this.secrets(found)).map(({ reference, value }) => [reference, value]));
    return Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value.replace(references, (reference) => secrets.get(reference)!)]));
  }

  private async disconnect(server: string): Promise<void> {
    const connection = this.connections.get(server);
    this.connections.delete(server);
    await connection?.opening?.catch(() => {});
    await connection?.client?.close().catch(() => {});
  }

  async close(): Promise<void> {
    this.closed = true;
    await Promise.all([...this.connections.keys()].map((server) => this.disconnect(server)));
  }
}
