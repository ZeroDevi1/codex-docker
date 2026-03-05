#!/bin/bash
set -e

# 1. 动态设置时区 (TZ)
if [ ! -z "$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
fi

# 2. 动态映射宿主机 UID/GID
USER_ID=${PUID:-1000}
GROUP_ID=${PGID:-1000}

# 如果宿主机要求的 UID/GID 不是 1000，则动态修改 devuser 的属性
if [ "$USER_ID" != "1000" ] || [ "$GROUP_ID" != "1000" ]; then
    echo "Updating devuser UID/GID to $USER_ID:$GROUP_ID..."
    groupmod -o -g "$GROUP_ID" devgroup || true
    usermod -o -u "$USER_ID" devuser || true
    # 修复家目录权限（后台静默执行，防止文件过多卡住启动）
    chown -R "$USER_ID:$GROUP_ID" /home/devuser &
fi

# 3. 处理 SSH 密钥（直接挂载版：known_hosts 永久持久化 + 自动信任 GitHub + 阿里云 Codeup）
if [ -d "/home/devuser/.ssh" ]; then
    echo "Securing mounted SSH keys (persist known_hosts)..."

    # 1. 修复权限
    chown -R devuser:devgroup /home/devuser/.ssh
    chmod 700 /home/devuser/.ssh

    # 严格权限：私钥 600，公钥/known_hosts/config 644
    find /home/devuser/.ssh -type f \( -name "id_*" -o -name "*.key" \) -not -name "*.pub" -exec chmod 600 {} \;
    find /home/devuser/.ssh -type f \( -name "*.pub" -o -name "known_hosts" -o -name "config" \) -exec chmod 644 {} \;

    # 2. 自动信任常用主机（GitHub + 阿里云 Codeup）
    for host in github.com codeup.aliyun.com; do
        if ! grep -q "^${host}" /home/devuser/.ssh/known_hosts 2>/dev/null; then
            echo "Auto-adding SSH host key for ${host} (第一次启动会联网获取)..."
            ssh-keyscan -t rsa,ed25519 "${host}" >> /home/devuser/.ssh/known_hosts 2>/dev/null || true
        fi
    done

    # 3. 最终修复 known_hosts 权限（防止 ssh-keyscan 写错权限）
    chown devuser:devgroup /home/devuser/.ssh/known_hosts 2>/dev/null || true
    chmod 644 /home/devuser/.ssh/known_hosts 2>/dev/null || true
fi


# 4. 修复代码工作目录的权限
if [ -d "/workspace" ]; then
    chown devuser:devgroup /workspace
fi

# 5. 降权启动目标程序
echo "Starting application..."
# 以 login shell 启动，确保 /etc/profile.d 与用户 profile 生效（vfox 等环境变量需要）
exec gosu devuser bash -lc 'exec "$@"' -- "$@"
