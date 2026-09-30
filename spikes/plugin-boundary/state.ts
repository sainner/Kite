import { z } from 'zod';

export const taskSchema = z.object({ id: z.string(), title: z.string(), done: z.boolean() }).strict();
export const stateSchema = z.object({ revision: z.number().int().nonnegative(), tasks: z.array(taskSchema) }).strict();
export const replaceSchema = z.object({ expectedRevision: z.number().int().nonnegative(), tasks: z.array(taskSchema).max(100) }).strict();

