/** 官方 prompt.attachment 接口的最小类型；模块由 Claude Code 加载，不访问文件、网络或进程。 */
type Attachment = { type: string; text: string; origin: { kind: string } };
type Result = { text: string | null };
type On = (event: 'prompt.attachment', matcher: { type: string[] },
  handler: (api: unknown, event: Attachment, next: (event: Attachment) => Promise<Result>) => Promise<Result>) => unknown;

/** 上游自身附加的提示类型；跨后端翻译据此跳过不会送达模型的附件。 */
export const engineAttachmentTypes = [
  'date', 'date_change', 'environment', 'model',
  'session_context', 'context_sections', 'coordinator_context',
  'skill_listing', 'dynamic_skill', 'sandbox_instructions',
  'output_style', 'output_style_instructions', 'language',
  'token_usage', 'total_tokens_reminder', 'budget_usd', 'output_token_usage',
  'batching_reminder', 'secondary_reminder', 'silent_turn_reminder',
];

export function register(on: On): void {
  on('prompt.attachment', { type: engineAttachmentTypes }, async (_api, event, next) => {
    // 仅删除上游自身的附加提示；用户插话、宿主 hooks 反馈、工具结果和恢复消息仍按原协议投递。
    if (event.origin.kind !== 'engine') return next(event);
    return { text: null };
  });
}
