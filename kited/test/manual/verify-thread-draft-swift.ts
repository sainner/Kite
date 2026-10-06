/**
 * 手动合同验证：编译 WorkThread 的真实草稿方法，验证停止退回与发送淡出回调交错时不丢字、不重复。
 * 运行：bun kited/test/manual/verify-thread-draft-swift.ts
 * Swift 编译不计入 small 测试耗时预算。
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

function method(source: string, signature: string): string {
  const start = source.indexOf(`    ${signature}`);
  if (start < 0 || source.indexOf(`    ${signature}`, start + 1) >= 0) throw new Error(`WorkThread 方法不唯一：${signature}`);
  const open = source.indexOf('{', start);
  if (open < 0) throw new Error(`WorkThread 方法缺少正文：${signature}`);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`WorkThread 方法未闭合：${signature}`);
}

const root = mkdtempSync(join(tmpdir(), 'thread-draft-contract-'));
try {
  const workThread = join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'Conversation', 'WorkThread.swift');
  const source = readFileSync(workThread, 'utf8');
  const begin = method(source, 'func beginDraftSubmission() -> UUID');
  const finish = method(source, 'func finishDraftSubmission(_ token: UUID)');
  const restore = method(source, 'private func restoreDraft(_ texts: [String])');
  const fixture = join(root, 'ThreadDraftContract.swift');
  writeFileSync(fixture, String.raw`
import Foundation

final class WorkThread {
    var draft = ""
    private var submittedDraft: (id: UUID, text: String)?
${begin}
${finish}
${restore}
    func applyReturned(_ texts: [String]) { restoreDraft(texts) }
}

private func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

@main
struct ThreadDraftContract {
    static func main() {
        let thread = WorkThread()
        thread.draft = "sending"
        let fading = thread.beginDraftSubmission()
        thread.draft += "new draft"
        thread.applyReturned(["sending", "queued"])
        require(thread.draft == "sending\n\nqueued\n\nnew draft", "return before fade lost or duplicated draft")
        thread.finishDraftSubmission(fading)
        require(thread.draft == "sending\n\nqueued\n\nnew draft", "late fade removed returned draft")

        thread.draft = "first"
        let fadedFirst = thread.beginDraftSubmission()
        thread.draft += "new draft"
        thread.finishDraftSubmission(fadedFirst)
        thread.applyReturned(["first"])
        require(thread.draft == "first\n\nnew draft", "fade before return lost or replaced new draft")

        thread.draft = "existing draft"
        thread.applyReturned(["returned A", "returned B"])
        require(thread.draft == "returned A\n\nreturned B\n\nexisting draft", "returned queue lost existing draft or order")
        print("thread draft return and fade contract passed")
    }
}
  `);
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const executable = join(root, 'thread-draft-contract');
  await command([
    compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    '-parse-as-library', fixture, '-o', executable,
  ], root);
  console.log(await command([executable], root));
} finally {
  rmSync(root, { recursive: true, force: true });
}
