/**
 * 浏览插件 kite.browser（docs/实例操作.md「浏览」）：一个实例是本工作区的一个端口，设备自己的网页视图经端口转发打开，工作机不参与。
 * 实例随窗口回收，只供界面，没有模型工具。端口须是本工作区运行中终端或预览此刻监听的，新建、选端口时核对；服务停了实例保留，同一端口再被监听时接着显示。
 * 路径、滚动与登录状态只在各自的设备上。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';

export const browserDefinitionId = 'kite.browser';

const portSchema = z.number().int().min(1).max(65535);
/** 新建浏览带的参数（窗口请求里的 browser）：可带端口。 */
export const browserSpecSchema = z.object({ port: portSchema.optional() }).strict();
export type BrowserSpec = z.infer<typeof browserSpecSchema>;
const stateSchema = z.object({ port: portSchema.optional() }).strict();
export const browserState = (instance: Pick<PluginInstance, 'state'>) => stateSchema.parse(instance.state.browser ?? {});

export interface BrowsingHost {
  store: Store;
  changed(workspaceId: string): void;
  /** 本工作区运行中终端与预览此刻监听的端口。 */
  ports(workspaceId: string): number[];
}

export class Browsing {
  constructor(private host: BrowsingHost) {}

  private checkPort(workspaceId: string, port: number): void {
    if (!this.host.ports(workspaceId).includes(port)) throw new KiteError(`localhost:${port} 不是这个工作区里运行中的终端或预览在监听的端口`, 409);
  }

  /** 新建浏览的状态；带的端口须正在被本工作区监听。 */
  initial(workspaceId: string, spec: BrowserSpec): Pick<PluginInstance, 'state'> {
    if (spec.port !== undefined) this.checkPort(workspaceId, spec.port);
    return { state: { browser: spec.port !== undefined ? { port: spec.port } : {} } };
  }

  /** 改看的端口，各设备共用；null 是不选。 */
  select(id: string, port: number | null): { port?: number } {
    const instance = this.host.store.instance(id);
    if (!instance || instance.definitionId !== browserDefinitionId) throw new KiteError('没有这个浏览窗口', 404);
    if (port !== null) this.checkPort(instance.workspaceId, port);
    const next = port !== null ? { port } : {};
    this.host.store.setInstanceState(id, { ...instance.state, browser: next });
    this.host.changed(instance.workspaceId);
    return next;
  }
}
