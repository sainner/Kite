/**
 * 手动原生合同：生产的 RepresentedRoot 截住里面托管视图（岛）的约束失效——岛按帧走，外面 representable 所在的 SwiftUI 图不再每帧整轮重排；
 * 对照场景换成普通 NSView，外面应每帧重排；RepresentedRoot 里普通子视图的排版照常按帧。
 * 运行：bun kited/test/manual/verify-represented-root-swift.ts [RepresentedRoot.swift 的替代路径]
 * 第一个参数可指定一份 RepresentedRoot.swift 快照，用来编译保留的回归快照或做判别力核验。
 * 用一个屏上的小测试窗口（TimelineView(.animation) 要窗口在屏上才走），约 10 秒；需要已解锁的图形会话。
 * 不计入快测预算，不在 .kite/check 里跑，不启动或操作 Kite App，不碰用户的剪贴板和 UserDefaults。
 */
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'represented-root-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = process.argv[2] ?? join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'UI', 'RepresentedRoot.swift');
  const snapshot = join(root, 'RepresentedRoot.swift');
  copyFileSync(source, snapshot);
  const executable = join(root, 'verify-represented-root');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    snapshot, join(import.meta.dir, 'RepresentedRootVerify.swift'), '-o', executable,
  ], root, 120_000);
  console.log(await command([executable], root, 30_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
