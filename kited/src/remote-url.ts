/**
 * 远程仓库地址。项目以远程为身份，同一仓库的 SSH 与 HTTPS 写法必须归一成同一个字符串：
 * `域名[:端口]/路径`，去掉用户名、口令、结尾的 .git 与斜杠，整体转小写（GitHub、GitLab 的路径不区分大小写）。
 * 只有 http(s) 保留非默认端口；SSH 的端口和网页服务无关，丢掉。
 */
const SCHEMES = new Set(['https', 'http', 'ssh', 'git', 'git+ssh']);

export function normalizeRemote(raw: string): string | null {
  const text = raw.trim();
  let host: string;
  let path: string;
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
    let url: URL;
    try { url = new URL(text); } catch { return null; }
    const scheme = url.protocol.slice(0, -1).toLowerCase();
    if (!SCHEMES.has(scheme)) return null;
    host = url.hostname + (url.port && scheme.startsWith('http') ? `:${url.port}` : '');
    try { path = decodeURIComponent(url.pathname); } catch { return null; }
  } else {
    // scp 写法：[用户@]主机:路径
    const scp = /^(?:[^@/\s]+@)?([^:/\s]+):(?!\/)(.+)$/.exec(text);
    if (!scp) return null;
    host = scp[1]!;
    path = scp[2]!;
  }
  path = path.replace(/^\/+|\/+$/g, '').replace(/\.git$/i, '');
  if (!host || !path || /\s/.test(path) || path.split('/').some((s) => !s || s === '.' || s === '..')) return null;
  return `${host}/${path}`.toLowerCase();
}

/** 归一化地址所在的主机，凭据按它查找。 */
export function remoteHost(normalized: string): string {
  return normalized.slice(0, normalized.indexOf('/'));
}

/** 访问用的 HTTPS 地址。用户给的是 http(s) 就原样使用（去掉其中的凭据），SSH 写法换成 HTTPS，以便用 token 访问。 */
export function httpsRemote(raw: string): string | null {
  const normalized = normalizeRemote(raw);
  if (!normalized) return null;
  if (/^https?:\/\//i.test(raw.trim())) {
    const url = new URL(raw.trim());
    url.username = '';
    url.password = '';
    return url.toString();
  }
  return `https://${normalized}.git`;
}

/** 远程地址末段，作为项目的显示名，保留用户写法的大小写。 */
export function remoteName(raw: string): string {
  const text = raw.trim().replace(/[/\\]+$/, '').replace(/\.git$/i, '');
  return text.slice(Math.max(text.lastIndexOf('/'), text.lastIndexOf(':')) + 1) || text;
}
