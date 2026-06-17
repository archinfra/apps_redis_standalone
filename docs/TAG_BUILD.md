# Tag 构建说明

真正的 tag 构建必须由 Git tag push 触发：

```bash
git tag v0.1.0
git push origin v0.1.0
```

不要用 `git push origin main` 代替 tag 构建。

原因：如果在 GitHub Actions 里用默认 `GITHUB_TOKEN` 创建并推送 tag，GitHub 默认不会再次触发另一个 workflow。因此 Actions 页面会显示 `main`，而不是 `v0.1.0`。

正确做法：

1. 本地克隆仓库。
2. 确认当前 `main` 是要发布的提交。
3. 执行 `git tag v0.1.0`。
4. 执行 `git push origin v0.1.0`。
5. 查看 Actions 里 `offline-run-packages` 的 ref 是否为 `v0.1.0`。

```bash
git clone https://github.com/archinfra/apps_redis_standalone.git
cd apps_redis_standalone
git checkout main
git pull origin main
git tag v0.1.0
git push origin v0.1.0
```
