/** Claude 输入用量包含缓存命中与写入；显示和自动压缩共用同一校验口径。 */
export function claudeInputTokens(usage: {
  input_tokens?: unknown; cache_read_input_tokens?: unknown; cache_creation_input_tokens?: unknown;
} | undefined): number | undefined {
  if (!usage) return undefined;
  const tokens = [usage.input_tokens, usage.cache_read_input_tokens ?? 0, usage.cache_creation_input_tokens ?? 0];
  return tokens.every((value): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0)
    ? tokens.reduce((total, value) => total + value, 0) : undefined;
}
