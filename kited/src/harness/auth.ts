/** 读取 Kite 独立授权的文件凭据；登录工具负责写入，本层只读。 */
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import type { SubscriptionCredentials } from './subscription-types.ts';

const credentials = z.object({
  auth_mode: z.literal('chatgpt'),
  tokens: z.object({ access_token: z.string().min(1), account_id: z.string().min(1) }),
});

export function defaultAuthFile(): string {
  return join(process.env.KITE_HOME ?? join(homedir(), '.kite'), 'auth', 'chatgpt', 'auth.json');
}

export async function readSubscriptionCredentials(authFile = defaultAuthFile()): Promise<SubscriptionCredentials> {
  let data: unknown;
  try { data = JSON.parse(await readFile(authFile, 'utf8')); }
  catch { throw new Error(`无法读取 ChatGPT 登录凭据：${authFile}。请先在 Kite 的独立认证目录完成设备登录，或用 --auth 指定文件。`); }
  const parsed = credentials.safeParse(data);
  // 不输出 Zod 诊断或文件内容，避免错误报告带上凭据。
  if (!parsed.success) throw new Error('需要 ChatGPT 订阅登录凭据；不接受 API key。请重新完成设备登录。');
  const { access_token, account_id } = parsed.data.tokens;
  let expiry: unknown;
  try { expiry = JSON.parse(Buffer.from(access_token.split('.')[1] ?? '', 'base64url').toString()).exp; }
  catch { throw new Error('ChatGPT 访问令牌格式无效，请重新登录。'); }
  if (typeof expiry !== 'number' || expiry * 1000 <= Date.now() + 30_000) {
    throw new Error('ChatGPT 访问令牌已过期或即将过期，请在该凭据所属的认证目录重新登录。Kite 尚未自动刷新登录。');
  }
  return { accessToken: access_token, accountId: account_id };
}
