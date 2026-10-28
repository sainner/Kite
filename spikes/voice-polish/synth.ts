/**
 * 用系统的中文合成语音把口语稿（scripts.json）念成样本，先跑通协议、粗看整理效果；合成的话比真人干净，结论以真人录音为准。
 * 每段一个 tts-NN 目录：audio.aiff、spoken.txt（念的稿子）、terms.txt、context.txt。已有的跳过。
 * 用法：bun spikes/voice-polish/synth.ts <样本目录> [语音，默认 Tingting]
 */
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';

const [root, voice = 'Tingting'] = process.argv.slice(2);
if (!root) {
  console.error('用法：bun synth.ts <样本目录> [语音]');
  process.exit(1);
}
const scripts = await Bun.file(join(import.meta.dir, 'scripts.json')).json() as {
  contexts: Record<string, string>;
  samples: { context?: string; spoken: string; terms: string[] }[];
};
for (const [index, sample] of scripts.samples.entries()) {
  const directory = join(root, `tts-${String(index + 1).padStart(2, '0')}`);
  if (await Bun.file(join(directory, 'audio.aiff')).exists()) continue;
  await mkdir(directory, { recursive: true });
  await Bun.$`say -v ${voice} -o ${join(directory, 'audio.aiff')} ${sample.spoken}`.quiet();
  await Bun.write(join(directory, 'spoken.txt'), `${sample.spoken}\n`);
  await Bun.write(join(directory, 'terms.txt'), `${sample.terms.join('\n')}\n`);
  if (sample.context) await Bun.write(join(directory, 'context.txt'), `${scripts.contexts[sample.context]}\n`);
  console.log(`${directory}：${sample.spoken}`);
}
