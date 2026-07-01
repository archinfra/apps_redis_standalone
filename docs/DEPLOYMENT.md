# Redis 单点服务离线部署说明

## 1. 构建侧

```bash
cd apps_redis_standalone
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
bash build.sh --arch amd64
bash build.sh --arch arm64
```

构建过程现在会按照 `images/image.json` 使用仓库内 `docker/redis/Dockerfile` 自构建镜像，而不是直接拉 `docker.io/library/redis:8` 打包。

构建出来的镜像默认 tag：

```text
sealos.hub:5000/kube4/redis-standalone:8
```

并分别保存为：

- `payload/images/redis-standalone-amd64.tar`
- `payload/images/redis-standalone-arm64.tar`

镜像内置：

- `/etc/redis/redis.conf`
- `/usr/local/bin/redis-standalone-entrypoint`
- `/usr/local/bin/redis-healthcheck`

并生成：

```text
payload/images/image-index.tsv
```

`image-index.tsv` 使用 `|` 分隔，字段为：

```text
name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile
```

## 2. 交付物

```text
redis-standalone-installer-amd64.run
redis-standalone-installer-amd64.run.sha256
redis-standalone-installer-arm64.run
redis-standalone-installer-arm64.run.sha256
```

## 3. 现场安装

```bash
sha256sum -c redis-standalone-installer-amd64.run.sha256
chmod +x redis-standalone-installer-amd64.run
./redis-standalone-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass 'PASSW9RD' \
  --password 'Redis@Passw0rd' \
  --storage-size 8Gi \
  -n aict \
  -y
```

执行内容：

1. 从 `.run` 内按字节偏移解出 payload。
2. 读取 `images/image-index.tsv`。
3. `docker load -i payload/images/*.tar`。
4. 将默认镜像 `sealos.hub:5000/kube4/redis-standalone:8` retarget 到 `--registry` 指定的内网仓库前缀。
5. `docker tag` 并 `docker push` 到目标内网仓库。
6. 渲染 `manifests/redis-standalone.yaml.tmpl`。
7. `kubectl apply` 安装 Namespace、Secret、Service、StatefulSet、PVC。
8. 等待 StatefulSet ready。

## 4. 半离线安装

如果内网仓库已经提前推送 Redis 镜像，可以跳过镜像导入和推送：

```bash
./redis-standalone-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  --password 'Redis@Passw0rd' \
  -n aict \
  -y
```

注意：`--skip-image-prepare` 只跳过 `docker load/tag/push`，不会跳过 Kubernetes 模板中的镜像地址渲染。

## 5. 验证

```bash
./redis-standalone-installer-amd64.run status -n aict
kubectl get pod,svc,statefulset,pvc -n aict -l app.kubernetes.io/instance=redis-standalone
kubectl exec -n aict statefulset/redis-standalone -- redis-cli -a 'Redis@Passw0rd' --no-auth-warning ping
```

预期输出：

```text
PONG
```

## 6. 卸载

默认保留 PVC：

```bash
./redis-standalone-installer-amd64.run uninstall -n aict -y
```

删除 PVC 数据：

```bash
./redis-standalone-installer-amd64.run uninstall -n aict --delete-pvc -y
```

## 7. 常见问题

### 为什么之前不是自构建？

旧版 `images/image.json` 使用：

```json
"pull": "docker.io/library/redis:8"
```

这意味着构建机只是拉官方镜像、保存 tar、打进 `.run`。现在已改成：

```json
"dockerfile": "docker/redis/Dockerfile"
```

所以 GitHub Actions 会自己构建 Redis standalone 镜像，再打包。

### Pod ImagePullBackOff

检查模板渲染出来的镜像地址是否为内网仓库地址：

```bash
kubectl get pod -n aict -l app.kubernetes.io/instance=redis-standalone -o yaml | grep image:
```

检查节点是否能访问内网仓库：

```bash
crictl pull sealos.hub:5000/kube4/redis-standalone:8
```

### PVC Pending

查看 StorageClass：

```bash
kubectl get storageclass
kubectl describe pvc -n aict -l app.kubernetes.io/instance=redis-standalone
```

如没有默认 StorageClass，安装时显式指定：

```bash
./redis-standalone-installer-amd64.run install --storage-class <storage-class-name> ...
```

### Redis 连接失败

确认密码和服务地址：

```bash
kubectl get svc -n aict redis-standalone
kubectl exec -n aict statefulset/redis-standalone -- redis-cli -a 'Redis@Passw0rd' --no-auth-warning ping
```
