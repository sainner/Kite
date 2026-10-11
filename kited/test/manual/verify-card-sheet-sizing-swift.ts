/**
 * 手动原生回归：同一次真实 SwiftUI sheet 随 CardSheet 内容增减调整高度。
 * 运行：bun kited/test/manual/verify-card-sheet-sizing-swift.ts
 * 不计入快测预算；可传入拆分前保留的 CardControls.swift 单文件路径比较修复前后。
 */
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'card-sheet-sizing-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const app = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const historicalControls = process.argv[2];
  const sheet = historicalControls ?? join(app, 'UI', 'CardSheet.swift');
  // 共享工作区可能继续改产品文件；本次编译固定一个完整快照，避免读到改动中的源文件。
  const snapshot = join(root, 'CardSheet.swift');
  copyFileSync(sheet, snapshot);
  const executable = join(root, 'verify-card-sheet-sizing');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    snapshot,
    // 历史单文件已包含这些类型，不能再编译拆分后的文件。
    ...(historicalControls ? [] : ['CardControls', 'CardActions'])
      .map((name) => join(app, 'UI', `${name}.swift`)),
    ...['Theme', 'InterfaceMode', 'PaneButtons', 'ControlPointer', 'Appearance', 'Typing', 'Toast', 'ActionBar']
      .map((name) => join(app, 'UI', `${name}.swift`)),
    join(app, 'Workspace', 'PaneHeader.swift'),
    join(app, 'Workspace', 'PaneHeaderHelp.swift'),
    join(app, 'Conversation', 'ThreadHeaderItems.swift'),
    join(import.meta.dir, 'CardSheetSizingVerify.swift'), '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 15_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
