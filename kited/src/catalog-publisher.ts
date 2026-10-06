import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { z } from 'zod';
import type { Kite } from './kite.ts';
import type { CatalogSnapshot } from './account/catalog.ts';
import type { AccountLink } from './account-client.ts';

export const publisherConfig = z.object({ url: z.url().startsWith('https://'), deviceId: z.uuid(), token: z.string().min(32) }).strict();
type Config = z.infer<typeof publisherConfig> & { revision: number };

/** 各机只发布自己的导航目录。单路写入与持久序号防止重启、重试覆盖较新的快照。 */
export class CatalogPublisher {
  private config?: Config;
  private pending?: Promise<void>;
  private abort?: AbortController;
  private dirty = false;
  private closed = false;
  private error?: string;
  private needsAuthorization = false;
  private timer: Timer;
  private unsubscribe: () => void;

  constructor(private file: string, private kite: Kite, private onLinked: () => void = () => {}) {
    if (existsSync(file)) this.config = JSON.parse(readFileSync(file, 'utf8'));
    this.unsubscribe = kite.bus.subscribe((event) => event.type === 'checkout.changed' || event.type === 'workspace.changed', () => this.schedule());
    // 在线状态由组网服务提供；目录空闲时不反复上传，只重试失败的发布。
    this.timer = setInterval(() => { if (this.error !== undefined) this.schedule(); }, 30_000);
    this.timer.unref();
    this.schedule();
  }

  status() { return { deviceId: this.config?.deviceId, error: this.error, needsAuthorization: this.needsAuthorization }; }

  /** 项目登记与凭据分发复用目录上报的工作机凭据。 */
  link(): AccountLink | undefined { return this.config && { url: this.config.url, token: this.config.token }; }

  async configure(config: z.infer<typeof publisherConfig>): Promise<void> {
    // 本机配置响应丢失后的重试不能把同一凭据的版本退回零。
    if (this.config?.deviceId !== config.deviceId || this.config.url !== config.url || this.config.token !== config.token) {
      this.abort?.abort();
      await this.pending;
      this.config = { ...config, revision: 0 };
      this.error = undefined;
      this.needsAuthorization = false;
      this.save();
    }
    this.schedule();
    this.onLinked();
  }

  private save() {
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    const temporary = this.file + '.tmp';
    writeFileSync(temporary, JSON.stringify(this.config), { mode: 0o600 });
    renameSync(temporary, this.file);
  }

  private schedule() {
    if (this.closed || !this.config) return;
    this.dirty = true;
    if (this.pending) return;
    this.pending = Promise.resolve().then(async () => {
      while (this.dirty && !this.closed && this.config) {
        this.dirty = false;
        const config = this.config;
        const snapshot: CatalogSnapshot = { machine: this.kite.machine(), projects: this.kite.projects(),
          checkouts: this.kite.checkouts(), workspaces: this.kite.store.workspaces() };
        config.revision++;
        this.save();
        this.abort = new AbortController();
        const response = await fetch(new URL(`/api/catalog/${config.deviceId}`, config.url), {
          method: 'PUT', headers: { authorization: `Bearer ${config.token}`, 'content-type': 'application/json' },
          body: JSON.stringify({ revision: config.revision, snapshot }),
          signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(10_000)]),
        });
        this.needsAuthorization = response.status === 401;
        if (!response.ok) throw new Error(`目录上报失败（${response.status}）`);
        this.error = undefined;
      }
    }).catch((error: unknown) => {
      if (!this.closed) this.error = error instanceof Error ? error.message : '目录上报失败';
    }).finally(() => {
      this.pending = undefined;
      this.abort = undefined;
      if (this.dirty && this.error === undefined) this.schedule();
    });
  }

  async stop() {
    this.closed = true;
    clearInterval(this.timer);
    this.unsubscribe();
    this.abort?.abort();
    await this.pending;
  }
}
