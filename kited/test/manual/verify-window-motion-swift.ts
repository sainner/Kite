/**
 * 手动原生回归：窗口收放/中途反向的实际像素、连续 resize，以及双窗口标题的位置和按钮命中。
 * 运行：bun kited/test/manual/verify-window-motion-swift.ts
 * 不计入快测预算；可传入 WindowMotion.swift 快照路径比较回归。
 */
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'window-motion-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = process.argv[2] ?? join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Workspace', 'WindowMotion.swift');
  const snapshot = join(root, 'WindowMotion.swift');
  copyFileSync(source, snapshot);
  const executable = join(root, 'verify-window-motion');
  await command([
    compiler, '-parse-as-library', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    snapshot, join(import.meta.dir, 'WindowMotionVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 30_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
