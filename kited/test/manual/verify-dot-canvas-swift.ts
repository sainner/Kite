/**
 * 手动原生回归：真实 DotField 浮动、闪烁和空白帧交接的颜色连续性。
 * 运行：bun kited/test/manual/verify-dot-canvas-swift.ts
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'dot-canvas-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'UI');
  const executable = join(root, 'verify-dot-canvas');
  await command([
    compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    ...['DotStage', 'DotPattern', 'DotExpression', 'Dots', 'WaitingBreath', 'Theme', 'InterfaceMode']
      .map((name) => join(source, `${name}.swift`)),
    join(import.meta.dir, 'DotCanvas.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 15_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
