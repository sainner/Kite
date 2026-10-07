/**
 * 手动原生回归：真实 SwiftUI 静息点阵像素，以及浮动、闪烁和空白帧交接的颜色连续性。
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
  // 点阵由着色器画；命令行程序的主 bundle 是可执行文件所在目录，ShaderLibrary.default 从这里取 default.metallib。
  const air = join(root, 'DotField.air');
  await command(['xcrun', '-sdk', 'macosx', 'metal', '-c', join(source, 'DotField.metal'), '-o', air], root, 60_000);
  await command(['xcrun', '-sdk', 'macosx', 'metallib', air, '-o', join(root, 'default.metallib')], root, 60_000);
  await command([
    compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    ...['DotStage', 'Dots', 'DotTuning', 'WaitingBreath', 'Theme', 'InterfaceMode']
      .map((name) => join(source, `${name}.swift`)),
    join(import.meta.dir, 'DotCanvas.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 15_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
