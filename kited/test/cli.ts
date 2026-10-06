import { join } from 'node:path';
import '../src/cli.ts';
import { Seen } from './harness-loop.ts';

/** 测试里的 CLI 连到本进程 daemon；子进程显式继承隔离环境。 */
export function startCli(url: string, ...args: string[]) {
  const proc = Bun.spawn([process.execPath, join(import.meta.dir, '..', 'src', 'cli.ts'), ...args], {
    env: { ...(process.env as Record<string, string>), KITE_URL: url },
    stdout: 'pipe', stderr: 'pipe',
  });
  const output = new Seen<string>();
  let text = '';
  const reading = (async () => {
    const reader = proc.stdout.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        text += decoder.decode(value, { stream: true });
        output.add(text);
      }
    } finally { reader.releaseLock(); }
  })();
  const errors = new Response(proc.stderr).text();
  return {
    /** 等某段模型输出经过 SSE 到达 CLI；提前退出视为失败。 */
    waitText(marker: string) {
      return Promise.race([
        output.wait((value) => value.includes(marker)),
        proc.exited.then(async () => {
          await reading;
          if (text.includes(marker)) return text;
          throw new Error(`CLI 在输出 ${marker} 前退出：${text}`);
        }),
      ]);
    },
    async finished() {
      const [code, , stderr] = await Promise.all([proc.exited, reading, errors]);
      return { code, stdout: text, stderr };
    },
    async stop() {
      if (proc.exitCode === null) proc.kill();
      await Promise.all([proc.exited, reading, errors]);
    },
  };
}
