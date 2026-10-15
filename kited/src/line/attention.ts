/**
 * 关注设备（docs/Line与工作区流转.md「会话状态与关注设备」）：此刻正在关注 Kite 的设备。App 在焦点、前后台变化时
 * PUT /attention 告知 Line 所在的工作机；设备还须连着这台工作机的事件流才算在关注，事件流全断即视为移出。
 * 只存在内存里：重启后事件流都断了，等 App 重连再告知。
 */
export class Attention {
  /** 设备 → 打开着的事件流条数。 */
  private streams = new Map<string, number>();
  /** App 声明在关注的设备；与事件流取交集才生效。 */
  private declared = new Set<string>();

  constructor(private changed: (devices: string[]) => void) {}

  /** 正在关注的设备。 */
  devices(): string[] { return [...this.declared].filter((device) => this.streams.has(device)).sort(); }

  set(device: string, focused: boolean): void {
    this.update(() => { if (focused) this.declared.add(device); else this.declared.delete(device); });
  }

  /** 设备打开一条事件流；返回关闭时调用的函数。最后一条断开时这台设备移出，重连后要再声明一次。 */
  connect(device: string): () => void {
    this.update(() => this.streams.set(device, (this.streams.get(device) ?? 0) + 1));
    let open = true;
    return () => {
      if (!open) return;
      open = false;
      this.update(() => {
        const count = (this.streams.get(device) ?? 1) - 1;
        if (count > 0) this.streams.set(device, count);
        else { this.streams.delete(device); this.declared.delete(device); }
      });
    };
  }

  private update(change: () => void): void {
    const before = this.devices().join('\n');
    change();
    const after = this.devices();
    if (after.join('\n') !== before) this.changed(after);
  }
}
