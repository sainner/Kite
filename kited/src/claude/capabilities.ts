/** 只初始化上游并读取账号当前的模型目录，不发送提示或启动模型请求。 */
import { query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { claudeOptions } from './options.ts';
import { agentModels } from '../agents/models.ts';

export async function claudeModels(cwd: string) {
  let finish!: () => void;
  const closed = new Promise<void>((resolve) => { finish = resolve; });
  const prompt: AsyncIterable<SDKUserMessage> = { async *[Symbol.asyncIterator]() { await closed; } };
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);
  const session = query({ prompt, options: { ...claudeOptions(cwd), persistSession: false, abortController: controller } });
  try {
    const models = await session.supportedModels();
    return agentModels.claude.flatMap(({ tier }) => {
      const model = models.find((model) => model.value === tier)
        ?? models.find((model) => model.value !== 'default' && (model.resolvedModel ?? model.value).startsWith(`claude-${tier}-`));
      return model ? [{ id: model.value, title: tier, ...(model.resolvedModel ? { resolvedModel: model.resolvedModel } : {}),
        reasoning: model.supportsEffort ? model.supportedEffortLevels ?? [] : [] }] : [];
    });
  } finally { clearTimeout(timeout); session.close(); finish(); }
}
