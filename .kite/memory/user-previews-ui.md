---
name: user-previews-ui
description: 用户负责视觉验收；保留预览与交付入口及 iPhone 真机验证要求
metadata:
  node_type: memory
  type: feedback
  originSessionId: 66683e4e-07b1-4044-bf52-915216e3fecc
---

用户要求改完界面后编译并打开新 build，由用户自己看效果、试手感，再给意见；不自行截图、放大、裁图验收。没有具体意见时不顺带重排界面。纯样式修改不额外写测试或搭测量探针；确需验证逻辑或数值时，先说明测量目的。

**Why:** 用户希望在真实使用中迭代界面；曾纠正自行视觉验收、简单样式改动扩大测试，以及改了手机交互却只交付 Mac 的做法。
**How to apply:**

- Mac 边改边看与交付确认的构建方式见 [App 预览和验证](../../app/README.md#预览和验证)，只保留一个预览实例。
- iPhone 窄屏、触控交互改动需构建、安装并打开已连接真机，由用户验收。
- Release 按 [macOS 安装与打包](../../docs/macOS安装与打包.md) 整体替换。曾因直接合并覆盖 App 混入旧服务资源、破坏签名，不要把这种方式当成快速安装。
