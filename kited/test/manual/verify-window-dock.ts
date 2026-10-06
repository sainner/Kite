/**
 * 手动合同验证：直接编译真实窗口排布类型，检查拖动、停靠与预设切换的状态交接。
 * 运行：bun kited/test/manual/verify-window-dock.ts
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'window-dock-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const source = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const executable = join(root, 'verify-window-dock');
  await command([
    compiler,
    '-sdk', sdk,
    '-target', `${architecture}-apple-macosx26.0`,
    join(source, 'Workspace', 'Tiles.swift'),
    join(source, 'Workspace', 'WindowLayout.swift'),
    join(source, 'UI', 'Theme.swift'),
    join(import.meta.dir, 'WindowDock.swift'),
    '-o', executable,
  ], root);
  console.log(await command([executable], root));
} finally {
  rmSync(root, { recursive: true, force: true });
}
