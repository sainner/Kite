/**
 * 手动原生合同：真实 SwiftUI 卡片切换后的环境入口恢复与按钮 hit testing。
 * 运行：bun kited/test/manual/verify-compact-pane-stack-swift.ts
 * 不计入快测预算。
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'compact-pane-stack-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = process.argv[2] ?? join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Workspace', 'CompactPaneStack.swift');
  const executable = join(root, 'verify-compact-pane-stack');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    source, join(import.meta.dir, 'CompactPaneStackVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 30_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
