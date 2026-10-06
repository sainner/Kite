/** 执行合同脚本的子进程，同时读完输出，失败时带上错误。 */
export async function command(args: string[], cwd: string, timeoutMs?: number): Promise<string> {
  const proc = Bun.spawn(args, {
    cwd,
    env: { ...(process.env as Record<string, string>) },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  let timedOut = false;
  const deadline = timeoutMs === undefined ? undefined : setTimeout(() => {
    timedOut = true;
    proc.kill('SIGKILL');
  }, timeoutMs);
  try {
    const [code, stdout, stderr] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    if (code !== 0) throw new Error(`命令${timedOut ? '超时' : '失败'}（${code}）：${args.join(' ')}\n${stdout}\n${stderr}`);
    return stdout.trim();
  } finally {
    if (deadline !== undefined) clearTimeout(deadline);
  }
}
