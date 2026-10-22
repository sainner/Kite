/**
 * 预览的画面：工作机上的浏览器页面或模拟器屏幕。人和 agent 走同一个循环：截一帧、做一个动作、等画面稳定、再截一帧。
 * 坐标一律是画面的逻辑尺寸：网页是 CSS 像素，模拟器是点；给设备看的帧按设备像素截，给模型的按逻辑尺寸截，坐标都照逻辑尺寸。
 */
import { setTimeout as delay } from 'node:timers/promises';
import { z } from 'zod';

const keyNames: Record<string, string> = {
  return: 'Enter', enter: 'Enter', backspace: 'Backspace', delete: 'Delete', escape: 'Escape', esc: 'Escape', tab: 'Tab', space: 'Space',
  up: 'ArrowUp', down: 'ArrowDown', left: 'ArrowLeft', right: 'ArrowRight', page_up: 'PageUp', prior: 'PageUp', page_down: 'PageDown', next: 'PageDown',
  home: 'Home', end: 'End', ctrl: 'Control', control: 'Control', alt: 'Alt', option: 'Alt', shift: 'Shift', cmd: 'Meta', command: 'Meta', super: 'Meta', meta: 'Meta',
};
/** 模型给的按键名统一成 Playwright 的写法：xdotool 的 Return、ctrl+a 这类也认。 */
export const playwrightKey = (key: string) => key.split('+').map((part) => keyNames[part.toLowerCase()] ?? part).join('+');

const point = { x: z.number().min(0), y: z.number().min(0) };
export const actionSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('click'), ...point, button: z.enum(['left', 'right']).optional(), count: z.number().int().min(1).max(3).optional() }).strict(),
  z.object({ type: z.literal('drag'), from: z.object(point).strict(), to: z.object(point).strict() }).strict(),
  z.object({ type: z.literal('scroll'), ...point, dx: z.number(), dy: z.number() }).strict(),
  z.object({ type: z.literal('type'), text: z.string().min(1).max(10_000) }).strict(),
  /** 按键名照 Playwright（Enter、Control+A）；模型的写法在 preview_action 里已统一（playwrightKey）。 */
  z.object({ type: z.literal('key'), key: z.string().min(1).max(100) }).strict(),
  z.object({ type: z.literal('long_press'), ...point, duration: z.number().min(0.1).max(10).optional() }).strict(),
  z.object({ type: z.literal('pinch'), ...point, scale: z.number().min(0.1).max(10) }).strict(),
  /** 网页：在同一个页面里打开本端口上的路径。 */
  z.object({ type: z.literal('navigate'), path: z.string().max(4096) }).strict(),
  z.object({ type: z.literal('back') }).strict(),
  z.object({ type: z.literal('forward') }).strict(),
  z.object({ type: z.literal('reload') }).strict(),
  /** 模拟器的主屏幕键。 */
  z.object({ type: z.literal('home') }).strict(),
]);
export type PreviewAction = z.infer<typeof actionSchema>;

export interface Frame {
  /** JPEG。 */
  data: Uint8Array;
  /** 逻辑尺寸。 */
  width: number;
  height: number;
}

/** 网页的地址与标题；模拟器没有。 */
export interface ScreenInfo { url?: string; pageTitle?: string }

export interface Screen {
  /** forModel 时按逻辑尺寸截、质量高一点，给模型看；否则按设备像素截，给设备显示。 */
  capture(forModel?: boolean): Promise<Frame>;
  act(action: PreviewAction): Promise<void>;
  /** 界面结构的文字：网页是无障碍树，模拟器是控件、文字与位置。 */
  inspect(): Promise<string>;
  info(): Promise<ScreenInfo>;
  /** 网页的视口跟着最近操作的那台设备的窗口；模拟器屏幕尺寸固定，没有。 */
  resize?(width: number, height: number): Promise<void>;
  /** 换端口：在同一个页面里打开新端口的首页。 */
  retarget?(port: number): Promise<void>;
  /** 底下的浏览器或模拟器还在；断了的重开。 */
  alive(): boolean;
  close(): Promise<void>;
}

/**
 * 等画面稳定的节奏：连续 stableMs 不变算稳定，每 pollMs 截一帧比较；转圈、动画不会停，最多等 maxMs，到时给当时的画面。
 * 动作之后画面一直没变的要等满 quietMs：App 冷启动、页面跳转常要一秒多才出第一帧，按 stableMs 算会截到动作之前的样子（模拟器上点开设置实测约 1.2 秒）。
 */
export interface SettleTiming { stableMs: number; pollMs: number; maxMs: number; quietMs?: number }
export const SETTLE: SettleTiming = { stableMs: 300, pollMs: 100, maxMs: 3000, quietMs: 1000 };

export const sameFrame = (a: Uint8Array, b: Uint8Array) => a.length === b.length && Buffer.from(a.buffer, a.byteOffset, a.length).equals(b);

/**
 * 等画面稳定，返回最后一帧与是否等到了稳定。afterAction 是刚做完动作，见 SettleTiming 的 quietMs；
 * forModel 时按给模型的尺寸截着比较（没有设备在看时，省得按设备像素截），最后一帧直接给模型。
 */
export async function settle(screen: Screen, timing: SettleTiming, options: { signal?: AbortSignal; afterAction?: boolean; forModel?: boolean } = {}): Promise<{ frame: Frame; settled: boolean }> {
  const start = Date.now();
  let frame = await screen.capture(options.forModel);
  let since = Date.now();
  let changed = !options.afterAction;
  while (Date.now() - start < timing.maxMs && !options.signal?.aborted) {
    await delay(timing.pollMs);
    const next = await screen.capture(options.forModel);
    if (!sameFrame(next.data, frame.data)) { frame = next; since = Date.now(); changed = true; continue; }
    if (Date.now() - since >= (changed ? timing.stableMs : timing.quietMs ?? timing.stableMs)) return { frame, settled: true };
  }
  return { frame, settled: false };
}
