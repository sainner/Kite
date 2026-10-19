/**
 * 凭据的封装密钥：每台工作机一把随机的 256 位密钥，只在本机。
 * 安装版的 macOS 服务放登录钥匙串，经系统自带的 security 读写：钥匙串只认创建条目的 security，kited 升级不会再弹窗。
 * 其他情况（Linux、开发与测试）放数据目录里只有本人可读的文件。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomBytes } from 'node:crypto';
import { KiteError } from '../errors.ts';

const SERVICE = 'Kite 凭据';

export function fileKey(path: string): () => Promise<Buffer> {
  return async () => {
    if (!existsSync(path)) {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      writeFileSync(path, randomBytes(32).toString('hex'), { mode: 0o600, flag: 'wx' });
    }
    return parse(readFileSync(path, 'utf8'));
  };
}

/** account 区分同一台 Mac 上的几个 kited 数据目录，用工作机 ID。 */
export function keychainKey(account: string): () => Promise<Buffer> {
  return async () => {
    const found = await security(['find-generic-password', '-s', SERVICE, '-a', account, '-w']);
    if (found.code === 0) return parse(found.stdout);
    // 44 是找不到条目；其他错误（钥匙串锁着、被拒绝）不能另建一把，否则旧凭据就解不开了。
    if (found.code !== 44) throw new KiteError(`读钥匙串里的凭据密钥失败：${found.stderr.trim() || found.code}`, 503);
    const key = randomBytes(32).toString('hex');
    // 密钥经标准输入交给 security 的交互模式，不出现在命令行里。
    // 交互模式里命令失败时退出码不一定反映出来，存完再读回核对。
    const added = await security(['-i'], `add-generic-password -s "${SERVICE}" -a "${account}" -w ${key}\n`);
    const stored = await security(['find-generic-password', '-s', SERVICE, '-a', account, '-w']);
    if (stored.code !== 0 || stored.stdout.trim() !== key) {
      throw new KiteError(`把凭据密钥存进钥匙串失败：${added.stderr.trim() || stored.stderr.trim() || stored.code}`, 503);
    }
    return parse(key);
  };
}

function parse(text: string): Buffer {
  const key = Buffer.from(text.trim(), 'hex');
  if (key.length !== 32) throw new KiteError('凭据密钥损坏', 503);
  return key;
}

/** 钥匙串锁着或在等人允许时 security 会一直等；后台服务不能跟着卡住，超时就算这次没取到，下次再取。 */
const SECURITY_TIMEOUT_MS = 60_000;

async function security(args: string[], input?: string) {
  const child = Bun.spawn(['/usr/bin/security', ...args], {
    env: { HOME: process.env.HOME ?? '', PATH: '/usr/bin:/bin' },
    stdin: input === undefined ? 'ignore' : new TextEncoder().encode(input), stdout: 'pipe', stderr: 'pipe',
  });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; child.kill(); }, SECURITY_TIMEOUT_MS);
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    return timedOut ? { stdout: '', stderr: `钥匙串 ${SECURITY_TIMEOUT_MS / 1000} 秒没有回应，可能锁着或在等人允许`, code: -1 } : { stdout, stderr, code };
  } finally { clearTimeout(timer); }
}
