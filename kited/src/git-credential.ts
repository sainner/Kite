/**
 * 让一次 git 子进程用给定凭据访问某个 HTTPS 远程，不写任何 git 配置文件。
 * 用 GIT_CONFIG_COUNT 注入只对该地址生效的凭据助手，助手从环境变量读口令，口令不出现在命令行或进程列表里。
 * 先用空值清空已有助手列表，避免系统钥匙串里的旧凭据抢先，也避免 git 把这份凭据存进钥匙串。
 */
export interface GitCredential {
  username: string;
  password: string;
}

/** 按 HTTPS 地址给出访问凭据；没有绑定时为 null，交给用户本机的 git 配置。 */
export interface GitCredentials {
  credential(url: string): Promise<GitCredential | null>;
}

const HELPER = '!f() { test "$1" = get && printf "username=%s\\npassword=%s\\n" "$KITE_GIT_USERNAME" "$KITE_GIT_PASSWORD"; }; f';

export function credentialEnv(url: string, credential: GitCredential | null): Record<string, string> {
  if (!credential) return { GIT_TERMINAL_PROMPT: '0' };
  const { protocol, host } = new URL(url);
  const key = `credential.${protocol}//${host}.helper`;
  return { ...gitConfigEnv([[key, ''], [key, HELPER]]), KITE_GIT_USERNAME: credential.username, KITE_GIT_PASSWORD: credential.password };
}

/** 只对这一次 git 子进程生效的配置（GIT_CONFIG_COUNT），不写配置文件；同时关掉交互式提示。 */
export function gitConfigEnv(pairs: Array<[string, string]>): Record<string, string> {
  return { GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_COUNT: String(pairs.length),
    ...Object.fromEntries(pairs.flatMap(([key, value], index) => [[`GIT_CONFIG_KEY_${index}`, key], [`GIT_CONFIG_VALUE_${index}`, value]])) };
}
