/**
 * 推流转材料前判断远程仓库是否公开。材料里有会话记录，按「有仓库读权限的人都能看」来定：
 * GitHub 用账号为它绑定的凭据查仓库信息，没有凭据时匿名查（私有仓库匿名查不到，算作看不出）；其他平台看不出。
 */
import type { AccountClient } from '../account-client.ts';

export async function repositoryVisibility(remote: string, account: AccountClient): Promise<'private' | 'public' | 'unknown'> {
  const [host, owner, repo] = remote.split('/');
  if (host !== 'github.com' || !owner || !repo) return 'unknown';
  try {
    const credential = account.linked ? await account.credential(`https://github.com/${owner}/${repo}.git`) : null;
    const response = await fetch(`https://api.github.com/repos/${owner}/${repo}`, {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'Kite', ...(credential ? { authorization: `Bearer ${credential.password}` } : {}) },
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) return 'unknown';
    const data = await response.json() as { private?: unknown };
    return data.private === true ? 'private' : data.private === false ? 'public' : 'unknown';
  } catch { return 'unknown'; }
}
