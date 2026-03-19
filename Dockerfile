FROM ubuntu:24.04

# 1. 基础环境及权限工具 (提权执行)
ENV DEBIAN_FRONTEND=noninteractive
ENV VFOX_HOME=/home/devuser/.version-fox
ENV VFOX_NODE_VERSION=22.14.0
ENV VFOX_GLOBAL_NPM_PACKAGES="ace-tool @upstash/context7-mcp"

# 【优化 1】替换为清华大学/阿里云的国内源 (针对 Ubuntu 24.04 DEB822 格式)
RUN sed -i 's/archive.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's/security.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/ubuntu.sources

# 【优化 2】增加 --no-install-recommends 参数，拒绝无效依赖雪崩
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl unzip wget sudo build-essential \
    python3 python3-pip \
    gosu tzdata ca-certificates \
    ffmpeg openssh-client \
    musl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# [统一包管理] 安装 Version-Fox (vfox)
# 注意：多架构构建（buildx + qemu）场景下，Docker build 过程中以非 root 用户执行 sudo 可能失败（nosuid）。
# 因此这里在 root 阶段直接完成 vfox 的 apt 安装，后续再切到 devuser 使用 vfox。
RUN set -eux; \
    echo "deb [trusted=yes lang=none] https://apt.fury.io/versionfox/ /" > /etc/apt/sources.list.d/versionfox.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends vfox; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# 让 vfox 在容器运行时也生效（entrypoint 用 bash -lc 执行，会读取 /etc/profile.d）
RUN set -eux; \
    mkdir -p /etc/profile.d; \
    printf '%s\n' 'export VFOX_HOME=/home/devuser/.version-fox' 'eval "$(vfox activate bash)"' > /etc/profile.d/vfox.sh; \
    chmod 0644 /etc/profile.d/vfox.sh

# 2. 预创建标准的开发用户 (UID 1000)
# 针对 Ubuntu 24.04 的特性，先删除默认占用 1000 ID 的 ubuntu 用户
RUN (id -u ubuntu >/dev/null 2>&1 && userdel -r ubuntu) || true && \
    groupadd -g 1000 devgroup && \
    useradd -u 1000 -g 1000 -m -s /bin/bash devuser && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 3. 切换至开发用户，安装所有的开发 SDK 和工具链
USER devuser
WORKDIR /home/devuser

# [Rust] 安装 Rust + Cargo (Rust 官方工具链最稳)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/home/devuser/.cargo/bin:${PATH}"

# [Python] 安装 uv (极致性能的 Python 环境和包管理)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/devuser/.local/bin:${PATH}"
# 让 uv 直接管理系统级 Python 包（容器环境下的推荐做法）
ENV UV_SYSTEM_PYTHON=1

# [新增：代码质量工具 Qlty CLI]
# 赋予 Agent 全局静态代码检查和格式化能力
RUN curl -fsSL https://qlty.sh | sh
ENV PATH="/home/devuser/.qlty/bin:${PATH}"

# vfox 已在 root 阶段安装；这里仅写入激活命令
RUN echo 'eval "$(vfox activate bash)"' >> /home/devuser/.bashrc \
    && echo 'eval "$(vfox activate bash)"' >> /home/devuser/.profile \
    && printf '%s\n' 'export VFOX_HOME=/home/devuser/.version-fox' | cat - /home/devuser/.bashrc > /home/devuser/.bashrc.tmp \
    && mv /home/devuser/.bashrc.tmp /home/devuser/.bashrc \
    && printf '%s\n' 'export VFOX_HOME=/home/devuser/.version-fox' | cat - /home/devuser/.profile > /home/devuser/.profile.tmp \
    && mv /home/devuser/.profile.tmp /home/devuser/.profile

# 配置 vfox 插件并安装 Java / Node.js
# 注意：vfox 需要在 bash 环境下激活才能执行 install
RUN bash -c "eval \"\$(vfox activate bash)\" && \
    vfox add java && \
    vfox add nodejs && \
    vfox install java@21.0.1 && \
    vfox install java@8.0.332 && \
    vfox use -g java@21.0.1+12 && \
    vfox install nodejs@22.14.0 && \
    vfox use -g nodejs@22.14.0 && \
    vfox use nodejs@22.14.0"

# [Node 辅助与全局工具] 启用 corepack 并安装业务所需的全局 CLI
RUN bash -c "eval \"\$(vfox activate bash)\" && \
    corepack enable && \
    corepack prepare pnpm@latest --activate && \
    npm install -g ace-tool @upstash/context7-mcp"

# 4. 切回 root 安装全局 Codex（默认跟随上游最新 Release）
USER root
ENV INSTALL_DIR=/usr/local/bin

ARG CODEX_REF=
ENV CODEX_REF=${CODEX_REF}

RUN set -eux; \
    ARCH=$(uname -m); \
    # 核心修正：严格绑定为 -gnu 后缀，杜绝 musl 污染
    if [ "$ARCH" = "x86_64" ]; then TARGET="x86_64-unknown-linux-gnu"; \
    elif [ "$ARCH" = "aarch64" ]; then TARGET="aarch64-unknown-linux-gnu"; \
    else echo "Unsupported arch: $ARCH" && exit 1; fi; \
    download() { \
        curl --fail --show-error --silent --location \
            --retry 8 \
            --retry-delay 2 \
            --retry-max-time 120 \
            --retry-all-errors \
            "$1" -o "$2"; \
    }; \
    RESOLVED_REF="$CODEX_REF"; \
    if [ -z "$RESOLVED_REF" ]; then \
        RESOLVED_REF="$(curl --fail --show-error --silent --location \
            --retry 8 \
            --retry-delay 2 \
            --retry-max-time 120 \
            --retry-all-errors \
            https://api.github.com/repos/stellarlinkco/codex/releases/latest | \
            python3 -c 'import json, sys; print(json.load(sys.stdin)[\"tag_name\"])')"; \
    fi; \
    \
    # 拼接精确的 Release 下载地址
    url="https://github.com/stellarlinkco/codex/releases/download/${RESOLVED_REF}/codex-${TARGET}"; \
    latest_url="https://github.com/stellarlinkco/codex/releases/latest/download/codex-${TARGET}"; \
    echo "Downloading ${url} ..."; \
    if ! download "$url" /usr/local/bin/codex; then \
        echo "WARN: 指定版本 ${RESOLVED_REF} 下载失败，回退拉取 latest ..."; \
        download "$latest_url" /usr/local/bin/codex; \
    fi; \
    chmod +x /usr/local/bin/codex

# 【新增】安装 dos2unix 工具
RUN apt-get update && apt-get install -y dos2unix && apt-get clean

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# 【修改】先转换换行符，再赋予执行权限
RUN dos2unix /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# 5. 收尾工作
WORKDIR /workspace
EXPOSE 5000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["codex", "serve", "--host", "0.0.0.0", "--port", "5000"]
