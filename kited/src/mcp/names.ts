/** 外部 MCP 服务名的规则：角色、项目约束、实例开关与机器清单共用；不依赖 SDK，账号级数据也能引用。 */
import { z } from 'zod';

export const serverNameSchema = z.string().regex(/^[a-zA-Z0-9_-]{1,32}$/, '服务名只能用字母、数字、下划线和连字符，最多 32 个字符');
/** 一组服务名：去重并按名字排序，各层存的都是这个形状，比较时不受顺序影响。 */
export const serverNamesSchema = z.array(serverNameSchema).max(64).transform((names) => [...new Set(names)].sort());
