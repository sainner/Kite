---
name: todo-headscale-cleanup
description: 个人 Headscale 实验服务的清理状态尚未核验
metadata:
  type: todo
---

**状态：** 待核验，不代表服务仍在运行。
**来源：** 个人 Headscale 实验部署记录。

清理线索为 `ssh lisa`、`headscale` systemd 服务、`/etc/headscale/config.yaml`，以及 nginx 的 `/etc/nginx/sites-available/headscale`、`/etc/nginx/streams-enabled/lisa443.conf`。这些位置只用于定位，不作为当前托管账号的部署配置。

**完成条件：** 先核实资源是否存在、是否仍有用途，再决定是否清理；已不存在或确认无需保留时删除本条。任何 nginx 调整先验证配置，并保留仍在使用的 sing-box 分流。
