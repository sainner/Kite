/**
 * 编辑器的 SourceKit 不知道这些合同怎么编译，单独看本目录的 Swift 文件会报找不到 App 里的类型。
 * 合同每次用 swiftc 编译本目录的 Swift 文件，就把这次的真实参数记进同目录的 compile_commands.json（不入库），
 * sourcekit-lsp 沿上级目录找到它，按同样的参数解析。运行时生成的输入（从 App 源码抽出的声明等）在临时目录里，
 * 拷到 build/sourcekit/ 再引用，临时目录删掉后参数仍然有效。
 */
import { copyFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';

const here = import.meta.dir;
const root = resolve(here, '..', '..', '..');
const database = join(here, 'compile_commands.json');

type Entry = { directory: string; file: string; arguments: string[] };

export function recordSwiftCompile(args: string[], cwd: string): void {
  // xcrun --find swiftc 这类查询也带 swiftc，没有本目录的 Swift 输入就不是要记的编译
  const at = args.findIndex((arg) => basename(arg) === 'swiftc');
  const own = args.filter((arg) => arg.endsWith('.swift')).map((arg) => resolve(cwd, arg)).filter((path) => dirname(path) === here);
  if (at < 0 || !own.length) return;
  const copies = join(root, 'build', 'sourcekit', basename(own[0]!, '.swift'));
  const compile: string[] = [];
  for (let index = at; index < args.length; index++) {
    const arg = args[index]!;
    if (arg === '-o') { index++; continue; }
    const path = arg.endsWith('.swift') ? resolve(cwd, arg) : undefined;
    if (path && relative(root, path).startsWith('..')) {
      mkdirSync(copies, { recursive: true });
      const copy = join(copies, basename(path));
      copyFileSync(path, copy);
      compile.push(copy);
    } else compile.push(path ?? arg);
  }
  // 直接调 /usr/bin/swiftc 时由 xcrun 补上 SDK，SourceKit 拿不到，替它补成 macOS 的
  if (!compile.includes('-sdk')) {
    const sdk = Bun.spawnSync(['xcrun', '--show-sdk-path'], { env: { ...(process.env as Record<string, string>) } });
    compile.splice(1, 0, '-sdk', sdk.stdout.toString().trim());
  }
  let entries: Entry[] = [];
  try {
    entries = JSON.parse(readFileSync(database, 'utf8')) as Entry[];
  } catch {
    // 还没有或写坏了就从头记，不影响合同本身
  }
  entries = [...entries.filter((entry) => !own.includes(entry.file)), ...own.map((file) => ({ directory: here, file, arguments: compile }))];
  const temporary = `${database}.${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(entries, null, 2)}\n`);
  renameSync(temporary, database);
}
