/** 模型只传引用，作用域由宿主绑定；明文仅在账号服务与执行宿主间流转。 */
import { z } from 'zod';

export const secretName = z.string().regex(/^[a-zA-Z][a-zA-Z0-9_-]{0,63}$/);
export const secretReference = z.string().regex(/^\{(account|project)\.[a-zA-Z][a-zA-Z0-9_-]{0,63}\}$/);
export const secretValue = z.object({
  kind: z.enum(['text', 'file']),
  value: z.string().min(1).max(65_536).refine((value) => !value.includes('\0'), '密钥不能包含 NUL'),
}).strict();
export type SecretValue = z.infer<typeof secretValue>;
export interface SecretMetadata { name: string; kind: SecretValue['kind']; projectId: string | null; updatedAt: number }
export interface ResolvedSecret extends SecretValue { reference: string }
export interface SecretProvider {
  list?(signal: AbortSignal): Promise<Array<SecretMetadata & { reference: string }>>;
  resolve(references: string[], signal: AbortSignal): Promise<ResolvedSecret[]>;
}

export const secretEnvironmentName = z.string().regex(/^KITE_SECRET_[A-Z][A-Z0-9_]*$/);
export const secretBindings = z.record(secretEnvironmentName, secretReference)
  .refine((bindings) => Object.keys(bindings).length <= 32, '一次最多使用 32 个密钥');
