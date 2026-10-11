---
name: performance-diagnosis
description: 动画卡顿怎么量：帧间隔对照、真机 Time Profiler 的用法，Mac 的结论不能外推到 iPhone
metadata:
  node_type: memory
  type: reference
  originSessionId: 19e18107-9859-4070-a429-82a37c6d6214
  modified: 2026-10-11T12:08:52.013Z
---

- 卡顿先量再改：用 `CADisplayLink` 记下动作后一两秒的帧间隔，每做一次换一种组合对照，一次只用一种组合。手感只能说明卡不卡，说明不了卡在哪。
- iPhone 的卡顿要在真机上量，Mac 上的结论不能外推。2026-10-11 同一个发送卡顿：Mac 上是控制区的逐帧动画；iPhone 上是对话里 `UITextView` 反复量尺寸，每次卡 200–500ms。真实触摸（交互玻璃）的开销，Mac 上的自动发送也测不到。
- 真机 Time Profiler：`xcrun xctrace record --template 'Time Profiler' --device <ID> --launch -- com.sainner.kite`。`--attach` 按进程名或进程号都找不到进程（2026-10-11，Xcode 27.2）。
  - 导出 `time-profile` 表后，调用栈在 `tagged-backtrace` 元素里。
  - `potential-hangs` 表直接列出 250ms 以上的卡顿。
- 探针日志写到 App 的缓存目录，用 `devicectl device copy from` 取回，见 [App 入口](../../app/README.md#预览和验证)。
- 对照开了编译优化的版本时，加 `SWIFT_OPTIMIZATION_LEVEL=-O` 并单独指定 `-derivedDataPath`，不搅乱日常的增量缓存。
- 动画“跳”而帧间隔看着正常时，逐帧记动画自己的进度（位置、距离）和旁边内容的位置对照。2026-10-11 发送的点阵波就是这样查出的：它从发送时刻开始计时，发送那次排版近百毫秒，第一帧跳过 12 格，比对话滑动早约 100 毫秒。
- iPhone 上点阵取景框逐帧刷新约 60Hz，旁边的滚动是 120Hz，原因没查。用户看过认为点阵波 60 帧够用（2026-10-11），不必为它追 120Hz。

**Why:** 这次先在 Mac 上修好，再按 Mac 的思路改 iPhone，白改了两轮；真机录一次调用栈就定位了。
**How to apply:** 查动画性能时先说明要加什么探针、为什么，测完删掉；需要用户操作时一次说清要做几次、怎么做。协作要求见 [[feedback-ui-workflow]]，效果取舍见 [[feedback-interaction-quality]]。
