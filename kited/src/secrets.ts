/** 模型只传引用，作用域由宿主绑定；明文只在工作机的账号级数据与执行宿主之间流转。 */
import { z } from 'zod';
import { KiteError } from './errors.ts';

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
/** 要存成项目密钥的环境变量文件：路径与内容合规，路径不重复；在登记项目之前检查。 */
export function checkEnvFiles(files: Array<{ path: string; value: string }>): void {
  const paths = new Set<string>();
  for (const { path, value } of files) {
    if (!secretPath.safeParse(path).success) throw new KiteError(`环境变量文件的路径无效：${path}`);
    if (!secretValue.shape.value.safeParse(value).success) throw new KiteError(`环境变量文件 ${path} 是空的、太大（超过 65536 字）或不是文本`);
    if (paths.has(path)) throw new KiteError(`环境变量文件重复：${path}`);
    paths.add(path);
  }
}
export interface SecretMetadata { name: string; kind: SecretValue['kind']; path?: string; projectId: string | null; updatedAt: number }
export interface ResolvedSecret extends SecretValue { reference: string }

const reason = z.string().trim().min(1).max(2000);
/**
 * 代理向用户要的一项密钥（docs/工具审批与提问.md「密钥请求」）：一条独立的密钥，或设了路径的环境变量文件里的一项。
 * value 是代理自己给的值，卡片预先填好；不给时由用户填写。
 */
export const secretItem = z.union([
  z.object({ name: secretName.describe('密钥名称：英文字母开头，只含字母、数字、下划线与短横线'), reason: reason.describe('要它做什么，展示给用户'),
    kind: secretValue.shape.kind.optional().describe('text（默认，命令里是环境变量）或 file（命令里是临时文件路径）'),
    value: secretValue.shape.value.optional().describe('你自己给的值（例如生成的随机串），用户确认后保存；真正的密钥不要编，留空由用户填写') }).strict(),
  z.object({ file: secretPath.describe('环境变量文件在工作区里的路径，如 .env'), key: z.string().regex(/^[A-Za-z_][A-Za-z0-9_.-]{0,127}$/).describe('变量名'),
    reason: reason.describe('要它做什么，展示给用户'),
    value: secretValue.shape.value.optional().describe('你自己给的值（例如 PORT=3001 的 3001）：文件里没有这一项或值本来是你给的时直接存，否则用户确认后保存；真正的密钥不要编，留空由用户填写') }).strict(),
]);
export type SecretItem = z.infer<typeof secretItem>;

/** 密钥请求里一项的称呼：独立密钥的名称，或「文件 里的 变量名」。 */
export const secretLabel = (item: { name?: string; file?: string; key?: string }): string => item.file ? `${item.file} 里的 ${item.key}` : item.name ?? '';

/** 一次请求要的几项，用户在同一张卡片里填，填了几项存几项；同一项不能要两次。 */
export const secretRequest = z.array(secretItem).min(1).max(10).superRefine((items, context) => {
  const seen = new Set<string>();
  for (const item of items) {
    const label = secretLabel(item);
    if (seen.has(label)) context.addIssue({ code: 'custom', message: `同一次请求里重复要了 ${label}` });
    seen.add(label);
  }
});
export type SecretRequest = z.infer<typeof secretRequest>;

export interface SecretProvider {
  list?(signal: AbortSignal): Promise<Array<SecretMetadata & { reference: string }>>;
  resolve(references: string[], signal: AbortSignal): Promise<ResolvedSecret[]>;
  /** 向用户要几项密钥：发出请求后立即返回交给模型的说明（全放行且每项都给了值时直接存好）；用户填好后的结果另作输入交给代理。 */
  request?(request: SecretRequest, signal: AbortSignal): Promise<string>;
  /** 代理收回自己发出的密钥请求，返回交给模型的说明。 */
  withdraw?(id: string): string;
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
