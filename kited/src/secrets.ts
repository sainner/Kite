/** 模型只传引用，作用域由宿主绑定；明文只在工作机的账号级数据与执行宿主之间流转。 */
import { z } from 'zod';

export const secretName = z.string().regex(/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/);
export const secretReference = z.string().regex(/^\{(account|project)\.[a-zA-Z][a-zA-Z0-9_-]{0,63}\}$/);
export const secretValue = z.object({
  kind: z.enum(['text', 'file']),
  value: z.string().min(1).max(65_536).refine((value) => !value.includes('\0'), '密钥不能包含 NUL'),
}).strict();
export type SecretValue = z.infer<typeof secretValue>;
/** 项目专用的文件密钥在工作区里的路径：相对路径，不含 . 与 ..，不在 .git 里。 */
export const secretPath = z.string().min(1).max(512).refine((path) => !path.startsWith('/') && !/[\\\0\n\r]/.test(path)
  && path.split('/').every((part) => part && part !== '.' && part !== '..' && part !== '.git'), '路径要写工作区里的相对路径，不含 . 与 ..，不在 .git 里');
export interface SecretMetadata { name: string; kind: SecretValue['kind']; path?: string; projectId: string | null; updatedAt: number }
export interface ResolvedSecret extends SecretValue { reference: string }

const reason = z.string().trim().min(1).max(2000);
/**
 * 代理向用户要一个密钥（docs/工具审批与提问.md「密钥请求」）：一条独立的密钥，或设了路径的环境变量文件里的一项。
 * value 是代理自己给的值，卡片预先填好；不给时由用户填写。
 */
export const secretRequest = z.union([
  z.object({ name: secretName.describe('密钥名称：英文字母开头，只含字母、数字、下划线与短横线'), reason: reason.describe('要它做什么，展示给用户'),
    kind: secretValue.shape.kind.optional().describe('text（默认，命令里是环境变量）或 file（命令里是临时文件路径）'),
    value: secretValue.shape.value.optional().describe('你自己给的值（例如生成的随机串），用户确认后保存；真正的密钥不要编，留空由用户填写') }).strict(),
  z.object({ file: secretPath.describe('环境变量文件在工作区里的路径，如 .env'), key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_.-]{0,127}$/).describe('变量名'),
    reason: reason.describe('要它做什么，展示给用户'),
    value: secretValue.shape.value.optional().describe('你自己给的值（例如 PORT=3001 的 3001），用户确认后保存；真正的密钥不要编，留空由用户填写') }).strict(),
]);
export type SecretRequest = z.infer<typeof secretRequest>;

export interface SecretProvider {
  list?(signal: AbortSignal): Promise<Array<SecretMetadata & { reference: string }>>;
  resolve(references: string[], signal: AbortSignal): Promise<ResolvedSecret[]>;
  /** 向用户要一个密钥，等用户在卡片里填好后保存；返回交给模型的结果说明，不含用户填的值。 */
  request?(request: SecretRequest, signal: AbortSignal): Promise<string>;
}

/** 环境变量文件（dotenv 写法）里 key 那一行，可带 export 前缀。 */
const envLine = (key: string) => new RegExp(`^(?:export\\s+)?${key.replace(/[.]/g, '\\.')}\\s*=.*$`, 'm');

/** 环境变量文件里有没有 key 这一项。 */
export const hasEnvKey = (content: string, key: string): boolean => envLine(key).test(content);

/** 环境变量文件里的一项按 dotenv 的写法替换，没有就追加；值里有空白、引号、# 或换行时加双引号转义。 */
export function setEnvLine(content: string, key: string, value: string): string {
  const quoted = /^[A-Za-z0-9_./:@%+,=-]*$/.test(value) ? value
    : `"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r')}"`;
  const line = `${key}=${quoted}`;
  if (hasEnvKey(content, key)) return content.replace(envLine(key), () => line);
  return `${content}${content && !content.endsWith('\n') ? '\n' : ''}${line}\n`;
}

export const secretEnvironmentName = z.string().regex(/^KITE_SECRET_[A-Z][A-Z0-9_]*$/);
export const secretBindings = z.record(secretEnvironmentName, secretReference)
  .refine((bindings) => Object.keys(bindings).length <= 32, '一次最多使用 32 个密钥');
