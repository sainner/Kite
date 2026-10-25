/**
 * 预览实例的配置与状态（docs/实例操作.md「预览」）。配置是跑哪个目标、装到哪台设备，建好不变；进程的状态同终端，在 state.terminal（见 terminal/state.ts）；
 * state.preview 是画面：种类由进程产生什么决定（screen、网页的主端口 port、App 窗口的 app），browser 是网页在哪看，各设备共用。
 */
import { z } from 'zod';
import type { PluginInstance } from '../model.ts';
import { deviceSchema } from './devices.ts';
import { portSchema } from '../workspace/files.ts';

export const previewDefinitionId = 'kite.preview';

/** 工作机上的浏览器。 */
export const workstationBrowsers = ['webkit', 'chromium', 'firefox', 'safari'] as const;
export type WorkstationBrowser = (typeof workstationBrowsers)[number];
/** 网页在哪看：device 是看的设备自己的网页视图，其余是工作机上的浏览器。 */
export const previewBrowsers = ['device', ...workstationBrowsers] as const;
export type PreviewBrowser = (typeof previewBrowsers)[number];

/** 画面的种类：进程树里开着窗口的 Mac App、目标用的模拟器、能用 HTTP 打开的端口，都没有是 none。 */
export const previewScreens = ['app', 'simulator', 'web', 'none'] as const;
export type PreviewScreen = (typeof previewScreens)[number];

const targetName = z.string().trim().min(1).max(255);
/** 新建预览带的参数（新建实例请求里的 preview 与 preview_open）：目标名与可选的设备。 */
export const previewSpecSchema = z.object({ target: targetName, device: deviceSchema.optional() }).strict();
export type PreviewSpec = z.infer<typeof previewSpecSchema>;
export const previewConfig = (instance: Pick<PluginInstance, 'config'>): PreviewSpec => previewSpecSchema.parse(instance.config.preview);

/** 网页视口的一边（CSS 像素）：设备窗口报的尺寸、并排的一格。 */
export const viewportEdge = z.number().int().min(200).max(4096);
export const stateSchema = z.object({
  screen: z.enum(previewScreens),
  /** 网页画面的主端口：分给目标的 PORT 能用 HTTP 打开时是它，否则是进程树里第一个能用 HTTP 打开的。 */
  port: portSchema.optional(),
  /** App 窗口画面看的 App 的路径（.app 或可执行文件）。 */
  app: z.string().min(1).max(4096).optional(),
  /** 网页在工作机的哪个浏览器里看；没有时在看的设备自己的网页视图里看（device）。 */
  browser: z.enum(workstationBrowsers).optional(),
}).strict();
export type PreviewState = z.infer<typeof stateSchema>;
export const previewState = (instance: Pick<PluginInstance, 'state'>): PreviewState => stateSchema.parse(instance.state.preview ?? { screen: 'none' });
