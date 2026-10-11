/**
 * 手动原生回归：停靠提示通过生产 source/host 跨越内容 mask，居中于图标并完整绘入窗口留白。
 * 运行：bun kited/test/manual/verify-dock-hover-label-swift.ts [DockHoverLabel.swift 快照]
 * 不计入快测预算，不启动或操作 Kite App。
 */
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'dock-hover-label-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = process.argv[2] ?? join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Workspace', 'DockHoverLabel.swift');
  const snapshot = join(root, 'DockHoverLabel.swift');
  copyFileSync(source, snapshot);
  const executable = join(root, 'verify-dock-hover-label');
  await command([
    compiler, '-parse-as-library', '-O', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    snapshot, join(import.meta.dir, 'DockHoverLabelVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 15_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
