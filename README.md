# apps_redis_standalone

Redis 单点服务 Kubernetes 离线 `.run` 安装包项目。

## tag 构建

必须在本地或带真实 GitHub 用户 Token 的 CI 里执行：

```bash
git tag v0.1.0
git push origin v0.1.0
```

注意：不要用 `git push origin main` 伪装 tag 构建。GitHub Actions 内置 `GITHUB_TOKEN` 推送 tag 时，GitHub 默认不会再触发另一个 workflow，因此 Actions 页面上会显示 `main`，不是 `v0.1.0`。

## 构建

```bash
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
bash build.sh --arch amd64
bash build.sh --arch arm64
bash build.sh --arch all
```

## 离线安装

```bash
./redis-standalone-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'PASSW9RD' \
  --password 'Redis@Passw0rd' \
  -n aict \
  -y
```
