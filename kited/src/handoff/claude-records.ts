/**
 * Claude 原生会话文件的定位与追加。条目格式属于锁定版本 CLI 的内部格式（SDK 0.3.280 / CLI 2.1.280），
 * 合成规则与验证方法见 spikes/handoff，升级 SDK 时须重跑。
 */
import { closeSync, existsSync, fstatSync, fsyncSync, mkdirSync, openSync, readFileSync, readSync, realpathSync, rmSync, writeSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { getSessionInfo } from '@anthropic-ai/claude-agent-sdk';

export interface ClaudeEntry {
  type: string;
  uuid?: string;
  parentUuid?: string | null;
  isSidechain?: boolean;
  /** Kite 从其他后端导入的条目；through 是来源记录中已导入的最后位置。 */
  kite?: { import: string; through: string };
  /** Kite 整体重组会话时写入的条目（压缩分界、合成历史与 last-prompt）；只服务模型上下文，显示时略过。 */
  kiteRebase?: string;
  [key: string]: unknown;
}

/** 与 CLI 的项目目录命名一致：非字母数字换成 -，过长时截断并附哈希。 */
function projectDirectory(cwd: string): string {
  const name = cwd.replace(/[^a-zA-Z0-9]/g, '-');
  if (name.length <= 200) return name;
  let hash = 0;
  for (let index = 0; index < cwd.length; index++) hash = (hash << 5) - hash + cwd.charCodeAt(index) | 0;
  return `${name.slice(0, 200)}-${Math.abs(hash).toString(36)}`;
}

function candidates(cwd: string, nativeId: string): string[] {
  // claudeOptions 继承宿主环境，配置目录随 CLAUDE_CONFIG_DIR。
  const projects = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude'), 'projects');
  const paths = [cwd, existsSync(cwd) ? realpathSync(cwd) : cwd].map((path) => join(projects, projectDirectory(path), `${nativeId}.jsonl`));
  return [...new Set(paths)];
}

/** 读取完整落盘的条目；没有会话时为空。 */
export function readClaudeEntries(cwd: string, nativeId: string): ClaudeEntry[] {
  const path = candidates(cwd, nativeId).find((candidate) => existsSync(candidate));
  if (!path) return [];
  const text = readFileSync(path, 'utf8');
  return text.slice(0, text.lastIndexOf('\n') + 1).split('\n').filter(Boolean).map((line) => JSON.parse(line) as ClaudeEntry);
}

/** 只追加，不改已有条目；新建的文件须能被 SDK 按同一会话 ID 找到，否则撤回并报错。 */
export async function appendClaudeEntries(cwd: string, nativeId: string, entries: ClaudeEntry[]): Promise<void> {
  const existing = candidates(cwd, nativeId).find((candidate) => existsSync(candidate));
  const path = existing ?? candidates(cwd, nativeId)[0]!;
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const fd = openSync(path, 'a+', 0o600);
  try {
    // CLI 异常退出可能留下未换行的尾部；先补换行，保持每行一条完整 JSON。只读最后一个字节。
    const size = fstatSync(fd).size, last = Buffer.alloc(1);
    const prefix = size && readSync(fd, last, 0, 1, size - 1) && last[0] !== 10 ? '\n' : '';
    const data = Buffer.from(prefix + entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n');
    let offset = 0;
    while (offset < data.length) offset += writeSync(fd, data, offset);
    fsyncSync(fd);
  } finally { closeSync(fd); }
  if (!existing && !await getSessionInfo(nativeId, { dir: cwd })) {
    rmSync(path, { force: true });
    throw new Error('合成的 Claude 会话无法被 SDK 定位，项目目录命名可能与当前 Claude Code 不一致');
  }
}
