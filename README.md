# apps_redis_standalone

Redis 单点服务 Kubernetes 离线 `.run` 安装包项目。

本项目用于把 Redis 单实例以统一离线交付形态打包：构建机先基于仓库内 `docker/redis/Dockerfile` 自构建 Redis 镜像，再保存为 tar，生成 `image-index.tsv`，拼接成自解压 `.run`；离线现场运行 `.run install` 后自动导入镜像、重打 tag、推送到内网仓库、渲染 Kubernetes YAML 并安装 Redis StatefulSet。

## 这次修复了什么

之前 `images/image.json` 使用 `pull: docker.io/library/redis:8`，所以 Actions 只是拉官方镜像再打包，并没有自构建镜像。现在已经改成 `dockerfile: docker/redis/Dockerfile`，Actions 会按 `amd64/arm64` 分别执行 `docker buildx build --load`。

同时把 Redis 配置、启动逻辑和健康检查脚本内置进镜像：

- `docker/redis/Dockerfile`
- `docker/redis/redis.conf`
- `docker/redis/redis-standalone-entrypoint`
- `docker/redis/redis-healthcheck`

Kubernetes manifest 不再挂载 ConfigMap 作为 Redis 配置文件，也不再在 Pod command 里拼接启动命令；容器直接使用镜像内置 entrypoint，探针直接调用 `/usr/local/bin/redis-healthcheck`。

## 目录结构

```text
apps_redis_standalone/
  VERSION
  build.sh
  install.sh
  images/
    image.json
  docker/
    redis/
      Dockerfile
      redis.conf
      redis-standalone-entrypoint
      redis-healthcheck
  manifests/
    redis-standalone.yaml.tmpl
  docs/
    DEPLOYMENT.md
  .github/workflows/
    offline-run-packages.yml
```

## 构建

构建机要求：Linux shell、Docker、python3、tar、sha256sum。构建 `arm64` 时 Docker Buildx/QEMU 需要可用。

```bash
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
bash build.sh --arch amd64
bash build.sh --arch arm64
# 或一次构建双架构
bash build.sh --arch all
```

构建产物：

```text
dist/redis-standalone-installer-amd64.run
dist/redis-standalone-installer-amd64.run.sha256
dist/redis-standalone-installer-arm64.run
dist/redis-standalone-installer-arm64.run.sha256
```

## tag 构建

真正的 tag 构建必须使用 Git tag 触发：

```bash
git tag v0.1.0
git push origin v0.1.0
```

不要用 `git push origin main` 伪装 tag 构建。GitHub Actions 内置 `GITHUB_TOKEN` 推送 tag 时，GitHub 默认不会再触发另一个 workflow，因此 Actions 页面会显示 `main`，不是 `v0.1.0`。

推送 `v*` tag 后，GitHub Actions 会构建 `amd64`、`arm64` 两个离线 `.run` 包，并发布 Release。

## 离线安装

```bash
sha256sum -c redis-standalone-installer-amd64.run.sha256
chmod +x redis-standalone-installer-amd64.run
./redis-standalone-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'PASSW9RD' \
  --password 'Redis@Passw0rd' \
  -n aict \
  -y
```

目标仓库已提前准备镜像时：

```bash
./redis-standalone-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  --password 'Redis@Passw0rd' \
  -n aict \
  -y
```

## 状态检查

```bash
./redis-standalone-installer-amd64.run status -n aict
kubectl get pod,svc,statefulset,pvc -n aict -l app.kubernetes.io/instance=redis-standalone
kubectl exec -n aict statefulset/redis-standalone -- redis-cli -a 'Redis@Passw0rd' --no-auth-warning ping
```

## 卸载

默认保留 PVC 数据：

```bash
./redis-standalone-installer-amd64.run uninstall -n aict -y
```

确认删除数据时再显式执行：

```bash
./redis-standalone-installer-amd64.run uninstall -n aict --delete-pvc -y
```

## 参数说明

安装器支持：

- `install|uninstall|status|unpack|help`
- `--registry`：目标内网仓库前缀，例如 `sealos.hub:5000/kube4`
- `--registry-user` / `--registry-pass`：推送目标仓库的账号密码
- `--skip-image-prepare`：跳过 `docker load/tag/push`
- `--password`：Redis requirepass 密码
- `--storage-size`：PVC 容量，默认 `8Gi`
- `--storage-class`：指定 StorageClass，不传则使用集群默认 StorageClass
- `--service-type` / `--node-port`：Service 暴露方式
- `--delete-pvc`：卸载时删除数据 PVC

## GitHub Actions

`main` 分支 push 会构建 `amd64`、`arm64` artifact；推送 `v*` tag 时会发布 GitHub Release，并把 `.run` 与 `.sha256` 附加到 Release。
