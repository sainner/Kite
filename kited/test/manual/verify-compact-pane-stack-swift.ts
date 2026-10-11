/**
 * 手动原生合同：紧凑窗口行横滑松手后的焦点切换与按钮命中、保活窗口的环境动作、外壳控制区接回源环境后的 keyboardShown、PanePresence 随停稳翻转。
 * 和生产的 CompactPaneStack.swift 一起编进去的还有 WindowMotion.swift、CompactPaneHeader.swift、PaneControlSwipe.swift，其余类型由夹具给最小定义。
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
  const workspace = join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Workspace');
  const source = process.argv[2] ?? join(workspace, 'CompactPaneStack.swift');
  const executable = join(root, 'verify-compact-pane-stack');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    source,
    join(workspace, 'WindowMotion.swift'),
    join(workspace, 'CompactPaneHeader.swift'),
    join(workspace, 'PaneControlSwipe.swift'),
    join(import.meta.dir, 'CompactPaneStackVerify.swift'),
    '-o', executable,
  ], root, 120_000);
  console.log(await command([executable], root, 30_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
