/**
 * 手动合同：真实 SwiftUI 宿主验证动画收起，SDK 值验证滚动阶段的定位交接。
 * 运行：bun kited/test/contract/verify-transcript-scroll-swift.ts
 * 不计入快测预算。
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'transcript-scroll-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const repository = join(import.meta.dir, '..', '..', '..');
  const source = readFileSync(join(repository, 'app', 'Kite', 'TranscriptScroll.swift'), 'utf8');
  const fixture = join(root, 'TranscriptScrollContract.swift');
  // fileprivate 只限同文件：原样编译生产文件与探针，不抽取、不复制实现。
  writeFileSync(fixture, source + '\n' + readFileSync(join(import.meta.dir, 'TranscriptScroll.swift'), 'utf8'));
  const executable = join(root, 'verify-transcript-scroll');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor', '-sdk', sdk,
    '-target', `${architecture}-apple-macosx26.0`,
    fixture, '-o', executable,
  ], root, 60_000);
  console.log(await command([executable], root, 20_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
