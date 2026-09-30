/** 补丁的已完成结果独立保存，历史引用不再读取当前文件来猜测当时的差异。 */
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';

export const diffID = z.string().regex(/^diff_[a-zA-Z0-9_-]+$/);
export const diffReferenceSchema = z.object({ id: diffID, paths: z.array(z.string()) }).strict();
export type DiffReference = z.infer<typeof diffReferenceSchema>;
export const fileDiffSchema = z.object({
  id: diffID,
  files: z.array(z.object({ path: z.string(), before: z.string().nullable(), after: z.string().nullable() }).strict()),
}).strict();
export type FileDiff = z.infer<typeof fileDiffSchema>;

export class FileDiffStore {
  constructor(private directory: string) {}

  save(diff: FileDiff): void {
    fileDiffSchema.parse(diff);
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const path = join(this.directory, `${diff.id}.json`);
    const temp = `${path}.${randomUUID()}.tmp`;
    try {
      const fd = openSync(temp, 'wx', 0o600);
      try { writeFileSync(fd, JSON.stringify(diff)); fsyncSync(fd); }
      finally { closeSync(fd); }
      renameSync(temp, path);
      const directory = openSync(this.directory, 'r');
      try { fsyncSync(directory); } finally { closeSync(directory); }
    } finally { rmSync(temp, { force: true }); }
  }

  read(id: string): FileDiff {
    diffID.parse(id);
    try { return fileDiffSchema.parse(JSON.parse(readFileSync(join(this.directory, `${id}.json`), 'utf8'))); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new KiteError('这份历史差异已不存在', 404);
      throw error;
    }
  }
}
