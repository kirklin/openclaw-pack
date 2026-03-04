# ==============================================================================
# Kirklin's openclaw-pack - Optimized Docker Build
# Base: Node.js 22 Slim
# ==============================================================================

FROM node:22-slim

# Maintainer and Meta info
LABEL maintainer="Kirklin"
LABEL description="集成了多种能力的 OpenClaw 核心与多插件网关环境"
LABEL org.opencontainers.image.source="https://github.com/kirklin/openclaw-pack"

# ==========================================
# 1. 系统底层依赖 (System Dependencies)
# ==========================================
USER root
ENV DEBIAN_FRONTEND=noninteractive

# 使用阿里云镜像源
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries && \
    sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends --fix-missing \
        ca-certificates curl wget gnupg jq git python3 unzip \
        libcap2-bin gosu chromium fonts-noto-cjk fonts-noto-color-emoji && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Fix Chromium sandbox for Docker compatibility
RUN chmod 4755 /usr/bin/chromium || true

# ==========================================
# 2. 核心框架与全局依赖 (Global Dependencies)
# ==========================================
# 使用 npm 国内镜像源加速全局包安装，并锁定核心组件版本
RUN npm config set registry https://registry.npmmirror.com && \
    npm install -g npm@latest && \
    npm install -g openclaw@2026.3.2 @sunnoy/wecom@v1.5.1 @openclaw/feishu playwright && \
    npx playwright install chromium --with-deps && \
    rm -rf /root/.npm /root/.cache

# 赋予 Node.js 监听低端口的权限
RUN setcap 'cap_net_bind_service=+ep' /usr/local/bin/node

# 注入 QMD (Quantum Memory Daemon) Mock 脚本
RUN echo '#!/bin/bash\necho "QMD Memory Daemon Mock"' > /usr/local/bin/qmd && \
    chmod +x /usr/local/bin/qmd

# ==========================================
# 3. 用户工作区初始化 (Workspace Setup)
# ==========================================
# 创建目录并赋予 node 用户权限，避免后续权限错乱
RUN mkdir -p /home/node/.openclaw/workspace \
             /home/node/.openclaw/extensions && \
    chown -R node:node /home/node/.openclaw

USER node
ENV HOME=/home/node
WORKDIR /home/node/.openclaw/extensions

# ==========================================
# 4. 插件独立分层安装 (Isolated Plugin Layers)
# ==========================================
# 优势：分层缓存。如果只修改单个插件，Docker 会复用其他层，极大提升二次构建速度。
# 注意：每个 RUN 内部自带清理命令，防止镜像体积膨胀。

# 插件 A: 钉钉接入 (Dingtalk)
RUN git clone --depth 1 https://github.com/soimy/openclaw-channel-dingtalk.git dingtalk && \
    cd dingtalk && \
    npm install --omit=dev --legacy-peer-deps && \
    rm -rf .git

# 插件 B: QQ 机器人 (QQBot)
RUN git clone --depth 1 https://github.com/justlovemaki/qqbot.git qqbot && \
    cd qqbot && \
    npm install --omit=dev || true && \
    rm -rf .git

# 全局清理 Node 用户的缓存
RUN rm -rf /home/node/.npm /home/node/.cache

# ==========================================
# 5. 启动配置 (Entrypoint Configuration)
# ==========================================
# 切回 root 配置启动脚本（启动脚本内应使用 gosu 降权运行）
USER root

COPY ./scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 核心环境变量
ENV HOME=/home/node \
    TERM=xterm-256color \
    NODE_PATH=/usr/local/lib/node_modules

# 暴露网关端口
EXPOSE 18789 18790

# 重置工作目录为 node 用户主目录
WORKDIR /home/node

# 最终入口点
ENTRYPOINT ["/bin/bash", "/usr/local/bin/entrypoint.sh"]
