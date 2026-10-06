/**
 * 让一次 git 子进程用给定凭据访问某个 HTTPS 远程，不写任何 git 配置文件。
 * 用 GIT_CONFIG_COUNT 注入只对该地址生效的凭据助手，助手从环境变量读口令，口令不出现在命令行或进程列表里。
 * 先用空值清空已有助手列表，避免系统钥匙串里的旧凭据抢先，也避免 git 把这份凭据存进钥匙串。
 */
export interface GitCredential {
  username: string;
  password: string;
}

const HELPER = '!f() { test "$1" = get && printf "username=%s\\npassword=%s\\n" "$KITE_GIT_USERNAME" "$KITE_GIT_PASSWORD"; }; f';

export function credentialEnv(url: string, credential: GitCredential | null): Record<string, string> {
  const env: Record<string, string> = { GIT_TERMINAL_PROMPT: '0' };
  if (!credential) return env;
  const { protocol, host } = new URL(url);
  const key = `credential.${protocol}//${host}.helper`;
  return {
    ...env,
    GIT_CONFIG_COUNT: '2',
    GIT_CONFIG_KEY_0: key, GIT_CONFIG_VALUE_0: '',
    GIT_CONFIG_KEY_1: key, GIT_CONFIG_VALUE_1: HELPER,
    KITE_GIT_USERNAME: credential.username,
    KITE_GIT_PASSWORD: credential.password,
  };
}
