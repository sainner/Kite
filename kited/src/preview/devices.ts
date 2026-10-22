/**
 * 预览目标装到哪台设备（docs/实例操作.md「目标」）：设备候选是工作机能建的模拟器型号，加上与工作机配对过的 iPhone、iPad（xcrun devicectl）。
 * 实例配置里的 device 是 {simulator: 型号} 或 {physical: 设备编号}；模拟器经 KITE_SIMULATOR、真机经 KITE_DEVICE 把编号交给目标脚本。
 * 真机拿不到实时画面，只装包。在 iPhone、iPad 上打开新建窗口时默认选中手上这台，App 按硬件型号（productType）对。
 */
import { randomUUID } from 'node:crypto';
import { readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { systemCommand } from '../system-command.ts';

export const deviceSchema = z.union([
  z.object({ simulator: z.string().trim().min(1).max(100) }).strict(),
  z.object({ physical: z.string().trim().min(1).max(100) }).strict(),
]);
export type PreviewDevice = z.infer<typeof deviceSchema>;

/** 设备候选里的一项：模拟器型号（family 是 iPhone 或 iPad），或配对过的真机（名字、硬件型号、市场名、连没连着）。 */
export type DeviceCandidate = { kind: 'simulator'; model: string; family: string }
  | { kind: 'physical'; id: string; name: string; model: string; marketingName?: string; connected: boolean };

const listSchema = z.object({ result: z.object({ devices: z.array(z.object({
  identifier: z.string(),
  deviceProperties: z.object({ name: z.string().optional() }).loose(),
  hardwareProperties: z.object({ productType: z.string().optional(), marketingName: z.string().optional(), reality: z.string().optional(),
    platform: z.string().optional() }).loose(),
  connectionProperties: z.object({ pairingState: z.string().optional(), transportType: z.string().optional(), tunnelState: z.string().optional() }).loose(),
}).loose()) }).loose() }).loose();

/**
 * 与工作机配对过的 iPhone、iPad；不是 Mac、没有 Xcode 时为空。连得上（USB 或同一网络）的才 connected：够不着的没有 transportType，
 * 或 tunnelState 为 unavailable；disconnected 只是隧道还没建，装的时候 devicectl 自己连上。JSON 的字段不是公开约定，对不上时按没有处理。
 */
export async function pairedDevices(env: Record<string, string>): Promise<Array<Extract<DeviceCandidate, { kind: 'physical' }>>> {
  if (process.platform !== 'darwin') return [];
  const output = join(tmpdir(), `kite-devices-${randomUUID()}.json`);
  try {
    const listed = await systemCommand(['/usr/bin/xcrun', 'devicectl', 'list', 'devices', '--quiet', '--json-output', output], { env, timeoutMs: 20_000 });
    if (listed.code !== 0) return [];
    return listSchema.parse(JSON.parse(readFileSync(output, 'utf8'))).result.devices
      .filter((device) => device.hardwareProperties.reality === 'physical'
        && (device.hardwareProperties.platform === 'iOS' || device.hardwareProperties.platform === 'iPadOS')
        && device.connectionProperties.pairingState === 'paired')
      .map((device) => ({ kind: 'physical' as const, id: device.identifier, name: device.deviceProperties.name ?? device.identifier,
        model: device.hardwareProperties.productType ?? '', ...(device.hardwareProperties.marketingName ? { marketingName: device.hardwareProperties.marketingName } : {}),
        connected: !!device.connectionProperties.transportType && device.connectionProperties.tunnelState !== 'unavailable' }));
  } catch {
    return [];
  } finally {
    rmSync(output, { force: true });
  }
}

/**
 * 预览用到的设备：模拟器型号须是工作机能建的，真机须配对过且够得着。找不到时错误里列出可选的。
 */
export function checkDevice(device: PreviewDevice, candidates: DeviceCandidate[]): DeviceCandidate {
  const found = 'simulator' in device
    ? candidates.find((candidate) => candidate.kind === 'simulator' && candidate.model === device.simulator)
    : candidates.find((candidate) => candidate.kind === 'physical' && candidate.id === device.physical);
  if (found?.kind === 'physical' && !found.connected) throw new KiteError(`${found.name} 现在够不着：连上线，或和工作机在同一局域网`, 409);
  if (found) return found;
  const listed = candidates.map(deviceLabel).join('、');
  throw new KiteError(`没有这台设备：${'simulator' in device ? device.simulator : device.physical}${listed ? `，可选：${listed}` : '，这台工作机没有可用的模拟器和配对过的设备'}`, 404);
}

/** 设备在列表与错误里的写法：模拟器写 {simulator: 型号}，真机写名字与 {physical: 编号}。 */
export const deviceLabel = (candidate: DeviceCandidate) => candidate.kind === 'simulator'
  ? `{simulator: "${candidate.model}"}` : `${candidate.name}（${candidate.marketingName ?? candidate.model}）{physical: "${candidate.id}"}`;
