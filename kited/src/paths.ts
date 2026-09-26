import { isAbsolute, relative, sep } from 'node:path';

/** path 在 root 里面，或就是 root；调用方负责解析符号链接。 */
export function within(path: string, root: string): boolean {
  const r = relative(root, path);
  // 只认 .. 这一段本身：「..data」这样的名字是 root 里面的文件夹。
  return r === '' || (r !== '..' && !r.startsWith(`..${sep}`) && !isAbsolute(r));
}
