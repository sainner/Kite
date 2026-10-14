/** 语音识别可选的模型，形状与代理模型目录相同，界面用同一个选择器；识别没有思考强度。模型目录手动维护。 */
export type SpeechProvider = 'dashscope';

export const speechVendors: { id: SpeechProvider; title: string }[] = [{ id: 'dashscope', title: '千问（百炼）' }];

export const speechModels: { id: string; title: string; name: string; reasoning: string[]; vendor: SpeechProvider }[] = [
  { id: 'qwen3-asr-flash-realtime', title: 'qwen', name: 'qwen3-asr-flash-realtime', reasoning: [], vendor: 'dashscope' },
];

export const defaultSpeechModel = { model: speechModels[0]!.id, reasoning: 'default' };
