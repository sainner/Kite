import { z } from 'zod';

const id = z.uuid();
const time = z.number().int().nonnegative().safe();
const named = { id, name: z.string().min(1).max(512), createdAt: time };

/** 目录仅包含导航摘要；严格拒绝会话正文、插件配置和文件内容。 */
export const catalogSnapshot = z.object({
  machine: z.object(named).strict(),
  projects: z.array(z.object({ ...named, remote: z.string().max(2048).optional() }).strict()).max(10_000),
  checkouts: z.array(z.object({
    id, projectId: id, machineId: id, path: z.string().startsWith('/').max(4096),
    commits: z.enum(['kite', 'user']), createdAt: time,
    /** 检出实际使用的远程（归一化）；托管仓库迁移后据此判断各检出是否已切换。 */
    remote: z.string().max(2048).optional(),
  }).strict()).max(10_000),
  workspaces: z.array(z.object({
    id, checkoutId: id, name: named.name, cwd: z.string().startsWith('/').max(4096),
    kind: z.enum(['root', 'worktree']), branch: z.string().nullable(), base: z.string().nullable(),
    status: z.enum(['preparing', 'open', 'failed', 'archived']), createdAt: time,
  }).strict()).max(10_000),
}).strict().superRefine((value, ctx) => {
  const projects = new Set(value.projects.map((p) => p.id));
  const checkouts = new Set(value.checkouts.map((c) => c.id));
  const workspaces = new Set(value.workspaces.map((w) => w.id));
  if (projects.size !== value.projects.length || checkouts.size !== value.checkouts.length || workspaces.size !== value.workspaces.length
    || value.checkouts.some((c) => c.machineId !== value.machine.id || !projects.has(c.projectId))
    || value.workspaces.some((w) => !checkouts.has(w.checkoutId))) {
    ctx.addIssue({ code: 'custom', message: '目录身份重复或归属无效' });
  }
});

export type CatalogSnapshot = z.infer<typeof catalogSnapshot>;
export const catalogPublication = z.object({ revision: z.number().int().positive().safe(), snapshot: catalogSnapshot }).strict();
