/**
 * 用真实录音比几家流式识别：每个样本分别不带上下文、带上下文各跑一遍，按真实语速推音频，
 * 比字错率、关键词命中、首个中间结果和说完到定稿的耗时。
 * 用法：bun run.ts <样本目录> [只跑哪几家，逗号分隔：doubao,qwen,apple]
 * 密钥可以写在样本目录的 .env 里（KEY=VALUE 一行一个），不进仓库；已经在环境变量里的不覆盖。
 */
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { apple, doubao, providers, qwen, type Context, type Provider, type Run } from './providers.ts';
import { contextOf, errorRate, termHits } from './score.ts';

const [root, only] = process.argv.slice(2);
if (!root) {
  console.error('用法：bun run.ts <样本目录> [doubao,qwen,apple]');
  process.exit(1);
}
const keys = Bun.file(join(root, '.env'));
if (await keys.exists()) {
  for (const line of (await keys.text()).split('\n')) {
    const match = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match && process.env[match[1]!] === undefined) process.env[match[1]!] = match[2]!.replace(/^(['"])(.*)\1$/, '$2');
  }
}
const byKey: Record<string, Provider> = { doubao, qwen, apple };
const chosen = only ? only.split(',').map((key) => byKey[key]).filter((provider): provider is Provider => !!provider) : providers;
const runnable = chosen.filter((provider) => {
  const missing = provider.missing();
  if (missing) console.error(`跳过 ${provider.name}：${missing}`);
  return !missing;
});

interface Row {
  sample: string;
  provider: string;
  context: boolean;
  run: Run;
  cer: number;
  terms: { hit: string[]; missed: string[] };
  firstPartial: number;
}

const rows: Row[] = [];
const samples = (await readdir(root, { withFileTypes: true })).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
for (const sample of samples) {
  const directory = join(root, sample);
  const files = await readdir(directory);
  const audio = files.find((file) => file.startsWith('audio.'));
  const reference = await text(join(directory, 'reference.txt'));
  if (!audio || reference === null) {
    console.error(`跳过样本 ${sample}：要有 audio.* 和 reference.txt`);
    continue;
  }
  const pcm = await toPcm(join(directory, audio));
  const conversation = await text(join(directory, 'context.txt'));
  const context: Context | null = conversation ? contextOf(conversation) : null;
  const terms = ((await text(join(directory, 'terms.txt'))) ?? '').split('\n').map((line) => line.trim()).filter(Boolean);
  for (const provider of runnable) {
    for (const withContext of context ? [false, true] : [false]) {
      const run = await provider.recognize(pcm, withContext ? context : null);
      const row: Row = {
        sample, provider: provider.name, context: withContext, run,
        cer: errorRate(run.final, reference), terms: termHits(run.final, terms), firstPartial: run.partials[0]?.at ?? NaN,
      };
      rows.push(row);
      console.log(`${sample}｜${provider.name}｜${withContext ? '带上下文' : '无上下文'}｜字错 ${percent(row.cer)}｜关键词 ${row.terms.hit.length}/${terms.length}`
        + `｜首字 ${ms(row.firstPartial)}｜定稿 ${ms(run.latency)}${run.error ? `｜出错：${run.error}` : ''}\n  ${run.final}`
        + (row.terms.missed.length ? `\n  漏掉：${row.terms.missed.join('、')}` : ''));
    }
  }
}

console.log('\n汇总（字错率按样本平均；关键词按总数；耗时取中位数）');
for (const provider of runnable) {
  for (const withContext of [false, true]) {
    const group = rows.filter((row) => row.provider === provider.name && row.context === withContext && !row.run.error);
    if (!group.length) continue;
    const hit = group.reduce((sum, row) => sum + row.terms.hit.length, 0);
    const total = group.reduce((sum, row) => sum + row.terms.hit.length + row.terms.missed.length, 0);
    console.log(`${provider.name}｜${withContext ? '带上下文' : '无上下文'}｜${group.length} 段｜字错 ${percent(average(group.map((row) => row.cer)))}`
      + `｜关键词 ${hit}/${total}｜首字 ${ms(median(group.map((row) => row.firstPartial)))}｜定稿 ${ms(median(group.map((row) => row.run.latency)))}`);
  }
}
const output = join(root, `results-${new Date().toISOString().replaceAll(':', '-')}.json`);
await Bun.write(output, JSON.stringify(rows, null, 2));
console.log(`\n明细写在 ${output}`);

async function text(path: string) {
  const file = Bun.file(path);
  return await file.exists() ? (await file.text()).trim() : null;
}

/** 任意格式的录音转成 16 kHz 单声道 s16le，取出 WAV 的 data 块。 */
async function toPcm(path: string) {
  const wav = `${process.env.TMPDIR ?? '/tmp'}/kite-voice-spike-${crypto.randomUUID()}.wav`;
  await Bun.$`afconvert -f WAVE -d LEI16@16000 -c 1 ${path} ${wav}`.quiet();
  const bytes = new Uint8Array(await Bun.file(wav).arrayBuffer());
  await Bun.$`rm -f ${wav}`.quiet();
  const view = new DataView(bytes.buffer);
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const id = new TextDecoder().decode(bytes.subarray(offset, offset + 4)), size = view.getUint32(offset + 4, true);
    if (id === 'data') return bytes.slice(offset + 8, offset + 8 + size);
    offset += 8 + size + (size % 2);
  }
  throw new Error(`${path} 转出来的 WAV 没有 data 块`);
}

function average(values: number[]) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function median(values: number[]) {
  const sorted = values.filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor(sorted.length / 2)]! : NaN;
}

function percent(value: number) {
  return `${(value * 100).toFixed(1)}%`;
}

function ms(value: number) {
  return Number.isFinite(value) ? `${Math.round(value)} 毫秒` : '—';
}
