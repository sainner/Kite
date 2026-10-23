/**
 * 工作目录以外的 skill 文件夹对代理放行只读：SkillCatalog 算出放行位置，localTools 合进策略，read 按整份策略校验。
 * 两个测试各挡一个合起来才出过的 bug，都要实际建出软链接跑一遍。
 */
import { expect, test } from 'bun:test';
import { mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { localTools } from '../../src/execution/local-tools.ts';
import { SkillCatalog } from '../../src/harness/context/project.ts';
import type { Tool } from '../../src/harness/types.ts';
import { ENV, useTemp } from '../util.ts';

const temp = useTemp();

/** 在 directory 下建一个 skill 文件夹并写 SKILL.md。 */
function skill(directory: string, name: string): void {
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, 'SKILL.md'), `---\nname: ${name}\ndescription: 测试用的 ${name}\n---\n# ${name}\n`);
}

/** 放行位置里有没有盖住 path 的：位置本身或它的上级。 */
const covers = (readable: string[], path: string) =>
  readable.some((entry) => entry === '/' || path === entry || path.startsWith(`${entry}/`));

function readTool(cwd: string, catalog: SkillCatalog, logDir: string): Tool {
  const tool = localTools({ cwd, logDir, env: ENV(), skills: catalog }).find((candidate) => candidate.name === 'read');
  if (!tool) throw new Error('缺少 read 工具');
  return tool;
}

function read(tool: Tool, cwd: string, path: string) {
  const args = { path };
  tool.validate(args);
  return tool.execute(args, { cwd, signal: new AbortController().signal });
}

// 真实出过的 bug（安全）：项目层的 skill 根目录本身是软链接时，旧实现取它的真实路径整个放进沙箱的 policy.read，
// 仓库里提交 .claude/skills -> /，或代理在可写的工作目录里建 .agents/skills -> 主目录，沙箱里 ~/.ssh 这类文件就都能读了。
// 依赖操作系统：realpathSync 跟着软链接把根目录解析到 / 或主目录；几部分的配合：collectSkills 跟着链接列清单、
// 放行位置按根目录与各 skill 文件夹合成，单看每处都对，合起来才放开整片目录。
test('项目层 skill 根目录软链接到 / 或主目录时不放行链接目标，仓库里工作目录以外的普通根目录照常放行', () => {
  const repo = temp();
  const home = temp();
  const system = temp();
  mkdirSync(join(repo, '.git'));
  const cwd = join(repo, 'pkg');
  mkdirSync(cwd);

  // 代表主目录：放一个秘密文件和一个没有 SKILL.md 的 .ssh
  writeFileSync(join(home, 'secret.txt'), '仅供测试的假秘密');
  mkdirSync(join(home, '.ssh'));
  writeFileSync(join(home, '.ssh', 'id_rsa'), '假私钥');

  // 仓库里提交的根目录软链接到 /；工作目录里代理自己建的根目录软链接到主目录
  mkdirSync(join(repo, '.claude'));
  symlinkSync('/', join(repo, '.claude', 'skills'));
  mkdirSync(join(cwd, '.agents'));
  symlinkSync(home, join(cwd, '.agents', 'skills'));

  // 对照：仓库根目录里的普通根目录，在工作目录以外、真实路径仍在仓库以内
  const legit = join(repo, '.agents', 'skills');
  skill(join(legit, 'ok'), 'ok');

  const catalog = new SkillCatalog(cwd, { system });
  const readable = catalog.readable;

  expect(readable).not.toContain('/');
  expect(readable.filter((entry) => entry === home || entry.startsWith(`${home}/`))).toEqual([]);
  expect(covers(readable, join(home, 'secret.txt'))).toBe(false);
  expect(covers(readable, join(home, '.ssh', 'id_rsa'))).toBe(false);

  expect(catalog.skills.map((entry) => entry.name)).toContain('ok');
  expect(covers(readable, legit)).toBe(true);
  expect(covers(readable, join(legit, 'ok', 'SKILL.md'))).toBe(true);
});

// 真实出过的 bug：skill 文件夹名带通配字符（软链接到工作目录外的 foo[1]）时，旧实现把它的真实路径原样加进 policy.read，
// read 校验整份读列表时抛「沙箱路径必须是无通配符的绝对路径」，读工作区里的普通文件也报错，patch 和每条 shell 同样全坏。
// 几部分的配合：collectSkills 跟着软链接认出这个 skill、放行位置为没被盖住的 skill 文件夹另加一条、withSkillReads 过滤、
// read 的 assertFileAccess 校验整份列表，合起来才出错；跳过带通配字符的条目时不能连别的 skill 一起丢掉。
test('skill 文件夹名带通配字符时 read 照常读工作区文件，别的工作目录外的 skill 文件也读得到', async () => {
  const cwd = temp();
  const outside = temp();
  const system = temp();
  const logs = temp();
  mkdirSync(join(cwd, '.git'));
  writeFileSync(join(cwd, 'a.txt'), '工作区里的普通文件\n');

  // 软链接到工作目录外、名字带方括号的 skill 文件夹（没被工作目录盖住），再加一个工作目录里名字带通配字符的
  skill(join(outside, 'foo[1]'), 'foo');
  mkdirSync(join(cwd, '.claude', 'skills'), { recursive: true });
  symlinkSync(join(outside, 'foo[1]'), join(cwd, '.claude', 'skills', 'foo'));
  skill(join(cwd, '.claude', 'skills', 'bar*'), 'bar');
  // 对照：同样软链接到工作目录外、名字普通的 skill
  skill(join(outside, 'plain'), 'plain');
  symlinkSync(join(outside, 'plain'), join(cwd, '.claude', 'skills', 'plain'));

  const catalog = new SkillCatalog(cwd, { system });
  expect(catalog.skills.map((entry) => entry.name).sort()).toEqual(['bar', 'foo', 'plain']);

  const tool = readTool(cwd, catalog, logs);
  const workspace = await read(tool, cwd, 'a.txt');
  expect(workspace.status).toBe('success');
  expect(workspace.output).toContain('工作区里的普通文件');

  const other = await read(tool, cwd, join(outside, 'plain', 'SKILL.md'));
  expect(other.status).toBe('success');
  expect(other.output).toContain('测试用的 plain');
});
