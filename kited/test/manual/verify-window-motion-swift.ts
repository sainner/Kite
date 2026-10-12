/**
 * 手动原生回归：窗口收放/反向像素、resize 与双窗标题命中，以及正文/环境更新和原生选区保留。
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
  const workspace = join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Workspace');
  const source = process.argv[2] ?? join(workspace, 'WindowMotion.swift');
  const snapshot = join(root, 'WindowMotion.swift');
  copyFileSync(source, snapshot);
  const header = join(root, 'WindowHeaderAnchored.swift');
  copyFileSync(join(workspace, 'WindowHeaderAnchored.swift'), header);
  const executable = join(root, 'verify-window-motion');
  await command([
    compiler, '-parse-as-library', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    snapshot, header, join(import.meta.dir, 'WindowMotionVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 30_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
