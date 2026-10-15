/**
 * 工作机目录：从组网的节点列表里找同一用户的设备，读各自的 /machine 确认是工作机；各工作机把自己的目录摘要写进账号级数据，
 * 随同步传给其他工作机。App 连上任意一台在线的工作机，就能看到其他工作机最近一次的摘要，见 docs/分布式架构.md「组网与发现」。
 */
import type { Machine, WorkspaceStatus } from '../model.ts';
import type { Peer } from '../peer-fetch.ts';
import type { CatalogSnapshot } from './catalog.ts';
import type { AccountData } from './store.ts';

/** 一台工作机；address 是组网上的访问地址，入网后才有。 */
export interface AccountMachine {
  id: string;
  name: string;
  online: boolean;
  address?: string;
}

/** 给 App 的目录：附最近一次的摘要与写入时刻。 */
export interface DirectoryEntry extends AccountMachine {
  updatedAt?: number;
  snapshot?: CatalogSnapshot;
}

/** 组网里的一台对端设备：address 是假定它跑着 kited 时的访问地址。 */
export interface Candidate { address: string; online: boolean }

interface Probe { machine?: { id: string; name: string }; at: number }
type Catalog = CatalogSnapshot & { address?: string };

/** 确认是工作机的，在线时每分钟再读一次；不是的（例如手机、平板）十分钟后再试。 */
const KITED_RECHECK_MS = 60_000;
const OTHER_RECHECK_MS = 10 * 60_000;
/** 这么久没读到 /machine 就算离线。 */
const ONLINE_MS = 3 * 60_000;
const REFRESH_MS = 20_000;
const PUBLISH_DELAY_MS = 1_000;

export class Directory {
  private probes = new Map<string, Probe>();
  private probing = new Map<string, Promise<Probe>>();
  private timer?: Timer;
  private publishing?: Timer;
  private closed = false;
  /** 各工作机的目录摘要，解析一次后缓存，账号级数据里的摘要变了才重读。 */
  private catalogs?: Map<string, { catalog: Catalog; at: number }>;
  private unsubscribe: () => void;

  constructor(private deps: {
    data: AccountData;
    self(): Machine;
    /** 本机在组网上的访问地址；组网没开时没有。 */
    address(): string | undefined;
    /** 本机此刻的目录摘要。 */
    snapshot(): CatalogSnapshot;
    /** 组网里同一用户的对端设备；组网没开时为 undefined。 */
    candidates(): Candidate[] | undefined;
    /** 访问对端 kited；组网上要经 kite-net 的本机代理。 */
    fetch(address: string, path: string, init?: RequestInit): Promise<Response>;
    /** 发现新的工作机或在线状态变化时调用。 */
    changed(): void;
    /** 本机目录变化后合并多久再写摘要（毫秒），默认 1 秒；测试里缩短。 */
    publishDelayMs?: number;
  }) {
    this.unsubscribe = deps.data.subscribe((changed) => { if (changed.some((entry) => entry.kind === 'catalog')) this.catalogs = undefined; });
  }

  start(): void {
    this.publish();
    void this.refresh();
    this.timer = setInterval(() => void this.refresh(), REFRESH_MS);
    this.timer.unref();
  }

  close(): void {
    this.closed = true;
    this.unsubscribe();
    clearInterval(this.timer);
    clearTimeout(this.publishing);
  }

  /** 本机的项目、检出或工作区变了：稍等合并几次变化，再写进账号级数据。 */
  schedule(): void {
    if (this.closed || this.publishing) return;
    this.publishing = setTimeout(() => { this.publishing = undefined; this.publish(); }, this.deps.publishDelayMs ?? PUBLISH_DELAY_MS);
    this.publishing.unref();
  }

  /** 全部工作机，本机在最前；从组网移除了的不再列出。 */
  list(): AccountMachine[] {
    return this.entries().map(({ snapshot: _, updatedAt: __, ...machine }) => machine);
  }

  entries(): DirectoryEntry[] {
    const self = this.deps.self();
    const candidates = this.deps.candidates();
    const present = candidates && new Map(candidates.map((candidate) => [candidate.address, candidate.online]));
    const address = this.deps.address();
    const byId = new Map<string, DirectoryEntry>();
    this.catalogs ??= new Map(this.deps.data.list('catalog').map(({ id, body, at }) => [id, { catalog: body as unknown as Catalog, at }]));
    for (const [id, { catalog, at }] of this.catalogs) {
      byId.set(id, { id, name: catalog.machine.name, online: false, ...(catalog.address ? { address: catalog.address } : {}),
        updatedAt: at, snapshot: { machine: catalog.machine, projects: catalog.projects, checkouts: catalog.checkouts, workspaces: catalog.workspaces } });
    }
    for (const [probed, { machine, at }] of this.probes) {
      if (!machine) continue;
      const entry = byId.get(machine.id) ?? { id: machine.id, name: machine.name, online: false };
      entry.address = probed;
      entry.online = Date.now() - at < ONLINE_MS && present?.get(probed) === true;
      byId.set(machine.id, entry);
    }
    const others = [...byId.values()].filter((entry) => entry.id !== self.id && (!present || !entry.address || present.has(entry.address)));
    const own = byId.get(self.id);
    return [{ ...own, id: self.id, name: self.name, online: true, ...(address ? { address } : {}) },
      ...others.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id))];
  }

  /** 在线的其他工作机。 */
  online(): Peer[] {
    const self = this.deps.self().id;
    return this.entries().filter((entry) => entry.id !== self && entry.online && entry.address).map((entry) => ({ id: entry.id, address: entry.address! }));
  }

  /** 目录摘要里有这个项目检出的工作机。 */
  holders(projectId: string): Set<string> {
    return new Set(this.entries().filter((entry) => entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)).map((entry) => entry.id));
  }

  /** 其他工作机的目录摘要里这个工作区的记录。 */
  copies(workspaceId: string): Array<{ machine: string; epoch: number; status: WorkspaceStatus }> {
    const self = this.deps.self().id;
    return this.entries().filter((entry) => entry.id !== self).flatMap((entry) => (entry.snapshot?.workspaces ?? [])
      .filter((w) => w.id === workspaceId).map((w) => ({ machine: entry.id, epoch: w.epoch, status: w.status })));
  }

  /** 组网来的请求是否出自一台工作机：按来源的组网 IP 找对端，没读过 /machine 就现在读。 */
  async verify(ip: string): Promise<boolean> {
    const candidate = this.deps.candidates()?.find((entry) => new URL(entry.address).hostname.replace(/^\[|\]$/g, '') === ip);
    if (!candidate) return false;
    const probe = this.probes.get(candidate.address);
    if (probe?.machine && Date.now() - probe.at < OTHER_RECHECK_MS) return true;
    return !!(await this.probe(candidate.address)).machine;
  }

  private publish(): void {
    if (this.closed) return;
    const address = this.deps.address();
    this.deps.data.put('catalog', this.deps.self().id, { ...this.deps.snapshot(), ...(address ? { address } : {}) });
  }

  /** 读一遍组网里的对端：没读过或该重读的读 /machine，目录有变化就通知。定时做，对端变了也可以立刻调用。 */
  async refresh(): Promise<void> {
    const candidates = this.deps.candidates() ?? [];
    // 本机组网地址变了要重新写摘要，其他工作机靠它找到这里。
    const own = this.deps.data.get('catalog', this.deps.self().id)?.body as Catalog | undefined;
    if (own?.address !== this.deps.address()) this.publish();
    const before = JSON.stringify(this.list());
    await Promise.all(candidates.filter((candidate) => {
      if (!candidate.online) return false;
      const probe = this.probes.get(candidate.address);
      return !probe || Date.now() - probe.at > (probe.machine ? KITED_RECHECK_MS : OTHER_RECHECK_MS);
    }).map((candidate) => this.probe(candidate.address)));
    if (!this.closed && JSON.stringify(this.list()) !== before) this.deps.changed();
  }

  private probe(address: string): Promise<Probe> {
    let pending = this.probing.get(address);
    if (!pending) {
      pending = (async () => {
        let machine: Probe['machine'];
        try {
          const response = await this.deps.fetch(address, '/machine', { signal: AbortSignal.timeout(10_000) });
          const body = response.ok ? await response.json() as { id?: unknown; name?: unknown } : {};
          if (typeof body.id === 'string' && typeof body.name === 'string') machine = { id: body.id, name: body.name };
        } catch { /* 连不上或不是 kited。 */ }
        const probe = { ...(machine ? { machine } : {}), at: Date.now() };
        this.probes.set(address, probe);
        return probe;
      })().finally(() => this.probing.delete(address));
      this.probing.set(address, pending);
    }
    return pending;
  }
}
