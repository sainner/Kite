/**
 * 人发的消息带的附件。原件存在工作机数据目录的 attachments/<工作区>/<附件>/ 下，只增不改：随工作区副本流转，删项目时一起删，
 * 在沙箱保护的目录里，代理碰不到。工作区里另放一份 .kite/attachments/<附件>/<文件名> 给代理用，检出的 info/exclude 忽略它，
 * 不进快照与提交；代理改了、删了，原件和会话都不受影响。能解码的图片收下时另存一份规整好、交给模型的样子，发消息时附进去。
 * 约定见 docs/会话显示协议.md「附件」。
 */
import { createHash, randomUUID } from 'node:crypto';
import { closeSync, constants, copyFileSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, renameSync, rmSync,
  statSync, writeFileSync, writeSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { AttachmentRef, ToolImage } from '../harness/types.ts';
import { fileKind, readImage } from './documents.ts';
import { WorkspaceFiles } from './files.ts';

/** 工作区里给代理用的那份所在的目录，相对工作区目录。 */
export const ATTACHMENT_DIR = '.kite/attachments';
export const MAX_ATTACHMENT_BYTES = 100 * 1024 * 1024;
export const MAX_MESSAGE_ATTACHMENTS = 10;
/** 交给模型的每张图最多这么大：一条消息带满图片时合计约 20 MB 的 base64，在 Claude 一次请求 32 MB 的上限以内。 */
const MODEL_IMAGE_BYTES = Math.floor(15_000_000 / MAX_MESSAGE_ATTACHMENTS);
const MAX_NAME_BYTES = 200;
/** 客户端生成的 ID，同时是目录名。 */
const ID = /^[A-Za-z0-9][A-Za-z0-9-]{7,63}$/;

export const attachmentPath = (ref: Pick<AttachmentRef, 'id' | 'name'>) => `${ATTACHMENT_DIR}/${ref.id}/${ref.name}`;
export const attachmentStore = (home: string, workspaceId: string) => join(home, 'attachments', workspaceId);

const positive = z.number().int().positive();
const refFields = z.object({
  id: z.string().min(1), name: z.string().min(1).max(255), mediaType: z.string().min(1), size: positive, width: positive.optional(), height: positive.optional(),
}).strict();
export const attachmentRef: z.ZodType<AttachmentRef> = refFields;
const stored = refFields.extend({ sha256: z.string() }).strict();
const modelSchema = z.object({ mediaType: z.enum(['image/png', 'image/jpeg', 'image/webp']), data: z.string().min(1) }).strict();

/** 文件名只留最后一段，去掉控制字符与斜杠；太长的保留扩展名截短。 */
export function attachmentName(raw: string): string {
  const name = raw.normalize('NFC').split(/[/\\]/).at(-1)!.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  if (!name || name === '.' || name === '..') return '附件';
  if (Buffer.byteLength(name) <= MAX_NAME_BYTES) return name;
  const dot = name.lastIndexOf('.');
  const extension = dot > 0 && name.length - dot <= 16 ? name.slice(dot) : '';
  let stem = [...name.slice(0, name.length - extension.length)];
  while (Buffer.byteLength(stem.join('') + extension) > MAX_NAME_BYTES) stem.pop();
  return stem.join('') + extension;
}

/** 开头 8 KB 里没有 NUL、是合法的 UTF-8，就当文本。 */
function textual(path: string): boolean {
  const head = Buffer.alloc(8192);
  const fd = openSync(path, 'r');
  let size: number;
  try { size = readSync(fd, head, 0, head.length, 0); } finally { closeSync(fd); }
  const bytes = head.subarray(0, size);
  if (bytes.includes(0)) return false;
  try { new TextDecoder('utf-8', { fatal: true }).decode(bytes, { stream: true }); return true; } catch { return false; }
}

/** 按文件头定类型；能解码的图片带原图尺寸和交给模型的那份，read 读不了的（太大、解不开）按普通文件。 */
async function describe(path: string): Promise<{ mediaType: string; width?: number; height?: number; model?: ToolImage }> {
  const kind = fileKind(path);
  if (kind === 'pdf') return { mediaType: 'application/pdf' };
  if (kind === 'image') {
    try {
      const { image, source } = await readImage(path, MODEL_IMAGE_BYTES);
      return { mediaType: `image/${source.format}`, width: source.width, height: source.height, model: image };
    } catch { /* 按普通文件 */ }
  }
  return { mediaType: kind === 'text' && textual(path) ? 'text/plain' : 'application/octet-stream' };
}

/** 收好、还没存进工作区的上传，见 Attachments.receive。 */
export interface Upload { workspaceId: string; staging: string; ref: AttachmentRef; sha256: string }

export class Attachments {
  constructor(private home: string) {}

  private dir(workspaceId: string, id: string): string {
    if (!ID.test(id)) throw new KiteError('附件 ID 无效');
    return join(attachmentStore(this.home, workspaceId), id);
  }

  private stored(workspaceId: string, id: string): z.infer<typeof stored> | undefined {
    const file = join(this.dir(workspaceId, id), 'meta.json');
    return existsSync(file) ? stored.parse(JSON.parse(readFileSync(file, 'utf8'))) : undefined;
  }

  /** 收了一半的上传和临时文件放这里：在各工作区的附件目录之外，副本不会扫到。 */
  private get staging(): string { return join(this.home, 'uploads'); }

  /** 清掉上次没收完的上传；kited 启动时调。 */
  clearStaging(): void { rmSync(this.staging, { recursive: true, force: true }); }

  /**
   * 收下上传的文件：内容、类型和交给模型的那份先放进暂存目录，之后 commit 存进工作区；存没存成都要 discard。
   * 收的时候不占工作区锁，大文件慢慢传也不挡别的操作。
   */
  async receive(workspaceId: string, id: string, rawName: string, body: AsyncIterable<Uint8Array>): Promise<Upload> {
    this.dir(workspaceId, id);
    const name = attachmentName(rawName);
    mkdirSync(this.staging, { recursive: true, mode: 0o700 });
    const staging = join(this.staging, randomUUID());
    mkdirSync(staging);
    try {
      const content = join(staging, 'content');
      const hash = createHash('sha256');
      let size = 0;
      const sink = Bun.file(content).writer();
      try {
        for await (const chunk of body) {
          size += chunk.byteLength;
          if (size > MAX_ATTACHMENT_BYTES) throw new KiteError(`附件超过 ${MAX_ATTACHMENT_BYTES / 1024 / 1024} MiB`, 413);
          hash.update(chunk);
          await sink.write(chunk);
        }
      } finally { await sink.end(); }
      if (!size) throw new KiteError('附件是空的');
      const sha256 = hash.digest('hex');
      const { model, ...described } = await describe(content);
      const ref: AttachmentRef = { id, name, size, ...described };
      if (model) writeFileSync(join(staging, 'model.json'), JSON.stringify(model));
      writeFileSync(join(staging, 'meta.json'), JSON.stringify({ ...ref, sha256 }));
      return { workspaceId, staging, ref, sha256 };
    } catch (error) {
      rmSync(staging, { recursive: true, force: true });
      throw error;
    }
  }

  /**
   * 把收好的上传存进工作区，再把给代理用的那份写进工作区目录 cwd。同一个 ID 已经存过同样的内容和名字时返回原来的，不同的报 409。
   * 调用方在工作区锁里调，并先让检出忽略 ATTACHMENT_DIR。
   */
  commit(upload: Upload, cwd: string): AttachmentRef {
    const { workspaceId, ref: { id } } = upload;
    const existing = this.stored(workspaceId, id);
    if (existing && (existing.sha256 !== upload.sha256 || existing.name !== upload.ref.name)) throw new KiteError('附件 ID 已用于其他文件', 409);
    if (!existing) {
      const target = this.dir(workspaceId, id);
      mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
      renameSync(upload.staging, target);
    }
    const ref = existing ? refOf(existing) : upload.ref;
    this.place(workspaceId, cwd, ref);
    return ref;
  }

  discard(upload: Upload): void { rmSync(upload.staging, { recursive: true, force: true }); }

  /** 分段上传拼接中的文件，在暂存目录里，按工作区与附件 ID 认。 */
  private partsFile(workspaceId: string, id: string): string {
    this.dir(workspaceId, id);
    return join(this.staging, 'parts', workspaceId, id);
  }

  /**
   * 分段上传的一段：写进这个附件拼接文件的 offset 处，几段可以同时写；size 是整份大小。
   * 组网上卡住的段由客户端换个请求重传（见 App 的 KitedClient.upload），后到的覆盖先到的。
   */
  async receivePart(workspaceId: string, id: string, size: number, offset: number, body: AsyncIterable<Uint8Array>): Promise<void> {
    if (!Number.isSafeInteger(size) || size <= 0) throw new KiteError('附件大小无效');
    if (size > MAX_ATTACHMENT_BYTES) throw new KiteError(`附件超过 ${MAX_ATTACHMENT_BYTES / 1024 / 1024} MiB`, 413);
    if (!Number.isSafeInteger(offset) || offset < 0 || offset >= size) throw new KiteError('分段位置无效');
    const file = this.partsFile(workspaceId, id);
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    const fd = openSync(file, constants.O_CREAT | constants.O_WRONLY, 0o600);
    try {
      let position = offset;
      for await (const chunk of body) {
        if (position + chunk.byteLength > size) throw new KiteError('分段超出附件大小');
        writeSync(fd, chunk, 0, chunk.byteLength, position);
        position += chunk.byteLength;
      }
    } finally { closeSync(fd); }
  }

  /** 各段都传完了：拼好的文件与整份的大小、SHA-256 对得上才交回它的位置，由调用方照整份上传收下；之后调 dropParts。 */
  async assembled(workspaceId: string, id: string, size: number, sha256: string): Promise<string> {
    const file = this.partsFile(workspaceId, id);
    if (!existsSync(file)) throw new KiteError('没有收到这个附件的分段', 404);
    const hash = createHash('sha256');
    for await (const chunk of Bun.file(file).stream()) hash.update(chunk);
    if (statSync(file).size !== size || hash.digest('hex') !== sha256) throw new KiteError('附件的分段没有传全，请重新上传', 409);
    return file;
  }

  dropParts(workspaceId: string, id: string): void { rmSync(this.partsFile(workspaceId, id), { force: true }); }

  /** 发消息带的附件：都要已经存好，不能重复，数量有上限。 */
  refs(workspaceId: string, ids: string[]): AttachmentRef[] {
    if (ids.length > MAX_MESSAGE_ATTACHMENTS) throw new KiteError(`一条消息最多带 ${MAX_MESSAGE_ATTACHMENTS} 个附件`);
    if (new Set(ids).size !== ids.length) throw new KiteError('附件重复');
    return ids.map((id) => this.content(workspaceId, id).ref);
  }

  /** 随消息发出的附件不再能删：记录里引用着它。 */
  markSent(workspaceId: string, refs: AttachmentRef[]): void {
    for (const ref of refs) {
      const marker = join(this.dir(workspaceId, ref.id), 'sent');
      if (!existsSync(marker)) writeFileSync(marker, '');
    }
  }

  /** 删掉没发出去的附件，连同工作区里的那份；已经没有的不算错。 */
  remove(workspaceId: string, cwd: string, id: string): void {
    const dir = this.dir(workspaceId, id);
    this.dropParts(workspaceId, id);
    if (!existsSync(dir)) return;
    if (existsSync(join(dir, 'sent'))) throw new KiteError('附件已随消息发出，不能删除', 409);
    rmSync(dir, { recursive: true, force: true });
    try { rmSync(new WorkspaceFiles(cwd).resolve(`${ATTACHMENT_DIR}/${id}`), { recursive: true, force: true }); }
    catch { /* 工作区不在了，或路径经链接指到了外面：不删 */ }
  }

  /** 原件的位置。 */
  content(workspaceId: string, id: string): { ref: AttachmentRef; path: string; sha256: string } {
    const meta = this.stored(workspaceId, id);
    if (!meta) throw new KiteError(`没有这个附件：${id}`, 404);
    return { ref: refOf(meta), path: join(this.dir(workspaceId, id), 'content'), sha256: meta.sha256 };
  }

  /**
   * 图片缩到长边不超过 size 的缩略图；带透明的 PNG 保留 PNG，其余给 JPEG。附件内容不会变，做过的存在附件旁边（随附件流转），
   * 下次直接给，不再解原图。
   */
  async thumbnail(workspaceId: string, id: string, size: number): Promise<{ bytes: Uint8Array<ArrayBuffer>; type: string }> {
    const { ref, path } = this.content(workspaceId, id);
    if (!ref.width || !ref.height) throw new KiteError('这个附件不是图片', 409);
    const type = ref.mediaType === 'image/png' ? 'image/png' : 'image/jpeg';
    const cached = join(this.dir(workspaceId, id), `thumbnail-${size}`);
    if (existsSync(cached)) return { bytes: new Uint8Array(readFileSync(cached)), type };
    const scale = Math.min(1, size / Math.max(ref.width, ref.height));
    const image = new Bun.Image(readFileSync(path)).resize(Math.max(1, Math.round(ref.width * scale)), Math.max(1, Math.round(ref.height * scale)), { fit: 'inside' });
    const bytes = (await (type === 'image/png' ? image.png() : image.jpeg({ quality: 85 })).bytes()).slice();
    // 先写在暂存目录再挪过去，副本不会拿到写了一半的
    mkdirSync(this.staging, { recursive: true, mode: 0o700 });
    const temp = join(this.staging, randomUUID());
    writeFileSync(temp, bytes);
    renameSync(temp, cached);
    return { bytes, type };
  }

  /** 附件里的图片交给模型的样子，按附件的顺序；不是图片的跳过。 */
  images(workspaceId: string, refs: AttachmentRef[]): ToolImage[] {
    return refs.flatMap((ref) => {
      if (!ref.width) return [];
      const file = join(this.dir(workspaceId, ref.id), 'model.json');
      return existsSync(file) ? [modelSchema.parse(JSON.parse(readFileSync(file, 'utf8')))] : [];
    });
  }

  /** 把存着的附件都写进工作区（流转来还原时）；已经有的不动。 */
  placeAll(workspaceId: string, cwd: string): void {
    const root = attachmentStore(this.home, workspaceId);
    if (!existsSync(root)) return;
    for (const id of readdirSync(root)) {
      if (!ID.test(id)) continue;
      const meta = this.stored(workspaceId, id);
      if (meta) this.place(workspaceId, cwd, meta);
    }
  }

  /**
   * 工作区里给代理用的那份：已经有（哪怕代理改过）就不动；APFS 上是克隆，不多占空间。只是给代理的方便，写不进去
   * （代理把目录换成了文件，或链到了工作区外面）不影响原件和上传，记一笔就算了。
   */
  private place(workspaceId: string, cwd: string, ref: AttachmentRef): void {
    if (!existsSync(cwd)) return;
    try {
      const target = new WorkspaceFiles(cwd).resolve(attachmentPath(ref));
      if (lstatSync(target, { throwIfNoEntry: false })) return;
      mkdirSync(dirname(target), { recursive: true });
      copyFileSync(join(this.dir(workspaceId, ref.id), 'content'), target, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE);
    } catch (error) { console.warn(`[附件] ${ref.name} 没能放进工作区：${(error as Error).message}`); }
  }
}

const refOf = ({ sha256: _, ...ref }: z.infer<typeof stored>): AttachmentRef => ref;
