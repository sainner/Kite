---
name: todo-remote-connections
description: 远程连接的真机验收与多机关系候选能力，供后续会话复核与继续处理
metadata:
  node_type: memory
  type: todo
  originSessionId: b3d2aaa8-3ec2-4770-ae23-6dd12ad9f77b
  modified: 2026-10-06T04:06:41.604Z
---

**状态：** 认证与连接恢复契约已定并实现（2026-10-06，见 [kited 远程连接](../../docs/kited.md#远程连接)）；真机验收待做，多机同步待评估。

**来源：** 原 docs/Agent与插件契约.md 的远程清单及 docs/kited.md 的多机条目。2026-10-06 用户选定组网作为远程链路、设备配对令牌作为认证方式；随后用户认为组网应内嵌进 kited 与 App（tsnet / TailscaleKit），而不是要求另装 Tailscale 客户端，控制服务器先用 Tailscale 官方服务，headscale 留作后续。

**待处理：**
- 真机验收：2026-10-06 已在 iPhone 真机上经自建 headscale（lisa 服务器上的 hs.sainner.top，自带 DERP 中继）扫码自动入网并配对成功。还未验证：浏览与发送、切后台再回前台重连（及节点重新上线耗时）、撤销后提示重新配对、节点密钥过期后的重新登录、蜂窝网络下的直连与经中继延迟（任务书 §20）、与代理 App 能否共存。
- 当前 Mac 上的 Kite App 尚未重装为含「添加设备」二维码的新版。
- 多机推送、拒绝后的重新整合属于候选能力，尚未确定方案。项目身份关联只统一身份，不同步文件或执行记录。

**完成条件：** 在明确的设备与网络条件下完成上述真机流程并记录覆盖范围，出现缺陷时转为具体问题；多机同步另行确认需求，不能从身份关联推断已支持同步。插件跨端操作的验收见 [[todo-plugin-device-validation]]。
