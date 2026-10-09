/**
 * 手动原生验证：窗口焦点、点阵停用与视图移除经过真实 SwiftUI 宿主后恢复 App 点阵占用状态。
 * 运行：bun kited/test/manual/verify-dot-background-swift.ts
 * 不计入快测预算。
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'dot-background-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'UI');
  const executable = join(root, 'verify-dot-background');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    ...['DotBackground', 'DotStage', 'DotPattern', 'DotExpression', 'Dots', 'WaitingBreath', 'Theme', 'InterfaceMode']
      .map((name) => join(source, `${name}.swift`)),
    join(import.meta.dir, 'DotBackgroundVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 15_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
