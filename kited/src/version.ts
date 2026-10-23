/**
 * Kite 的版本：构建号标识一份运行文件，协议号标识 App 与工作机之间的接口，见 docs/App.md「版本」与
 * docs/macOS安装与打包.md「自动更新」。构建号由打包写进运行目录的 manifest.json；源码运行没有它，记为 dev。
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';

/** App 依赖的接口或事件格式有不兼容的改动时加 1，与 App 的 KiteProtocol.version 一起改。 */
export const PROTOCOL = 19;

export interface Version { build: string; protocol: number; builtAt?: string; commit?: string }

/** 运行目录的 manifest.json：打包时写入，安装器据此核对平台、架构与运行时。 */
export const runtimeManifest = z.object({
  platform: z.string(), arch: z.string(), bun: z.string(), builtAt: z.string(),
  build: z.string().regex(/^[0-9a-f]{16}$/), protocol: z.number().int(), commit: z.string(),
});
export type RuntimeManifest = z.infer<typeof runtimeManifest>;

/** 读运行目录的 manifest；没有（源码运行）或读不懂时为 undefined。 */
export function readManifest(runtime: string): RuntimeManifest | undefined {
  const file = join(runtime, 'manifest.json');
  if (!existsSync(file)) return undefined;
  try { return runtimeManifest.parse(JSON.parse(readFileSync(file, 'utf8'))); } catch { return undefined; }
}

export function versionOf(manifest: RuntimeManifest | undefined): Version {
  return manifest ? { build: manifest.build, protocol: PROTOCOL, builtAt: manifest.builtAt, commit: manifest.commit } : { build: 'dev', protocol: PROTOCOL };
}
