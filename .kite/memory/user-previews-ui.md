---
name: user-previews-ui
description: App 界面改完只编译、装上、打开新 build，由用户自己在模拟器里预览，不要自己点模拟器验证
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0e99a4ab-9086-4db6-9f61-bc85aab9d1d7
  modified: 2026-09-24T13:04:46.756Z
---

改完 App 界面代码、`.kite/check` 通过以后，编译并在模拟器里装上、打开新 build 就停，由用户自己预览和试手感。不要自己用模拟器工具点、截图来验证。

**Why:** 用户明确说过「不用你来预览，写好、改好代码之后打开新的 build，我来预览即可」。手势、动画的手感要本人试，自己截图验证慢，还会用错坐标得出错误结论。

**How to apply:** 改了 app/ 下的界面就编译 iPhone 模拟器版，`simctl install` 以后 `simctl launch`，告诉用户可以看了。逻辑上拿不准的地方写在回复里请用户试，不要自己去点。
