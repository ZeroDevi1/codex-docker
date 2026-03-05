# codex-docker

基于上游 `stellarlinkco/codex` 的 Docker 镜像封装，并通过 GitHub Actions 自动构建并推送到 GHCR（公开镜像）。

## 使用

拉取镜像（将 `ZeroDevi1` 替换成你的 GitHub 用户名/组织名）：

```bash
docker pull ghcr.io/<owner>/codex-docker:latest
```

启动服务示例：

```bash
docker run --rm -p 5000:5000 ghcr.io/<owner>/codex-docker:latest
```

默认命令：

```bash
codex serve --host 0.0.0.0 --port 5000
```

## 自动构建（跟随上游 Release）

由于 GitHub Actions 的 `release` 事件只能监听“本仓库”的 Release，本仓库采用定时任务轮询上游 `stellarlinkco/codex` 的 `latest release tag`：

- Workflow：`.github/workflows/build-and-push-ghcr.yml`
- 逻辑：每 30 分钟检查一次上游 latest release tag；若 GHCR 已存在同名 tag 则跳过，否则构建并推送
- 你也可以在 GitHub Actions 页面手动触发，并通过 `codex_ref` 输入框指定任意上游 tag/ref 进行构建

镜像 tag 规则：

- `ghcr.io/<owner>/codex-docker:<上游tag>`（例如 `v1.2.2`）
- `ghcr.io/<owner>/codex-docker:latest`

## GitHub 需要配置什么

1. 确保仓库启用了 GitHub Actions（一般默认开启）
2. 进入 `Settings -> Actions -> General -> Workflow permissions`，确保 `GITHUB_TOKEN` 至少具备写入 Packages 的权限（workflow 内已声明 `packages: write`）
3. 首次推送镜像后，到仓库的 Packages 页面把容器包可见性改为 `Public`（公开镜像）

## 参考与致谢

- 上游项目：[`stellarlinkco/codex`](https://github.com/stellarlinkco/codex)（本镜像通过其 `scripts/install.sh` 安装 Codex）
