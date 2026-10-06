---
name: reference-headscale-lisa
description: Kite 组网用的自建 headscale 部署在服务器 lisa 上，维护或排查组网时查这里
metadata:
  type: reference
---

2026-10-06 部署。`ssh lisa` 登录（Ubuntu 24.04，root）。

- headscale v0.29.4，deb 安装，systemd 服务 `headscale`；配置 `/etc/headscale/config.yaml`（原始备份 `config.yaml.orig`），`server_url: https://hs.sainner.top`，内置 DERP（region 999，STUN UDP 3478），MagicDNS 基础域名 `tailnet.kite`，用户 `sainner`。
- 443 由 nginx stream 按 SNI 分流：`hs.sainner.top` → `127.0.0.1:4443`（nginx 终结 TLS 后反代 `127.0.0.1:8080`），其余流量仍去 sing-box 代理。配置在 `/etc/nginx/sites-available/headscale` 和 `/etc/nginx/streams-enabled/lisa443.conf`，后者改前备份在 `/root/lisa443.conf.bak-headscale`。证书由 certbot webroot（`/var/www/acme`）签发并自动续期。
- DNS 在 Cloudflare，`hs` 与 `rm` 两条 A 记录指向 61.124.1.122（`rm` 是排查时多加的，未使用）。这台开发 Mac 所在网络会拦截并缓存普通 DNS 查询，新记录可能要等负缓存（最长 30 分钟）过期；核对时从服务器或用 DoH 查。
- 工作机 kited 的 headscale 管理密钥在 `~/.kite/tailnet/headscale.json`，用 `kite net admin` 写入。

**How to apply:** 组网连不上、要换控制服务器或撤销节点（`headscale nodes list / delete`）时从这里入手；改 nginx 前先 `nginx -t`，不要动 sing-box 的分流。相关待办见 [[todo-remote-connections]]。
