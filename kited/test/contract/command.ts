/** 执行合同脚本的子进程，同时读完输出，失败时带上错误。 */
export async function command(args: string[], cwd: string): Promise<string> {
  const proc = Bun.spawn(args, {
    cwd,
    env: { ...(process.env as Record<string, string>) },
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [code, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  if (code !== 0) throw new Error(`${args.join(' ')} 失败：${stderr || stdout}`);
  return stdout.trim();
}
