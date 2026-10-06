# Kite 托管账号服务

此目录适用于 `hk-server` 上的现有 Kubernetes 集群。入口为 `https://hs.sainner.top`，使用 `kite` 命名空间，不修改其他站点。`/api` 和托管 Git 远程 `/git` 转发到 Kite 账号服务，其余路径由 Headscale 提供；Headscale 管理 API 不公开到外部入口。

## 组成与持久数据

- `kubernetes.yaml`：两个单副本 Deployment、持久卷、内部服务和两个 Ingress。SQLite 服务更新使用 Recreate，避免两个实例同时写同一文件。`/git` 单独一个 Ingress，放宽请求体上限并关闭请求缓冲，供推送使用。
- `Dockerfile`：账号服务镜像，在官方 Bun 镜像上加装 git。镜像在服务器上构建并导入 k3s，不经镜像仓库。
- `headscale.yaml`、`policy.json`：组网控制、香港 DERP 中继及同账号互通策略；UDP 3478 使用宿主端口。
- `account-source` ConfigMap：由 `src/account/main.ts` 用项目 Bun 编译出的单文件。修改源码后须重新编译和更新，不能只重启旧内容。
- `account-secrets` Secret：`KITE_ACCOUNT_SECRET` 是稳定的账号服务密钥，用户绑定的 Git 凭据也用它派生的密钥加密；`HEADSCALE_API_KEY` 是服务间管理凭据；可选的 `GITHUB_CLIENT_ID` 是 GitHub OAuth App 的客户端 ID（需开启 Device Flow），未设置时不能用设备码绑定 GitHub。不要打印到日志、提交 Git 或写进 App。
- `account-data` 卷的 `/data/account.sqlite` 保存账号、设备、导航目录、项目登记与加密的 Git 凭据，`/data/repos/` 保存托管远程的裸仓库；`headscale-data` 卷保存网络节点和私钥。删除 Pod 不清数据；不要在升级时删除 PVC。

本机通过 `ssh hk-server` 管理。服务器的 kubectl 使用 `KUBECONFIG=$HOME/.kube/config`；默认的 k3s 配置不对 ubuntu 用户开放。

## 更新

首次部署或升级 Bun 版本时，在服务器上构建账号服务镜像并导入 k3s，标签与 `kubernetes.yaml` 一致：

```sh
scp kited/deploy/account/Dockerfile hk-server:kite-hosted/Dockerfile
ssh hk-server 'cd kite-hosted && docker build -t kite-account:1.4.2-git . && docker save kite-account:1.4.2-git | sudo k3s ctr images import -'
```

本地使用项目 Bun 构建：

```sh
cd kited
node_modules/.bin/bun build src/account/main.ts --target=bun --minify --outdir=/tmp/kite-account-build
scp /tmp/kite-account-build/main.js hk-server:kite-hosted/main.js
```

服务器端更新 ConfigMap 后重启账号 Deployment。使用 server-side apply，避免把大文件再复制进 annotation：

```sh
export KUBECONFIG=$HOME/.kube/config
kubectl -n kite create configmap account-source --from-file=main.js=$HOME/kite-hosted/main.js --dry-run=client -o yaml |
  kubectl apply --server-side -f -
kubectl -n kite rollout restart deployment/account
kubectl -n kite rollout status deployment/account
```

修改网络配置时分别更新 `headscale-config` 并重启 Headscale；修改 Deployment 或 Ingress 时应用此目录的清单。先核对当前资源与差异，尤其是持久卷、域名和端口。升级前备份两个 SQLite 数据库、托管仓库目录及 Headscale 私钥；不要只复制仍在写入中的 SQLite 主文件而漏掉 WAL。重新生成 `KITE_ACCOUNT_SECRET` 会使原会话失效，已绑定的 Git 凭据也无法再解密。

## 密钥与运行检查

首次部署先启动 Headscale，在 Pod 内使用 `headscale apikeys create` 创建 API key，再与随机账号密钥一起写入 Secret。密钥值通过权限受限的临时文件传递。现有账号密钥必须保留；重新生成会使原会话失效。API key 有有效期，需要在到期前创建替代密钥、更新 Secret、重启账号服务并撤销旧 key。

```sh
kubectl -n kite get pods,certificate
kubectl -n kite logs deployment/account --tail=30
kubectl -n kite logs deployment/headscale --tail=30
kubectl -n kite top pods
```

未登录访问 `/api/account` 应返回 401。完整验证见 `kited/test/manual/verify-account-network.ts`；其随机测试账号会打印用户 ID，节点会自动清理，账号数据库记录需按这些 ID 清理。真实用户的数据不参与验证。新节点、跨账号隔离、SSE 撤销应共同通过，单独的健康检查不等于网络链路可用。
