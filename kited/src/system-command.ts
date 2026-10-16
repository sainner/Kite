/** 跑系统自带的小工具读它的输出：env 显式给出，不继承 kited 的环境；超时就杀掉。 */
export async function systemCommand(command: string[], options: { env?: Record<string, string>; timeoutMs?: number } = {}): Promise<{ code: number; stdout: string }> {
  const child = Bun.spawn(command, { env: options.env ?? { PATH: '/usr/bin:/bin' }, stdout: 'pipe', stderr: 'ignore' });
  const timer = setTimeout(() => child.kill(), options.timeoutMs ?? 5_000);
  try {
    const stdout = await new Response(child.stdout).text();
    return { code: await child.exited, stdout };
  } finally { clearTimeout(timer); }
}
