/** 预览实例的配置与状态（docs/实例操作.md「预览」）。配置是看哪一种，建好不变；状态是网页看哪个端口、在哪看，各设备共用。 */
import { z } from 'zod';
import type { PluginInstance } from '../model.ts';

export const previewDefinitionId = 'kite.preview';

/** 工作机上的浏览器；不用 WebKit，见 browsers.ts。 */
export const workstationBrowsers = ['chromium', 'firefox'] as const;
export type WorkstationBrowser = (typeof workstationBrowsers)[number];
/** 网页在哪看：device 是看的设备自己的网页视图，其余是工作机上的浏览器。 */
export const previewBrowsers = ['device', ...workstationBrowsers] as const;
export type PreviewBrowser = (typeof previewBrowsers)[number];

export const previewKinds = ['web', 'simulator'] as const;
export type PreviewKind = (typeof previewKinds)[number];

const configSchema = z.object({ kind: z.enum(previewKinds) }).strict();
export const previewConfig = (instance: Pick<PluginInstance, 'config'>) => configSchema.parse(instance.config.preview);

const portSchema = z.number().int().min(1).max(65535);
export const stateSchema = z.object({
  /** 网页的端口，须是本工作区运行中终端监听的；还没选时没有。 */
  port: portSchema.optional(),
  /** 网页在工作机的哪个浏览器里看；没有时在看的设备自己的网页视图里看（device）。 */
  browser: z.enum(workstationBrowsers).optional(),
}).strict();
export type PreviewState = z.infer<typeof stateSchema>;
export const previewState = (instance: Pick<PluginInstance, 'state'>): PreviewState => stateSchema.parse(instance.state.preview ?? {});

/** 新建预览带的参数（窗口请求里的 preview）：看网页还是模拟器，网页可带端口与在哪看。 */
export const previewSpecSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('web'), port: portSchema.optional(), browser: z.enum(previewBrowsers).optional() }).strict(),
  z.object({ kind: z.literal('simulator') }).strict(),
]);
export type PreviewSpec = z.infer<typeof previewSpecSchema>;
