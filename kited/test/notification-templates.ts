import type { ContextDefinition } from '../src/harness/context/types.ts';
import type { Kited } from './harness.ts';

interface Template { definition: ContextDefinition; revision: string }

/** 从真实目录编辑通知，保留原有正文，只替换测试加入的文字和变量段落。 */
export async function editNotificationTemplate(request: Kited['call'], id: string, text: string, variable: string): Promise<Template> {
  const catalog = await request('GET', '/context-templates');
  if (catalog.status !== 200) throw new Error(`读取通知模板目录失败：${catalog.status}`);
  const template = (catalog.body.templates as Template[]).find((entry) => entry.definition.id === id);
  if (!template) throw new Error(`缺少通知模板：${id}`);
  const definition: ContextDefinition = {
    ...template.definition,
    blocks: [...template.definition.blocks.filter((block) => block.id !== 'custom-notification'), {
      type: 'paragraph', id: 'custom-notification', title: '自定义通知',
      parts: [{ type: 'text', text: `${text}\n` }, { type: 'variable', name: variable }],
    }],
  };
  const saved = await request('PUT', `/context-templates/${id}`, {
    expectedRevision: template.revision, definition,
  });
  if (saved.status !== 200) throw new Error(`保存通知模板 ${id} 失败：${saved.status} ${JSON.stringify(saved.body)}`);
  return saved.body as Template;
}
