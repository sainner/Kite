import { expect, test } from 'bun:test';
import { mkdirSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { projectFolders } from '../../src/harness/context/project.ts';
import { collectSkills, skillsBinding, type Skill } from '../../src/harness/context/skills.ts';
import { useTemp } from '../util.ts';

const temp = useTemp();

/** 在 directory 下建一个 skill 文件夹并写 SKILL.md，返回 SKILL.md 的路径。 */
function skill(directory: string, content: string): string {
  mkdirSync(directory, { recursive: true });
  const path = join(directory, 'SKILL.md');
  writeFileSync(path, content);
  return path;
}

/** 路径解析过软链接的清单，按名字排序：软链接到达的那条留的是哪个路径不作要求，只要求指向同一个 SKILL.md。 */
const resolved = (skills: Skill[]) => skills
  .map(({ name, layer, description, path }) => ({ name, layer, description, path: realpathSync(path) }))
  .sort((a, b) => a.name.localeCompare(b.name));

// 代码之外的行为：readdirSync 把软链接当普通条目列出来、statSync 跟着链接判成目录、realpathSync 把相对软链接解析到同一个真实目录，
// 三者合起来才让 .agents/skills/x -> ../../.claude/skills/x 这种仓库里常见的链接只算一次，而指向不存在目标的链接不会让整个清单抛错；
// 几部分的配合：projectFolders 给的由外到内的层级，乘上每级 .claude/skills、.agents/skills 两个位置的先后，合起来决定同名时谁留下，
// 单看任一处都对，顺序反了才会错，要实际建出目录跑一遍。
test('skill 清单：里层同名盖外层、项目盖系统、同级 .agents 盖 .claude，相对软链接到同一文件夹只算一次，没有 SKILL.md 和断掉的链接不算', () => {
  const root = temp();
  const system = temp();
  mkdirSync(join(root, '.git'));
  const pkg = join(root, 'pkg');

  // 系统层：SYSTEM_SKILLS 里现在只有 kite-onboard，用自己建的目录代替仓库里真实的那份
  const systemOnboard = skill(join(system, 'kite-onboard'), '---\nname: kite-onboard\ndescription: 测试用的系统 skill\n---\n# 正文\n');

  // 根一级：.claude 里 alpha、shared、一个没有 SKILL.md 的文件夹；.agents 里 beta，shared 是指向 .claude 同名文件夹的相对软链接，再加一条断掉的链接
  const rootAlpha = skill(join(root, '.claude/skills/alpha'), '---\nname: alpha\ndescription: 根层的 alpha\n---\n');
  const shared = skill(join(root, '.claude/skills/shared'), '---\nname: shared\ndescription: 两个位置链到同一个文件夹\n---\n');
  mkdirSync(join(root, '.claude/skills/empty'));
  const beta = skill(join(root, '.agents/skills/beta'), '# beta\n\n没有头，只列名字。\n');
  symlinkSync('../../.claude/skills/shared', join(root, '.agents/skills/shared'));
  symlinkSync('../../nowhere', join(root, '.agents/skills/dangling'));

  // 里一级 pkg：alpha 的文件夹名不同但头里的 name 相同（折行块说明），delta 两个位置各一份，gamma 带引号的说明，kite-onboard 与系统层同名
  const innerAlpha = skill(join(pkg, '.claude/skills/alpha-inner'), '---\nname: alpha\ndescription: >\n  子目录里的 alpha，\n  折成两行写的说明\n---\n');
  skill(join(pkg, '.claude/skills/delta'), '---\nname: delta\ndescription: pkg 的 .claude 里的 delta\n---\n');
  const agentsDelta = skill(join(pkg, '.agents/skills/delta'), '---\nname: delta\ndescription: .agents 里的 delta，同一级盖 .claude\n---\n');
  const gamma = skill(join(pkg, '.agents/skills/gamma'), '---\nname: "gamma"\ndescription: "带引号的一句说明: 冒号也在里面"\n---\n');
  const projectOnboard = skill(join(pkg, '.agents/skills/kite-onboard'), '---\nname: kite-onboard\ndescription: 项目层盖掉系统层\n---\n');

  // 工作目录在 pkg：两级都算，里层赢
  expect(projectFolders(pkg)).toEqual([root, pkg]);
  const inner = collectSkills(projectFolders(pkg), { system });
  expect(resolved(inner)).toEqual([
    { name: 'alpha', layer: 'project', description: '子目录里的 alpha， 折成两行写的说明', path: innerAlpha },
    { name: 'beta', layer: 'project', description: '', path: beta },
    { name: 'delta', layer: 'project', description: '.agents 里的 delta，同一级盖 .claude', path: agentsDelta },
    { name: 'gamma', layer: 'project', description: '带引号的一句说明: 冒号也在里面', path: gamma },
    { name: 'kite-onboard', layer: 'project', description: '项目层盖掉系统层', path: projectOnboard },
    { name: 'shared', layer: 'project', description: '两个位置链到同一个文件夹', path: shared },
  ]);
  const innerLines = skillsBinding(inner).text.split('\n');
  expect(innerLines).toHaveLength(6);

  // 工作目录在仓库根：pkg 一级不算，根层的 alpha 留下，系统层的 kite-onboard 没被盖
  const outer = collectSkills(projectFolders(root), { system });
  expect(resolved(outer)).toEqual([
    { name: 'alpha', layer: 'project', description: '根层的 alpha', path: rootAlpha },
    { name: 'beta', layer: 'project', description: '', path: beta },
    { name: 'kite-onboard', layer: 'system', description: '测试用的系统 skill', path: systemOnboard },
    { name: 'shared', layer: 'project', description: '两个位置链到同一个文件夹', path: shared },
  ]);
});
